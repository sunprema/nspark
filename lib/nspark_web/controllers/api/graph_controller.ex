defmodule NsparkWeb.Api.GraphController do
  @moduledoc """
  Runtime API for on-demand graph compilation (HLD §8 compile endpoint).
  Accepts a bearer token via the :api pipeline. The graph's tenant is resolved
  from the authenticated user's memberships.
  """
  use NsparkWeb, :controller

  import Ash.Query, only: [filter: 2, sort: 2]
  alias Nspark.Architecture.{Graph, Node}

  def compile(conn, %{"graph_id" => graph_id}) do
    user = conn.assigns[:current_user]

    if is_nil(user) do
      conn |> put_status(401) |> json(%{error: "unauthorized"})
    else
      case find_with_tenant(Graph, graph_id, user) do
        nil ->
          conn |> put_status(404) |> json(%{error: "graph not found"})

        {graph, org_id} ->
          opts = [tenant: org_id, actor: user]
          nodes = Node |> filter(graph_id == ^graph.id) |> sort(inserted_at: :asc) |> Ash.read!(opts)
          resolution = Nspark.Registry.resolve_skills(nodes, opts)

          if resolution.problems != [] do
            conn
            |> put_status(422)
            |> json(%{
              error: "unresolved_skills",
              unresolved:
                Enum.map(resolution.problems, fn p ->
                  %{node_id: p.node_id, source_asset_id: p.source_asset_id, reason: p.reason}
                end)
            })
          else
            compiled =
              Nspark.Compiler.compile(resolution.nodes, [], resolved_assets: resolution.manifest)

            json(conn, %{
              graph_id: graph.id,
              graph_name: graph.name,
              graph_version: graph.graph_version,
              compiled: %{
                markdown: compiled.markdown,
                token_estimate: compiled.token_estimate,
                included: compiled.included,
                excluded: compiled.excluded,
                resolved_skills: compiled.resolved_assets
              }
            })
          end
      end
    end
  end

  @doc """
  Format-first export (BUILD_PLAN Phase 5): return the graph's control layer as a
  ready-to-paste PromptBasic deliverable (execution contract + rendered program),
  served as downloadable `text/plain`.
  """
  def export(conn, %{"graph_id" => graph_id}) do
    user = conn.assigns[:current_user]

    if is_nil(user) do
      conn |> put_status(401) |> json(%{error: "unauthorized"})
    else
      case find_with_tenant(Graph, graph_id, user) do
        nil ->
          conn |> put_status(404) |> json(%{error: "graph not found"})

        {graph, org_id} ->
          opts = [tenant: org_id, actor: user]
          nodes = Node |> filter(graph_id == ^graph.id) |> sort(inserted_at: :asc) |> Ash.read!(opts)
          body = Nspark.PromptBasic.Export.render(nodes)

          conn
          |> put_resp_content_type("text/plain")
          |> put_resp_header("content-disposition", ~s(attachment; filename="#{graph.slug}.promptbasic.md"))
          |> send_resp(200, body)
      end
    end
  end

  defp find_with_tenant(resource, id, user) do
    user.id
    |> Nspark.Accounts.memberships_for_user!()
    |> Enum.find_value(fn m ->
      case Ash.get(resource, id, tenant: m.organization_id, actor: user) do
        {:ok, record} -> {record, m.organization_id}
        _ -> nil
      end
    end)
  end
end
