defmodule Nspark.Repo.Migrations.NullLinkedSkillNodeContent do
  @moduledoc """
  Data migration (Knowledge Layer, plan Phase 1): linked Skill nodes no longer
  own content — it is resolved from the Skill at compile time. Clear the now-dead
  copied content on existing linked skill nodes. Non-skill linked nodes keep their
  copy (they have no resolver yet).

  Irreversible by design: the original copied content is redundant with the Skill.
  """
  use Ecto.Migration

  def up do
    execute("""
    UPDATE nodes
    SET content = NULL
    WHERE type = 'skill' AND source_asset_id IS NOT NULL
    """)
  end

  def down, do: :ok
end
