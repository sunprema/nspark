defmodule Nspark.Architecture.EdgeType do
  @moduledoc "Dependency relationship types between nodes. See docs/HLD.md §4."
  use Ash.Type.Enum, values: [:compile, :dependency, :reference]
end
