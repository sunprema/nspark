defmodule Nspark.Architecture.DeployImpactTest do
  use Nspark.DataCase, async: true

  alias Nspark.Accounts.{Membership, Organization}
  alias Nspark.Architecture
  alias Nspark.Architecture.{Graph, Node}
  alias Nspark.Projects.Project

  setup do
    org = Ash.create!(Organization, %{name: "Deploy", slug: "deploy-org"})
    user = Ash.Seed.seed!(Nspark.Accounts.User, %{email: "deploy@example.com"})
    Ash.create!(Membership, %{user_id: user.id, organization_id: org.id, role: :owner})

    t = [tenant: org.id, authorize?: false]
    project = Ash.create!(Project, %{name: "P", status: :active}, t)
    graph = Ash.create!(Graph, %{name: "G", project_id: project.id}, t)
    %{org: org, user: user, t: t, project: project, graph: graph}
  end

  defp persona(graph, content, t),
    do: Ash.create!(Node, %{type: :persona, label: "P", content: content, graph_id: graph.id}, t)

  defp publish(graph, nodes, ctx, opts \\ []) do
    {:ok, version} = Architecture.publish_graph(graph, nodes, [], ctx.user, ctx.org.id, opts)
    {version, Ash.reload!(graph, ctx.t)}
  end

  defp deploy(version, env, ctx) do
    Nspark.Deployments.deploy_version(
      %{
        environment: env,
        project_id: ctx.project.id,
        graph_version_id: version.id,
        deployed_version: version.version_number
      },
      ctx.t
    )
  end

  test "no active deployment in the environment ⇒ :no_active_deployment", ctx do
    node = persona(ctx.graph, "Greet {first}", ctx.t)
    {v1, _graph} = publish(ctx.graph, [node], ctx)

    assert Architecture.deploy_impact(v1, :production, ctx.t) == :no_active_deployment
  end

  test "redeploying the same version ⇒ :unchanged", ctx do
    node = persona(ctx.graph, "Greet {first}", ctx.t)
    {v1, _graph} = publish(ctx.graph, [node], ctx)
    {:ok, _dep} = deploy(v1, :production, ctx)

    assert Architecture.deploy_impact(v1, :production, ctx.t) == :unchanged
  end

  test "deploying a breaking version over the live one is flagged with attribution", ctx do
    node = persona(ctx.graph, "Greet {first}", ctx.t)
    {v1, graph} = publish(ctx.graph, [node], ctx)
    {:ok, _dep} = deploy(v1, :production, ctx)

    node = Ash.update!(node, %{content: "Greet {first} {company}"}, ctx.t)

    {v2, _graph} =
      publish(graph, [node], ctx, acknowledge_breaking: true, changelog: "now needs {company}")

    impact = Architecture.deploy_impact(v2, :production, ctx.t)

    assert %{level: :breaking, current_version: 1, diff: diff} = impact
    assert "requires new variable {company}" in diff["reasons"]
    assert impact.deployment.environment == :production
  end

  test "a compatible deploy over the live one is not flagged breaking", ctx do
    node = persona(ctx.graph, "Greet {first} {last}", ctx.t)
    {v1, graph} = publish(ctx.graph, [node], ctx)
    {:ok, _dep} = deploy(v1, :production, ctx)

    # Drop {last} — compatible (apps may keep supplying it harmlessly).
    node = Ash.update!(node, %{content: "Greet {first}"}, ctx.t)
    {v2, _graph} = publish(graph, [node], ctx)

    assert %{level: :compatible} = Architecture.deploy_impact(v2, :production, ctx.t)
  end

  test "impact is scoped per environment", ctx do
    node = persona(ctx.graph, "Greet {first}", ctx.t)
    {v1, graph} = publish(ctx.graph, [node], ctx)
    {:ok, _dep} = deploy(v1, :production, ctx)

    node = Ash.update!(node, %{content: "Greet {first} {company}"}, ctx.t)

    {v2, _graph} =
      publish(graph, [node], ctx, acknowledge_breaking: true, changelog: "now needs {company}")

    # Production serves v1 → breaking; staging serves nothing → no gate.
    assert %{level: :breaking} = Architecture.deploy_impact(v2, :production, ctx.t)
    assert Architecture.deploy_impact(v2, :staging, ctx.t) == :no_active_deployment
  end
end
