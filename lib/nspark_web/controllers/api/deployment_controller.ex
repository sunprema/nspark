defmodule NsparkWeb.Api.DeploymentController do
  @moduledoc """
  Runtime API for executing a pinned deployment with variable injection
  (HLD §8 run endpoint). Accepts a bearer token via the :api pipeline.
  The deployment's tenant is resolved from the authenticated user's memberships.
  """
  use NsparkWeb, :controller

  alias Nspark.Deployments.Deployment

  def run(conn, %{"deployment_id" => dep_id} = params) do
    user = conn.assigns[:current_user]
    variables = Map.get(params, "variables", %{})

    if is_nil(user) do
      conn |> put_status(401) |> json(%{error: "unauthorized"})
    else
      case find_with_tenant(Deployment, dep_id, user) do
        nil ->
          conn |> put_status(404) |> json(%{error: "deployment not found"})

        {dep, org_id} ->
          dep = Ash.load!(dep, [:graph_version], tenant: org_id, actor: user)

          if dep.status != :active do
            conn |> put_status(422) |> json(%{error: "deployment is not active"})
          else
            snapshot = dep.graph_version.graph_snapshot
            nodes = snapshot_to_nodes(snapshot["nodes"] || [])
            nodes_injected = inject_variables(nodes, variables)
            compiled = Nspark.Compiler.compile(nodes_injected)

            json(conn, %{
              deployment_id: dep.id,
              environment: dep.environment,
              endpoint_slug: dep.endpoint_slug,
              deployed_version: dep.deployed_version,
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

  defp snapshot_to_nodes(node_maps) do
    Enum.map(node_maps, fn n ->
      %{
        type: String.to_existing_atom(n["type"]),
        label: n["label"] || "",
        content: n["content"] || "",
        is_muted: n["is_muted"] || false
      }
    end)
  end

  defp inject_variables(nodes, variables) when map_size(variables) == 0, do: nodes

  defp inject_variables(nodes, variables) do
    Enum.map(nodes, fn node ->
      content = node.content || ""

      injected =
        Enum.reduce(variables, content, fn {key, value}, acc ->
          replacement = if is_binary(value), do: value, else: Jason.encode!(value)
          String.replace(acc, "{#{key}}", replacement)
        end)

      Map.put(node, :content, injected)
    end)
  end
end
