defmodule NsparkWeb.Api.DeploymentController do
  @moduledoc """
  Runtime API for executing a pinned deployment with variable injection and
  multi-agent orchestration (HLD §8 run endpoint). Accepts a bearer token
  via the :api pipeline. The deployment's tenant is resolved from the
  authenticated user's memberships.

  Flow:
  1. Load deployment → graph_version → graph_snapshot
  2. Compile snapshot into a prompt artifact (may contain [AGENT: ...] directives)
  3. Run Nspark.Orchestrator: dispatch sub-agents, inject outputs, render final prompt
  4. Return resolved prompt + orchestration metadata
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
            nodes = snapshot["nodes"] || []
            edges = snapshot["edges"] || []

            compiled = Nspark.Compiler.compile(nodes, edges)

            case Nspark.Orchestrator.run(compiled.markdown, variables, tenant: org_id) do
              {:ok, %{prompt: prompt, sub_agent_calls: calls}} ->
                json(conn, %{
                  deployment_id: dep.id,
                  environment: dep.environment,
                  endpoint_slug: dep.endpoint_slug,
                  deployed_version: dep.deployed_version,
                  prompt: prompt,
                  sub_agent_calls: calls,
                  resolved_skills: dep.graph_version.resolved_skills,
                  stats: %{
                    token_estimate: compiled.token_estimate,
                    included: compiled.included,
                    excluded: compiled.excluded
                  }
                })

              {:error, %{reason: reason, sub_agent_calls: calls}} ->
                conn
                |> put_status(422)
                |> json(%{error: reason, sub_agent_calls: calls})
            end
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
end
