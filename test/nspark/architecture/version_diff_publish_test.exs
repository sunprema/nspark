defmodule Nspark.Architecture.VersionDiffPublishTest do
  use Nspark.DataCase, async: true

  alias Nspark.Accounts.{Membership, Organization}
  alias Nspark.Architecture
  alias Nspark.Architecture.{Graph, Node}
  alias Nspark.Projects.Project

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
