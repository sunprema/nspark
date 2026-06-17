defmodule Nspark.Architecture do
  @moduledoc """
  The agent architecture domain: graphs and their nodes, edges, and immutable
  version snapshots. See docs/HLD.md §4 for the persistence model.
  """
  use Ash.Domain, otp_app: :nspark, extensions: [AshAdmin.Domain, AshPaperTrail.Domain]

  alias Nspark.Architecture.{Graph, Node, Edge, GraphVersion}
  import Ash.Query, only: [filter: 2]

  admin do
    show? true
  end

  paper_trail do
    include_versions?(true)
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
  `GraphVersion`, then bump `graph.graph_version`.

  Linked Skill nodes are resolved against the Registry first and their content is
  **frozen** into the snapshot, so a deployed prompt never changes when a Skill is
  later edited. The resolved Skill versions are recorded on the version's
  `resolved_skills` manifest (Knowledge Layer, plan Phase 4).

  The new version is diffed against the immediately preceding one
  (`Nspark.VersionDiff.diff/2`) and the classified result is frozen on the
  version's `diff_summary`. A **breaking** change (a new required variable, a
  variable rename, or a dropped output) is gated: the caller must pass
  `acknowledge_breaking: true` **and** a non-blank `:changelog` naming the break.

  Options (`opts`):
  - `:acknowledge_breaking` — `true` to proceed past a breaking diff
  - `:changelog` — required when acknowledging a breaking change

  Returns `{:ok, version}`, or:
  - `{:error, {:unresolved_skills, problems}}` — a linked Skill is missing/deprecated
  - `{:error, {:breaking_change, diff}}` — breaking diff, not acknowledged
  - `{:error, {:changelog_required, diff}}` — acknowledged but no changelog
  """
  def publish_graph(graph, nodes, edges, actor, tenant, opts \\ []) do
    ash_opts = [tenant: tenant, actor: actor]
    resolution = Nspark.Registry.resolve_skills(nodes, ash_opts)

    if resolution.problems != [] do
      {:error, {:unresolved_skills, resolution.problems}}
    else
      snapshot = serialize_snapshot(resolution.nodes, edges)
      contract = Nspark.VersionDiff.contract(snapshot)
      version_number = graph.graph_version
      diff_summary = diff_against_previous(graph, snapshot, ash_opts)

      with :ok <- gate_breaking(diff_summary, opts) do
        result =
          Nspark.Repo.transaction(fn ->
            version =
              Ash.create!(
                GraphVersion,
                %{
                  graph_id: graph.id,
                  version_number: version_number,
                  graph_snapshot: snapshot,
                  resolved_skills: resolution.manifest,
                  input_contract: contract,
                  diff_summary: diff_summary,
                  changelog: normalize_changelog(opts[:changelog]),
                  author_id: actor.id
                },
                ash_opts
              )

            Ash.update!(graph, %{graph_version: version_number + 1}, ash_opts)
            version
          end)

        result
      end
    end
  end

  # Diff the new snapshot against the immediately preceding published version.
  # First publish (no prior version) is `%{"level" => "initial"}` and never gated.
  defp diff_against_previous(graph, snapshot, ash_opts) do
    case versions_for_graph!(graph.id, ash_opts) do
      [latest | _] -> Nspark.VersionDiff.diff(latest.graph_snapshot, snapshot)
      [] -> %{"level" => "initial"}
    end
  end

  # A breaking diff requires both an explicit acknowledgement and a changelog.
  # `diff/2` levels are atoms; `"initial"` (a string) never matches, so first
  # publishes pass straight through.
  defp gate_breaking(%{"level" => :breaking} = diff, opts) do
    cond do
      not Keyword.get(opts, :acknowledge_breaking, false) -> {:error, {:breaking_change, diff}}
      blank?(opts[:changelog]) -> {:error, {:changelog_required, diff}}
      true -> :ok
    end
  end

  defp gate_breaking(_diff, _opts), do: :ok

  defp normalize_changelog(changelog) do
    if blank?(changelog), do: nil, else: String.trim(changelog)
  end

  defp blank?(nil), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false

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
      Edge
      |> filter(graph_id == ^graph.id)
      |> Ash.read!(opts)
      |> Enum.each(&Ash.destroy!(&1, opts))

      Node
      |> filter(graph_id == ^graph.id)
      |> Ash.read!(opts)
      |> Enum.each(&Ash.destroy!(&1, opts))

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

          Ash.create!(
            Edge,
            %{graph_id: graph.id, source_node_id: src, target_node_id: tgt, edge_type: edge_type},
            opts
          )
        end
      end)

      id_map
    end)
  end

  # ── Deploy-time breaking-change impact ──────────────────────────────────────

  @doc """
  Classify the impact of deploying `version` to `environment` against whatever is
  **currently live** there.

  Publishing a new version protects `@latest` consumers (that gate lives in
  `publish_graph/6`), but an environment alias (`@production`) keeps serving its
  pinned version until someone deploys over it. So the deploy step is where an
  environment's consumers can actually break — this diffs the version being
  deployed against the environment's active deployment's frozen snapshot.

  Returns:
  - `:no_active_deployment` — nothing live in `environment` yet (first deploy)
  - `:unchanged` — that environment already serves this exact version
  - `%{level:, diff:, current_version:, deployment:}` — `diff` is the
    `VersionDiff.diff/2` of current→new; `level` is its `"level"`. Only a
    `:breaking` level should gate the deploy.
  """
  def deploy_impact(version, environment, ash_opts) do
    case Nspark.Deployments.active_deployment_for(version.graph_id, environment, ash_opts) do
      {:ok, nil} ->
        :no_active_deployment

      {:ok, deployment} ->
        current = deployment.graph_version

        if current.id == version.id do
          :unchanged
        else
          diff = Nspark.VersionDiff.diff(current.graph_snapshot, version.graph_snapshot)

          %{
            level: diff["level"],
            diff: diff,
            current_version: current.version_number,
            deployment: deployment
          }
        end

      {:error, _} ->
        :no_active_deployment
    end
  end

  # ── Canonical snapshot serialization ────────────────────────────────────────

  @doc "Serialize nodes + edges to the canonical graph_snapshot JSON shape."
  def serialize_snapshot(nodes, edges) do
    %{
      "nodes" =>
        Enum.map(nodes, fn n ->
          meta = n.metadata || %{}

          %{
            "id" => n.id,
            "type" => to_string(n.type),
            "label" => n.label,
            "content" => n.content,
            "is_muted" => n.is_muted,
            "source_asset_id" => n.source_asset_id,
            "position" => meta["position"] || %{"x" => 0, "y" => 0},
            "metadata" => Map.drop(meta, ["position"])
          }
        end),
      "edges" =>
        Enum.map(edges, fn e ->
          %{
            "id" => e.id,
            "source_node_id" => e.source_node_id,
            "target_node_id" => e.target_node_id,
            "edge_type" => to_string(e.edge_type),
            # Edge metadata carries the conditional branch (`%{"branch" => "yes"}`),
            # which the compiler's conditional routing and the contract's optional-
            # variable detection both read. Dropping it here silently broke both on
            # every published snapshot.
            "metadata" => e.metadata || %{}
          }
        end)
    }
  end
end
