defmodule Nspark.Architecture.VersionDiffPublishTest do
  use Nspark.DataCase, async: true

  alias Nspark.Accounts.{Membership, Organization}
  alias Nspark.Architecture
  alias Nspark.Architecture.{Edge, Graph, Node}
  alias Nspark.Projects.Project
  require Ash.Query

  setup do
    org = Ash.create!(Organization, %{name: "Diff", slug: "diff-org"})
    user = Ash.Seed.seed!(Nspark.Accounts.User, %{email: "diff@example.com"})
    Ash.create!(Membership, %{user_id: user.id, organization_id: org.id, role: :owner})

    t = [tenant: org.id, authorize?: false]
    project = Ash.create!(Project, %{name: "P", status: :active}, t)
    graph = Ash.create!(Graph, %{name: "G", project_id: project.id}, t)
    %{org: org, user: user, t: t, graph: graph}
  end

  # Publish the current node set, returning {version, reloaded_graph} so the next
  # publish sees the bumped graph_version.
  defp publish(graph, nodes, ctx, opts \\ []) do
    case Architecture.publish_graph(graph, nodes, [], ctx.user, ctx.org.id, opts) do
      {:ok, version} -> {version, Ash.reload!(graph, ctx.t)}
      other -> other
    end
  end

  defp persona(graph, content, t),
    do: Ash.create!(Node, %{type: :persona, label: "P", content: content, graph_id: graph.id}, t)

  test "first publish records an initial diff and is never gated", ctx do
    node = persona(ctx.graph, "You are helpful", ctx.t)
    {version, _graph} = publish(ctx.graph, [node], ctx)

    assert version.diff_summary["level"] in [:initial, "initial"]
    assert version.version_number == 1
  end

  test "a compatible change (removed variable) publishes clean", ctx do
    node = persona(ctx.graph, "Greet {first} {last}", ctx.t)
    {_v1, graph} = publish(ctx.graph, [node], ctx)

    node = Ash.update!(node, %{content: "Greet {first}"}, ctx.t)
    {v2, _graph} = publish(graph, [node], ctx)

    reloaded = Ash.get!(Architecture.GraphVersion, v2.id, ctx.t)
    assert reloaded.diff_summary["level"] == "compatible"
    assert reloaded.diff_summary["variables"]["removed"] == ["last"]
  end

  test "a breaking change is blocked without acknowledgement", ctx do
    node = persona(ctx.graph, "Greet {first}", ctx.t)
    {_v1, graph} = publish(ctx.graph, [node], ctx)

    node = Ash.update!(node, %{content: "Greet {first} {company}"}, ctx.t)

    assert {:error, {:breaking_change, diff}} =
             Architecture.publish_graph(graph, [node], [], ctx.user, ctx.org.id)

    assert diff["level"] == :breaking
    assert "requires new variable {company}" in diff["reasons"]

    # No second version was created and the graph version was not bumped.
    assert [_only_one] = Architecture.versions_for_graph!(graph.id, ctx.t)
    assert Ash.reload!(graph, ctx.t).graph_version == graph.graph_version
  end

  test "acknowledging a breaking change without a changelog is rejected", ctx do
    node = persona(ctx.graph, "Greet {first}", ctx.t)
    {_v1, graph} = publish(ctx.graph, [node], ctx)

    node = Ash.update!(node, %{content: "Greet {first} {company}"}, ctx.t)

    assert {:error, {:changelog_required, _diff}} =
             Architecture.publish_graph(graph, [node], [], ctx.user, ctx.org.id,
               acknowledge_breaking: true
             )

    assert [_only_one] = Architecture.versions_for_graph!(graph.id, ctx.t)
  end

  test "publish preserves edge branch metadata so branch-only variables are optional", ctx do
    # A conditional gate routes to a constraint on its "yes" branch; the
    # constraint's variable is needed only when the branch fires. This goes
    # through the real path (serialize_snapshot → contract), which previously
    # dropped edge metadata and marked every variable required.
    gate = Ash.create!(Node, %{type: :conditional, label: "Gate", content: "{score} > 0.8", graph_id: ctx.graph.id}, ctx.t)

    branch_target =
      Ash.create!(Node, %{type: :constraint, label: "Escalate", content: "Notify {oncall}", graph_id: ctx.graph.id}, ctx.t)

    Ash.create!(
      Edge,
      %{
        graph_id: ctx.graph.id,
        source_node_id: gate.id,
        target_node_id: branch_target.id,
        metadata: %{"branch" => "yes"}
      },
      ctx.t
    )

    edges = Edge |> Ash.Query.filter(graph_id == ^ctx.graph.id) |> Ash.read!(ctx.t)
    {:ok, version} = Architecture.publish_graph(ctx.graph, [gate, branch_target], edges, ctx.user, ctx.org.id)

    vars = version.input_contract["variables"]
    assert vars["score"]["required"] == true
    assert vars["oncall"]["required"] == false
  end

  test "a breaking change publishes with acknowledgement and a changelog", ctx do
    node = persona(ctx.graph, "Greet {first}", ctx.t)
    {_v1, graph} = publish(ctx.graph, [node], ctx)

    node = Ash.update!(node, %{content: "Greet {first} {company}"}, ctx.t)

    {v2, _graph} =
      publish(graph, [node], ctx,
        acknowledge_breaking: true,
        changelog: "  Now requires {company}  "
      )

    reloaded = Ash.get!(Architecture.GraphVersion, v2.id, ctx.t)
    assert reloaded.version_number == 2
    assert reloaded.diff_summary["level"] == "breaking"
    assert reloaded.diff_summary["variables"]["added"] == ["company"]
    # changelog is trimmed
    assert reloaded.changelog == "Now requires {company}"
  end
end
