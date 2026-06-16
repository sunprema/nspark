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
          compiled = Nspark.Compiler.compile(nodes)

          json(conn, %{
            graph_id: graph.id,
            graph_name: graph.name,
            graph_version: graph.graph_version,
            compiled: %{
              markdown: compiled.markdown,
              token_estimate: compiled.token_estimate,
              included: compiled.included,
              excluded: compiled.excluded
            }
          })
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
