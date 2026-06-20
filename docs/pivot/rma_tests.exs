# PromptBasic Test layer — scenario coverage for the RMA agent.
#
# Usage:  elixir docs/pivot/rma_tests.exs
#
# Each scenario is a slice of the intended-behavior spec the static lens CANNOT infer:
# "given this state + these true conditions, the agent should do X." The deterministic
# Selector runs real priority/state/memory resolution and we assert the outcome.
#
# Scenarios drain to [OTHERWISE] expose COVERAGE GAPS — the capability the parser can't provide.

Code.require_file("promptbasic_engine.exs", __DIR__)

alias PromptBasic.{Parser, Selector}

prog = Parser.parse_file(Path.join(__DIR__, "PROMPT_BASIC_RMA.md"))

# ── scenarios ───────────────────────────────────────────────────────────────
# given:  %{state, memory, conds}   expect: subset of %{fires, state_to, tool, handled}
# kind:   :spec (should pass) | :gap (documents a coverage hole we expect to FAIL today)

scenarios = [
  # — happy path, should all pass —
  %{name: "intake: start return with order id", kind: :spec,
    given: %{state: "intake", conds: ["user_wants_return", "has_order_id"]},
    expect: %{fires: "R2", state_to: "verifying", tool: "lookup_order"}},

  %{name: "intake: start return without order id → ask", kind: :spec,
    given: %{state: "intake", conds: ["user_wants_return", "no_order_id"]},
    expect: %{fires: "R3", handled: true}},

  %{name: "verifying: eligible → choose resolution", kind: :spec,
    given: %{state: "verifying", conds: ["order_eligible"]},
    expect: %{state_to: "choosing_resolution"}},

  %{name: "verifying: not eligible → closed", kind: :spec,
    given: %{state: "verifying", conds: ["order_not_eligible"]},
    expect: %{state_to: "closed"}},

  %{name: "choose refund → awaiting + label", kind: :spec,
    given: %{state: "choosing_resolution", conds: ["wants_refund"]},
    expect: %{fires: "R6", state_to: "awaiting_return", tool: "generate_return_label"}},

  %{name: "awaiting: item received → inspecting", kind: :spec,
    given: %{state: "awaiting_return", memory: %{"item_received" => "true"}, conds: []},
    expect: %{state_to: "inspecting", tool: "flag_inspection"}},

  %{name: "awaiting: status check while not received", kind: :spec,
    given: %{state: "awaiting_return", memory: %{"item_received" => "false"}, conds: ["user_asks_status"]},
    expect: %{fires: "R9", handled: true}},

  %{name: "inspecting: pass + refund → refund issued, closed", kind: :spec,
    given: %{state: "inspecting", memory: %{"inspection_passed" => "true", "resolution_choice" => "refund"}, conds: []},
    expect: %{state_to: "closed", tool: "issue_refund"}},

  %{name: "global guard: angry user from any state → escalated", kind: :spec,
    given: %{state: "awaiting_return", conds: ["user_angry"]},
    expect: %{fires: "R1", state_to: "escalated", tool: "create_support_ticket"}},

  # — coverage gaps (intended behavior with NO rule today; we expect these to FAIL) —
  %{name: "GAP: user chooses repair (offered in prompt)", kind: :gap,
    given: %{state: "choosing_resolution", conds: ["wants_repair"]},
    expect: %{handled: true}},

  %{name: "GAP: escalated user asks for an update", kind: :gap,
    given: %{state: "escalated", conds: ["user_asks_status"]},
    expect: %{handled: true}},

  %{name: "GAP: inspection passes but resolution was repair", kind: :gap,
    given: %{state: "inspecting", memory: %{"inspection_passed" => "true", "resolution_choice" => "repair"}, conds: []},
    expect: %{handled: true}},

  # — tie surfacing: both refund and replacement asserted true —
  %{name: "AMBIGUOUS: user says refund and replacement", kind: :spec,
    given: %{state: "choosing_resolution", conds: ["wants_refund", "wants_replacement"]},
    expect: %{fires: "R6"}}
]

# ── runner ──────────────────────────────────────────────────────────────────
defmodule Runner do
  def check(prog, sc) do
    res = Selector.fire(prog, sc.given)
    fired = if res.rule == :otherwise, do: :otherwise, else: res.rule.id
    handled = res.rule != :otherwise

    failures =
      Enum.flat_map(sc.expect, fn
        {:fires, want} -> cmp("fires", want, fired)
        {:state_to, want} -> cmp("state_to", want, res.result.state_to)
        {:tool, want} -> if want in res.result.tools, do: [], else: ["tool #{inspect(want)} not called (called: #{inspect(res.result.tools)})"]
        {:handled, want} -> cmp("handled", want, handled)
      end)

    %{sc: sc, fired: fired, res: res, handled: handled, failures: failures}
  end

  defp cmp(_f, want, want), do: []
  defp cmp(f, want, got), do: ["#{f}: expected #{inspect(want)}, got #{inspect(got)}"]

  def transition(%{result: %{state_to: nil}}), do: ""
  def transition(%{result: %{state_to: s}}), do: "  →state #{s}"
end

results = Enum.map(scenarios, &Runner.check(prog, &1))

IO.puts("\n  PromptBasic Test layer — RMA   (#{length(scenarios)} scenarios)\n")

Enum.each(results, fn r ->
  drained? = match?(%{drained: true}, r.res.result)
  tie_note = if length(r.res.tie) > 1, do: "  ⚑ tie #{inspect(r.res.tie)} → #{r.fired} wins", else: ""

  {icon, label} =
    cond do
      r.failures == [] -> {"✅", "PASS"}
      r.sc.kind == :gap and drained? -> {"❌", "GAP"}
      true -> {"🔴", "FAIL"}
    end

  IO.puts("  #{icon} #{label}  #{r.sc.name}")
  IO.puts("        fired: #{r.fired}#{Runner.transition(r.res)}#{tie_note}")
  Enum.each(r.failures, &IO.puts("        ↳ #{&1}"))
end)

passes = Enum.count(results, &(&1.failures == []))
gaps = Enum.count(results, &(&1.sc.kind == :gap and &1.failures != []))
fails = Enum.count(results, &(&1.sc.kind == :spec and &1.failures != []))

IO.puts("\n  ── #{passes} pass · #{gaps} coverage gap · #{fails} regression ──")

if gaps > 0 do
  IO.puts("\n  COVERAGE GAPS (intended inputs that drain to OTHERWISE — fix in the agent):")
  results
  |> Enum.filter(&(&1.sc.kind == :gap and &1.failures != []))
  |> Enum.each(&IO.puts("    ❌ #{&1.sc.name}"))
end

IO.puts("")
