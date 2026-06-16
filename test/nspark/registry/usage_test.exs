defmodule Nspark.Registry.UsageTest do
  use Nspark.DataCase, async: true

  alias Nspark.Accounts.Organization
  alias Nspark.Architecture.{Graph, GraphVersion, Node}
  alias Nspark.Deployments.Deployment
  alias Nspark.Projects.Project
  alias Nspark.Registry
  alias Nspark.Registry.Skill

  setup do
    org = Ash.create!(Organization, %{name: "Use", slug: "use-org"})
    t = [tenant: org.id, authorize?: false]
    project = Ash.create!(Project, %{name: "P", status: :active}, t)
    %{t: t, project: project}
  end

  test "counts linked nodes and distinct consuming graphs", %{t: t, project: project} do
    skill = Ash.create!(Skill, %{name: "Planning", content: "PLAN"}, t)
    g1 = Ash.create!(Graph, %{name: "Alpha", project_id: project.id}, t)
    g2 = Ash.create!(Graph, %{name: "Beta", project_id: project.id}, t)

    # two linked nodes in g1, one in g2
    Ash.create!(Node, %{type: :skill, label: "n1", graph_id: g1.id, source_asset_id: skill.id}, t)
    Ash.create!(Node, %{type: :skill, label: "n2", graph_id: g1.id, source_asset_id: skill.id}, t)
    Ash.create!(Node, %{type: :skill, label: "n3", graph_id: g2.id, source_asset_id: skill.id}, t)
    # an unlinked node should not count
    Ash.create!(Node, %{type: :persona, label: "p", graph_id: g1.id}, t)

    usage = Registry.skill_usage(skill.id, t)

    assert usage.nodes == 3
    assert Enum.map(usage.graphs, & &1.name) == ["Alpha", "Beta"]
    assert usage.deployments == []
  end

  test "a skill referenced nowhere has empty usage", %{t: t} do
    skill = Ash.create!(Skill, %{name: "Unused", content: "x"}, t)
    assert Registry.skill_usage(skill.id, t) == %{nodes: 0, graphs: [], deployments: []}
  end

  test "counts deployments whose frozen snapshot embeds the skill", %{t: t, project: project} do
    skill = Ash.create!(Skill, %{name: "Cited", content: "CITE"}, t)
    graph = Ash.create!(Graph, %{name: "Gamma", project_id: project.id}, t)

    snapshot = %{
      "nodes" => [
        %{"id" => "a", "type" => "skill", "source_asset_id" => skill.id},
        %{"id" => "b", "type" => "persona", "source_asset_id" => nil}
      ],
      "edges" => []
    }

    version =
      Ash.create!(
        GraphVersion,
        %{version_number: 1, graph_id: graph.id, graph_snapshot: snapshot},
        t
      )

    Ash.create!(
      Deployment,
      %{
        environment: :production,
        project_id: project.id,
        graph_version_id: version.id,
        deployed_version: 1
      },
      Keyword.put(t, :action, :deploy)
    )

    usage = Registry.skill_usage(skill.id, t)

    assert [%{environment: :production}] = usage.deployments
    # snapshot-only reference: no live linked nodes
    assert usage.nodes == 0
  end
end
