defmodule Nspark.Architecture do
  @moduledoc """
  The agent architecture domain: graphs and their nodes, edges, and immutable
  version snapshots. See docs/HLD.md §4 for the persistence model.
  """
  use Ash.Domain, otp_app: :nspark, extensions: [AshAdmin.Domain]

  alias Nspark.Architecture.{Graph, Node, Edge, GraphVersion}
  import Ash.Query, only: [filter: 2]

  admin do
    show? true
  end

  resources do
    resource Graph

    resource Node

    resource Edge

    resource GraphVersion do
      define :versions_for_graph, action: :list_for_graph, args: [:graph_id]
    end
  end

  # ── Graph persistence: publish and restore ──────────────────────────────────

  @doc """
  Snapshot the current draft (nodes + edges already in DB) into an immutable
  `GraphVersion`, then bump `graph.graph_version`. Returns `{:ok, version}`.
  """
  def publish_graph(graph, nodes, edges, actor, tenant) do
    opts = [tenant: tenant, actor: actor]
    snapshot = serialize_snapshot(nodes, edges)
    version_number = graph.graph_version

    Nspark.Repo.transaction(fn ->
      version =
        Ash.create!(
          GraphVersion,
          %{
            graph_id: graph.id,
            version_number: version_number,
            graph_snapshot: snapshot,
            author_id: actor.id
          },
          opts
        )

      Ash.update!(graph, %{graph_version: version_number + 1}, opts)
      version
    end)
  end

  @doc """
  Restore a graph to a published snapshot. Deletes the current nodes/edges and
  recreates them from the version's `graph_snapshot`. Returns `{:ok, id_map}`
  where `id_map` maps snapshot node ids → new node ids.
  """
  def restore_version(version, graph, actor, tenant) do
    opts = [tenant: tenant, actor: actor]
    snapshot = version.graph_snapshot

    Nspark.Repo.transaction(fn ->
      # Delete current canvas (edges first due to FK constraints).
      Edge |> filter(graph_id == ^graph.id) |> Ash.read!(opts) |> Enum.each(&Ash.destroy!(&1, opts))
      Node |> filter(graph_id == ^graph.id) |> Ash.read!(opts) |> Enum.each(&Ash.destroy!(&1, opts))

      # Recreate nodes, accumulating old_id → new_id mapping.
      id_map =
        (snapshot["nodes"] || [])
        |> Enum.reduce(%{}, fn n, acc ->
          new_node =
            Ash.create!(
              Node,
              %{
                type: String.to_existing_atom(n["type"]),
                label: n["label"] || "Node",
                content: n["content"],
                is_muted: n["is_muted"] || false,
                source_asset_id: n["source_asset_id"],
                graph_id: graph.id,
                metadata: %{"position" => n["position"] || %{"x" => 0, "y" => 0}}
              },
              opts
            )

          Map.put(acc, n["id"], new_node.id)
        end)

      # Recreate edges using the new node ids.
      (snapshot["edges"] || [])
      |> Enum.each(fn e ->
        src = Map.get(id_map, e["source_node_id"])
        tgt = Map.get(id_map, e["target_node_id"])

        if src && tgt do
          edge_type =
            (e["edge_type"] || "dependency")
            |> String.to_existing_atom()

          Ash.create!(Edge, %{graph_id: graph.id, source_node_id: src, target_node_id: tgt, edge_type: edge_type}, opts)
        end
      end)

      id_map
    end)
  end

  # ── Canonical snapshot serialization ────────────────────────────────────────

  @doc "Serialize nodes + edges to the canonical graph_snapshot JSON shape."
  def serialize_snapshot(nodes, edges) do
    %{
      "nodes" =>
        Enum.map(nodes, fn n ->
          %{
            "id" => n.id,
            "type" => to_string(n.type),
            "label" => n.label,
            "content" => n.content,
            "is_muted" => n.is_muted,
            "source_asset_id" => n.source_asset_id,
            "position" => (n.metadata || %{})["position"] || %{"x" => 0, "y" => 0}
          }
        end),
      "edges" =>
        Enum.map(edges, fn e ->
          %{
            "id" => e.id,
            "source_node_id" => e.source_node_id,
            "target_node_id" => e.target_node_id,
            "edge_type" => to_string(e.edge_type)
          }
        end)
    }
  end
end
