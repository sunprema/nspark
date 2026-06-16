defmodule Nspark.Architecture.PublishResolutionTest do
  use Nspark.DataCase, async: true

  alias Nspark.Accounts.{Membership, Organization}
  alias Nspark.Architecture
  alias Nspark.Architecture.{Graph, GraphVersion, Node}
  alias Nspark.Projects.Project
  alias Nspark.Registry.Skill

  setup do
    org = Ash.create!(Organization, %{name: "Pub", slug: "pub-org"})
    user = Ash.Seed.seed!(Nspark.Accounts.User, %{email: "pub@example.com"})
    Ash.create!(Membership, %{user_id: user.id, organization_id: org.id, role: :owner})

    t = [tenant: org.id, authorize?: false]
    project = Ash.create!(Project, %{name: "P", status: :active}, t)
    graph = Ash.create!(Graph, %{name: "G", project_id: project.id}, t)
    %{org: org, user: user, t: t, graph: graph}
  end

  test "freezes resolved skill content into the snapshot and records the manifest",
       %{org: org, user: user, t: t, graph: graph} do
    skill = Ash.create!(Skill, %{name: "Planning", content: "PLAN NOW"}, t)

    node =
      Ash.create!(
        Node,
        %{type: :skill, label: "Planning", graph_id: graph.id, source_asset_id: skill.id},
        t
      )

    {:ok, version} = Architecture.publish_graph(graph, [node], [], user, org.id)

    snap_node = Enum.find(version.graph_snapshot["nodes"], &(&1["id"] == node.id))
    assert snap_node["content"] == "PLAN NOW"
    # source link is preserved so deployment usage scanning still works
    assert snap_node["source_asset_id"] == skill.id

    reloaded = Ash.get!(GraphVersion, version.id, t)
    assert [%{"name" => "Planning", "version" => v}] = reloaded.resolved_skills
    assert v == skill.version
  end

  test "a later skill edit does not change an already-published snapshot",
       %{org: org, user: user, t: t, graph: graph} do
    skill = Ash.create!(Skill, %{name: "Plan", content: "V1 CONTENT"}, t)
    node = Ash.create!(Node, %{type: :skill, label: "Plan", graph_id: graph.id, source_asset_id: skill.id}, t)
    {:ok, version} = Architecture.publish_graph(graph, [node], [], user, org.id)

    Ash.update!(skill, %{content: "V2 CONTENT"}, t)

    reloaded = Ash.get!(GraphVersion, version.id, t)
    snap_node = Enum.find(reloaded.graph_snapshot["nodes"], &(&1["id"] == node.id))
    assert snap_node["content"] == "V1 CONTENT"
  end

  test "blocks publish when a linked skill is unresolved",
       %{org: org, user: user, t: t, graph: graph} do
    missing = Ash.UUID.generate()
    node = Ash.create!(Node, %{type: :skill, label: "Broken", graph_id: graph.id, source_asset_id: missing}, t)

    assert {:error, {:unresolved_skills, [%{reason: :missing}]}} =
             Architecture.publish_graph(graph, [node], [], user, org.id)

    # nothing was persisted
    assert GraphVersion |> Ash.read!(t) |> Enum.empty?()
  end
end
