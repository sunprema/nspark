defmodule Nspark.Architecture.NodeType do
  @moduledoc """
  Graph node types. See docs/HLD.md §4.

  Two layers (docs/pivot/DESIGN_MEMO_two_layer_lens.md §3):

    * **Context layer** (always in the prompt): persona, constraint, context, skill,
      memory, tool, evaluation, output, agent, conditional.
    * **Control layer** (PromptBasic, conditional): `rule` (a `[WHEN]` → actions card,
      flat — no nested control flow) and `state` (a node in the state machine; edges are
      `[STATE]` transitions). Priority is vertical stack order within a state.
  """
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
      :agent,
      :rule,
      :state
    ]
end
