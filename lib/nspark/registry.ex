defmodule Nspark.Registry do
  @moduledoc """
  The Knowledge Registry: reusable assets (skills, policies, schemas, memory
  templates) and packages that bundle them. See docs/HLD.md §4 and UX §4.3.

  Nodes reference registry assets via `Node.source_asset_id` — a "linked" node
  tracks the asset (updates propagate); a "cloned" node copies content and
  detaches. That distinction lives on the Node, not here.
  """
  use Ash.Domain, otp_app: :nspark, extensions: [AshAdmin.Domain, AshPaperTrail.Domain]

  admin do
    show? true
  end

  paper_trail do
    include_versions? true
  end

  resources do
    resource Nspark.Registry.Skill
    resource Nspark.Registry.Policy
    resource Nspark.Registry.Schema
    resource Nspark.Registry.MemoryTemplate
    resource Nspark.Registry.Package
    resource Nspark.Registry.PackageItem
  end
end
