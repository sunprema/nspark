defmodule Nspark.Registry.ResolutionTest do
  use Nspark.DataCase, async: true

  alias Nspark.Accounts.Organization
  alias Nspark.Registry
  alias Nspark.Registry.Skill

  setup do
    org = Ash.create!(Organization, %{name: "Res", slug: "res-org"})
    %{t: [tenant: org.id, authorize?: false]}
  end

  defp skill_node(id, asset_id, content \\ "local copy"),
    do: %{id: id, type: :skill, source_asset_id: asset_id, content: content}

  test "resolves linked skill content from the registry and reports the version", %{t: t} do
    skill = Ash.create!(Skill, %{name: "Planning", content: "PLAN THIS"}, t)

    nodes = [
      skill_node("n1", skill.id, "stale copy"),
      %{id: "n2", type: :persona, source_asset_id: nil, content: "You are X"}
    ]

    result = Registry.resolve_skills(nodes, t)

    assert Enum.find(result.nodes, &(&1.id == "n1")).content == "PLAN THIS"
    # non-linked nodes pass through untouched
    assert Enum.find(result.nodes, &(&1.id == "n2")).content == "You are X"
    assert result.manifest == [%{id: skill.id, name: "Planning", version: skill.version}]
    assert result.problems == []
  end

  test "missing skill reference yields a :missing problem and an error diagnostic", %{t: t} do
    missing = Ash.UUID.generate()
    result = Registry.resolve_skills([skill_node("n1", missing)], t)

    assert [%{node_id: "n1", source_asset_id: ^missing, reason: :missing}] = result.problems
    assert result.manifest == []
    # content is left untouched; the diagnostic is the signal
    assert Enum.find(result.nodes, &(&1.id == "n1")).content == "local copy"

    assert [%{level: :error, code: :unresolved_skill, node_ids: ["n1"]}] =
             Registry.resolution_diagnostics(result.problems)
  end

  test "deprecated skill reference yields a :deprecated problem and no manifest entry", %{t: t} do
    skill = Ash.create!(Skill, %{name: "Old", content: "X"}, t)
    skill = Ash.update!(skill, %{}, t ++ [action: :archive])
    result = Registry.resolve_skills([skill_node("n1", skill.id)], t)

    assert [%{node_id: "n1", reason: :deprecated}] = result.problems
    assert result.manifest == []
  end

  test "resolves string-keyed snapshot nodes", %{t: t} do
    skill = Ash.create!(Skill, %{name: "Retr", content: "RETRIEVE"}, t)
    nodes = [%{"id" => "n1", "type" => "skill", "source_asset_id" => skill.id, "content" => "old"}]

    result = Registry.resolve_skills(nodes, t)
    assert Enum.find(result.nodes, &(&1["id"] == "n1"))["content"] == "RETRIEVE"
  end

  test "a graph with no linked skills passes through without a registry query", %{t: t} do
    nodes = [%{id: "n1", type: :persona, source_asset_id: nil, content: "hi"}]
    assert %{nodes: ^nodes, manifest: [], problems: []} = Registry.resolve_skills(nodes, t)
  end
end
