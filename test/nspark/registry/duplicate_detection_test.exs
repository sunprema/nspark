defmodule Nspark.Registry.DuplicateDetectionTest do
  use Nspark.DataCase, async: true

  alias Nspark.Accounts.Organization
  alias Nspark.Architecture.{Graph, Node}
  alias Nspark.Projects.Project
  alias Nspark.Registry
  alias Nspark.Registry.Skill

  setup do
    org = Ash.create!(Organization, %{name: "Dup", slug: "dup-org"})
    t = [tenant: org.id, authorize?: false]
    project = Ash.create!(Project, %{name: "P", status: :active}, t)
    g1 = Ash.create!(Graph, %{name: "Alpha", project_id: project.id}, t)
    g2 = Ash.create!(Graph, %{name: "Beta", project_id: project.id}, t)
    %{t: t, g1: g1, g2: g2}
  end

  defp skill_node(content, graph, t, attrs \\ %{}) do
    Ash.create!(
      Node,
      Map.merge(%{type: :skill, label: "Citation", content: content, graph_id: graph.id}, attrs),
      t
    )
  end

  @dup "Always cite a source for every factual claim using [ref:N]."

  test "groups identical skill content across graphs", %{t: t, g1: g1, g2: g2} do
    skill_node(@dup, g1, t)
    skill_node("  Always cite a SOURCE for every  factual claim using [ref:N].  ", g2, t)
    skill_node("Something else entirely, unrelated content here.", g1, t)

    [group] = Registry.duplicate_skill_candidates(t)

    assert group.count == 2
    assert Enum.map(group.graphs, & &1.name) == ["Alpha", "Beta"]
    assert length(group.node_ids) == 2
  end

  test "ignores content that appears only once", %{t: t, g1: g1} do
    skill_node(@dup, g1, t)
    assert Registry.duplicate_skill_candidates(t) == []
  end

  test "ignores trivially short content", %{t: t, g1: g1, g2: g2} do
    skill_node("cite it", g1, t)
    skill_node("cite it", g2, t)
    assert Registry.duplicate_skill_candidates(t) == []
  end

  test "excludes nodes already linked to a Skill", %{t: t, g1: g1, g2: g2} do
    skill = Ash.create!(Skill, %{name: "Cite", content: @dup}, t)
    skill_node(@dup, g1, t, %{source_asset_id: skill.id, content: nil})
    skill_node(@dup, g2, t, %{source_asset_id: skill.id, content: nil})

    assert Registry.duplicate_skill_candidates(t) == []
  end
end
