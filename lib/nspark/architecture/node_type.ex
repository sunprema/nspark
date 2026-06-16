defmodule Nspark.Architecture.NodeType do
  @moduledoc "The nine graph node types. See docs/HLD.md §4."
  use Ash.Type.Enum,
    values: [
      :persona,
      :constraint,
      :context,
      :conditional,
      :skill,
      :memory,
      :tool,
      :evaluation,
      :output,
      :agent
    ]
end
