defmodule Nspark.PromptBasic.Export do
  @moduledoc """
  Format-first export (BUILD_PLAN Phase 5): turn a graph's control layer into a
  ready-to-paste PromptBasic deliverable that works in any LLM surface with no runtime.

  `render/2` bundles the **execution contract** (how a model must interpret the bracket
  tokens — the `USAGE_RULES` injection validated at 11/11 in the LLM-compliance harness)
  with the **rendered program** (`Compiler.to_source/3`). `program/2` returns just the
  program; `contract/0` just the contract.

  Exporting from the graph's node `content` preserves the author's exact rule text (it does
  not round-trip through the IR), so re-export is faithful.
  """

  alias Nspark.PromptBasic.Compiler

  @contract """
  # PromptBasic Execution Contract

  You are operating under PromptBasic, a structured rule system for controlling agent
  behavior. Interpret the rules below as a behavioral execution policy — not as prose,
  and not as code.

  ## Rule evaluation (every turn)
  1. Read all rules.
  2. Evaluate each `[WHEN]` condition semantically (natural language), against the user
     input, the current `[STATE]`, and `[MEMORY]`.
  3. Collect all matching rules.
  4. If several match, pick the highest `[PRIORITY]` (higher number wins); on a tie, the
     rule that appears first wins.
  5. Execute the selected rule's actions in order; `[STOP]` halts immediately.
  6. If no rule matches, execute `[OTHERWISE]`.

  Select exactly one rule per turn. Never merge or execute conflicting rules.

  ## Conditions
  - `[WHEN] a AND b` — all parts must hold. `[WHEN] a OR b` — any part may hold.
  - `state = X` matches only when the current state is `X`.

  ## State & memory
  - `[STATE] X` sets the single active state; it gates which rules match next turn.
  - `[MEMORY] key = value` writes persistent memory; read it as `{{memory:key}}`.

  ## Tools
  - `[TOOL] name -> var` calls a tool and binds its output to `var`.
  - Reference an output as `{{tool:var}}`. Call the tool before any `[RESPOND]` that uses it.

  ## Actions
  `[RESPOND]` reply to the user · `[ASK]` request missing info · `[TOOL]` call a tool ·
  `[MEMORY]` write memory · `[STATE]` change state · `[STOP]` end this turn.
  """

  @doc "The execution contract to inject ahead of any PromptBasic program."
  @spec contract() :: String.t()
  def contract, do: @contract

  @doc "Just the rendered PromptBasic program for the graph's control layer."
  @spec program([map()], keyword()) :: String.t()
  def program(nodes, opts \\ []), do: nodes |> Compiler.to_source([], opts) |> String.trim()

  @doc "Ready-to-paste deliverable: execution contract + the rendered program."
  @spec render([map()], keyword()) :: String.t()
  def render(nodes, opts \\ []) do
    String.trim(@contract) <> "\n\n---\n\n" <> program(nodes, opts) <> "\n"
  end
end
