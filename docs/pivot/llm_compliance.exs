# PromptBasic LLM-compliance harness.
#
# Run:  ANTHROPIC_API_KEY=sk-ant-... mix run docs/pivot/llm_compliance.exs
#       (mix run, so Req/Jason deps are loaded)
#
# Question it answers: given the USAGE_RULES execution contract + a PromptBasic program +
# a natural-language scenario, does a real LLM select the SAME rule the deterministic
# Selector says it should? The Selector is the ground-truth oracle; the LLM is under test.
#
# A high agreement rate (~90%+) means the "format works anywhere via prompt injection" path
# is real (ship format + lens, light runtime). A low rate (~60%) means selection must happen
# in code (the engine becomes the runtime). This number decides which product to build.

Code.require_file("promptbasic_engine.exs", __DIR__)

alias PromptBasic.{Parser, Selector}

defmodule Harness do
  @model "claude-opus-4-8"
  @api "https://api.anthropic.com/v1/messages"
  @dir __DIR__

  def contract, do: File.read!(Path.join(@dir, "USAGE_RULES.md"))

  # Render the parsed program back to text WITH rule ids, so the LLM's answer space
  # (R1..Rn / OTHERWISE) matches the Selector's.
  def render(prog) do
    rules =
      prog.rules
      |> Enum.map_join("\n\n", fn r ->
        head =
          if r.priority == :otherwise,
            do: "[RULE #{r.id}] [OTHERWISE]",
            else: "[RULE #{r.id}] [PRIORITY] #{r.priority}\n[WHEN] #{when_text(r)}"

        head <> "\n" <> actions_text(r)
      end)

    """
    PROGRAM: #{prog.init_state && "initial state = #{prog.init_state}"}
    #{rules}
    """
  end

  defp when_text(%{when_op: :none}), do: "(always)"
  defp when_text(%{when_op: op, atoms: atoms}) do
    sep = case op do
      :or -> " OR "
      :and -> " AND "
      _ -> ""
    end
    Enum.map_join(atoms, sep, & &1.raw)
  end

  defp actions_text(r) do
    parts =
      Enum.map(r.tools, &"TOOL #{&1.name}") ++
        Enum.map(r.mem_writes, fn {k, v} -> "MEMORY #{k}=#{v}" end) ++
        Enum.map(r.state_writes, &"STATE→#{&1}") ++
        List.wrap(r.terminal && String.upcase(to_string(r.terminal))) ++
        (if r.has_stop, do: ["STOP"], else: [])

    "actions: " <> Enum.join(parts, "; ")
  end

  def ask(prog_text, scenario) do
    g = scenario.given
    mem = g |> Map.get(:memory, %{}) |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{v}" end)
    ctx = Map.get(scenario, :context, "")

    user = """
    #{prog_text}

    CURRENT STATE: #{Map.get(g, :state, "intake")}
    MEMORY: #{if mem == "", do: "(defaults)", else: mem}
    #{if ctx == "", do: "", else: "SITUATION: " <> ctx}
    LATEST USER MESSAGE: "#{scenario.msg}"

    Evaluate the [WHEN] conditions against this input, resolve by [PRIORITY], and decide which
    single rule fires. On the final line output exactly: ANSWER: <rule id e.g. R6, or OTHERWISE>
    """

    system =
      Harness.contract() <>
        "\n\nYou will be given a PromptBasic program with rule ids, the current state/memory, " <>
        "and a user message. Apply the execution contract above and select the one firing rule."

    body = %{
      model: @model,
      max_tokens: 2048,
      thinking: %{type: "adaptive"},
      system: system,
      messages: [%{role: "user", content: user}]
    }

    case Req.post(@api,
           json: body,
           headers: [
             {"x-api-key", System.fetch_env!("ANTHROPIC_API_KEY")},
             {"anthropic-version", "2023-06-01"}
           ],
           receive_timeout: 300_000,
           retry: :transient,
           max_retries: 4
         ) do
      {:ok, %{status: 200, body: resp}} -> {:ok, extract(resp)}
      {:ok, %{status: s, body: b}} -> {:error, "HTTP #{s}: #{inspect(b)}"}
      {:error, e} -> {:error, inspect(e)}
    end
  end

  defp extract(resp) do
    text =
      resp["content"]
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map_join("\n", & &1["text"])

    case Regex.run(~r/ANSWER:\s*(R\d+|OTHERWISE)/i, text) do
      [_, ans] -> String.upcase(ans)
      _ -> "UNPARSED(#{String.slice(text, -40, 40)})"
    end
  end
end

# ── scenarios: structured `given` (oracle) + natural-language `msg`/`context` (LLM) ──
scenarios = [
  %{name: "intake: return w/ order id", given: %{state: "intake", conds: ["user_wants_return", "has_order_id"]},
    msg: "Hi, I'd like to return my order — the order number is A-10293."},
  %{name: "intake: return w/o order id", given: %{state: "intake", conds: ["user_wants_return", "no_order_id"]},
    msg: "I want to return something I bought last week."},
  %{name: "verifying: eligible", given: %{state: "verifying", conds: ["order_eligible"]},
    context: "Order lookup shows it was purchased 8 days ago; the return window is 30 days.",
    msg: "(system: eligibility check complete)"},
  %{name: "choose refund", given: %{state: "choosing_resolution", conds: ["wants_refund"]},
    msg: "I'd like a refund, please."},
  %{name: "choose replacement", given: %{state: "choosing_resolution", conds: ["wants_replacement"]},
    msg: "Can you send me a replacement unit instead?"},
  %{name: "awaiting: status check", given: %{state: "awaiting_return", memory: %{"item_received" => "false"}, conds: ["user_asks_status"]},
    msg: "Has my return arrived at your warehouse yet?"},
  %{name: "awaiting: item received", given: %{state: "awaiting_return", memory: %{"item_received" => "true"}, conds: []},
    context: "The carrier just confirmed the returned item was delivered to the warehouse.",
    msg: "(system: item received event)"},
  %{name: "inspecting: pass + refund", given: %{state: "inspecting", memory: %{"inspection_passed" => "true", "resolution_choice" => "refund"}, conds: []},
    context: "QA inspection passed; the customer had chosen a refund.",
    msg: "(system: inspection complete)"},
  %{name: "global guard: angry user", given: %{state: "awaiting_return", conds: ["user_angry"]},
    msg: "This is ridiculous, I've been waiting forever. Let me talk to a human RIGHT NOW."},
  %{name: "GAP: wants repair", given: %{state: "choosing_resolution", conds: ["wants_repair"]},
    msg: "Actually, could you just repair it rather than refund or replace?"},
  %{name: "GAP: escalated follow-up", given: %{state: "escalated", conds: ["user_asks_status"]},
    msg: "Any update on the support ticket you opened for me?"}
]

# ── run ──
unless System.get_env("ANTHROPIC_API_KEY") do
  IO.puts("\n  ANTHROPIC_API_KEY not set. Run:\n  ANTHROPIC_API_KEY=sk-ant-... mix run docs/pivot/llm_compliance.exs\n")
  System.halt(1)
end

prog = Parser.parse_file(Path.join(Path.dirname(__ENV__.file), "PROMPT_BASIC_RMA.md"))
prog_text = Harness.render(prog)

IO.puts("\n  PromptBasic LLM-compliance — RMA   model=claude-opus-4-8   (#{length(scenarios)} scenarios)\n")

results =
  Enum.map(scenarios, fn sc ->
    oracle = Selector.fire(prog, sc.given)
    truth = if oracle.rule == :otherwise, do: "OTHERWISE", else: oracle.rule.id

    {llm, note} =
      case Harness.ask(prog_text, sc) do
        {:ok, ans} -> {ans, ""}
        {:error, e} -> {"ERROR", e}
      end

    agree = llm == truth
    icon = if agree, do: "✅", else: "❌"
    IO.puts("  #{icon} #{String.pad_trailing(sc.name, 30)} oracle=#{String.pad_trailing(truth, 10)} llm=#{llm}")
    if note != "", do: IO.puts("        #{note}")
    %{agree: agree, truth: truth, llm: llm, sc: sc}
  end)

agreed = Enum.count(results, & &1.agree)
rate = Float.round(agreed / length(results) * 100, 1)
IO.puts("\n  ── agreement: #{agreed}/#{length(results)} = #{rate}% ──")
IO.puts("  (≥90% → format-first is viable; ~60% → selection must move into the engine)\n")
