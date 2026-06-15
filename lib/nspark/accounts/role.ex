defmodule Nspark.Accounts.Role do
  @moduledoc "Per-organization role held via a Membership. See docs/HLD.md §11."
  use Ash.Type.Enum, values: [:owner, :admin, :editor, :viewer]
end
