defmodule Nspark.Registry.SkillLifecycleTest do
  use Nspark.DataCase, async: true

  alias Nspark.Accounts.{Membership, Organization}
  alias Nspark.Registry.Skill

  setup do
    org = Ash.create!(Organization, %{name: "Life", slug: "life-org"})
    seed = [tenant: org.id, authorize?: false]
    skill = Ash.create!(Skill, %{name: "S", content: "c"}, seed)

    %{
      org: org,
      seed: seed,
      skill: skill,
      editor: user_with_role(org, :editor, "ed@x.com"),
      admin: user_with_role(org, :admin, "ad@x.com")
    }
  end

  defp user_with_role(org, role, email) do
    user = Ash.Seed.seed!(Nspark.Accounts.User, %{email: email})
    Ash.create!(Membership, %{user_id: user.id, organization_id: org.id, role: role})
    user
  end

  test "create yields a draft v1", %{skill: skill} do
    assert skill.status == :draft
    assert skill.version == 1
  end

  test "publish bumps the version and marks it published", %{org: org, skill: skill, admin: admin} do
    published = Ash.update!(skill, %{}, tenant: org.id, actor: admin, action: :publish)
    assert published.status == :published
    assert published.version == 2
    assert published.updated_by_id == admin.id
  end

  test "archive deprecates the skill", %{org: org, skill: skill, admin: admin} do
    archived = Ash.update!(skill, %{}, tenant: org.id, actor: admin, action: :archive)
    assert archived.status == :deprecated
  end

  test "editors can edit content but cannot publish", %{org: org, skill: skill, editor: editor} do
    updated = Ash.update!(skill, %{content: "new body"}, tenant: org.id, actor: editor)
    assert updated.content == "new body"
    assert updated.updated_by_id == editor.id

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.update(skill, %{}, tenant: org.id, actor: editor, action: :publish)
  end
end
