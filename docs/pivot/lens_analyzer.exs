# PromptBasic Lens — static-analysis pass.
#
# Usage:  elixir docs/pivot/lens_analyzer.exs [path-to-promptbasic-file]
#
# Sound (and a couple of clearly-labelled heuristic) static checks over the parse tree.
# No LLM involved. Parser/Selector live in promptbasic_engine.exs.

Code.require_file("promptbasic_engine.exs", __DIR__)

defmodule PromptBasic.Analyzer do
  @moduledoc "Static checks over the parsed program."

  def run(prog) do
    rules = Enum.reject(prog.rules, &(&1.priority == :otherwise))

    [
      condition_inventory(rules),
      complementary_smell(rules),
      dead_states(prog, rules),
      dead_memory(prog, rules),
      tool_checks(prog, rules),
      unresolved_refs(rules),
      priority_ties(rules),
      shadowing(rules),
      preemption(rules),
      drain_note()
    ]
  end

  defp condition_inventory(rules) do
    atoms = rules |> Enum.flat_map(& &1.atoms) |> Enum.uniq_by(& &1.key)
    {sem, mem} = Enum.split_with(atoms, &(&1.kind == :semantic))
    literals = Enum.filter(atoms, & &1.literal)

    lines =
      ["#{length(sem)} semantic (LLM-judged), #{length(mem)} memory (deterministic)"] ++
        ["  semantic: " <> Enum.map_join(sem, ", ", & &1.key)] ++
        ["  memory:   " <> Enum.map_join(mem, ", ", & &1.key)] ++
        case literals do
          [] -> []
          ls -> ["  ⚠ literal-phrased (breaks on paraphrase): " <> Enum.map_join(ls, ", ", & &1.raw)]
        end

    {:info, "CONDITION INVENTORY", lines}
  end

  defp complementary_smell(rules) do
    keys = rules |> Enum.flat_map(& &1.atoms) |> Enum.map(& &1.key) |> Enum.uniq()
    pairs = for a <- keys, b <- keys, a < b, complementary_names?(a, b), uniq: true, do: {a, b}

    case pairs do
      [] -> {:ok, "COMPLEMENTARY MODELING", ["none"]}
      ps ->
        {:smell, "COMPLEMENTARY MODELING",
         Enum.map(ps, fn {a, b} ->
           "🟠 `#{a}` / `#{b}` are independent atoms but logically one tri-state " <>
             "(true/false/unknown) — 'unknown' is unhandled"
         end)}
    end
  end

  defp dead_states(prog, rules) do
    written = rules |> Enum.flat_map(& &1.state_writes) |> MapSet.new()
    read = rules |> Enum.flat_map(& &1.atoms) |> Enum.filter(&(&1.key == "state")) |> Enum.map(& &1.value) |> MapSet.new()
    dead = MapSet.difference(written, read) |> MapSet.delete(prog.init_state)

    case MapSet.to_list(dead) do
      [] -> {:ok, "DEAD STATES", ["none"]}
      ds ->
        {:error, "DEAD STATES",
         Enum.map(ds, fn s ->
           "🔴 `#{s}` is entered (via [STATE]) but no rule has [WHEN] state = #{s} — " <>
             "the user's next message dead-ends to [OTHERWISE]"
         end)}
    end
  end

  defp dead_memory(prog, rules) do
    declared = prog.decl_mem |> Map.keys() |> MapSet.new()
    read = rules |> Enum.flat_map(& &1.atoms) |> Enum.filter(&(&1.kind == :memory and &1.key != "state")) |> Enum.map(& &1.key) |> MapSet.new()
    written = rules |> Enum.flat_map(& &1.mem_writes) |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    used = MapSet.union(read, written)

    dead = MapSet.difference(declared, used)
    write_only = MapSet.difference(written, read)

    findings =
      Enum.map(MapSet.to_list(dead), fn k -> "🟠 `#{k}` declared but never read or written — dead memory" end) ++
        Enum.map(MapSet.to_list(write_only), fn k -> "🟡 `#{k}` written but no [WHEN] ever reads it" end)

    case findings do
      [] -> {:ok, "MEMORY USAGE", ["all declared keys are used"]}
      fs -> {:warn, "MEMORY USAGE", fs}
    end
  end

  defp tool_checks(prog, rules) do
    declared = prog.decl_tools |> Enum.map(& &1.name) |> MapSet.new()
    invoked = rules |> Enum.flat_map(& &1.tools) |> Enum.map(& &1.name) |> MapSet.new()
    unused = MapSet.difference(declared, invoked)
    undeclared = MapSet.difference(invoked, declared)

    findings =
      Enum.map(MapSet.to_list(unused), &"🟡 tool `#{&1}` declared but never invoked") ++
        Enum.map(MapSet.to_list(undeclared), &"🔴 tool `#{&1}` invoked but never declared")

    case findings do
      [] -> {:ok, "TOOL INVENTORY", ["#{MapSet.size(declared)} declared, all invoked, none undeclared"]}
      fs -> {:warn, "TOOL INVENTORY", fs}
    end
  end

  defp unresolved_refs(rules) do
    findings =
      Enum.flat_map(rules, fn r ->
        produced = r.tools |> Enum.map(& &1.out) |> MapSet.new()

        r.refs
        |> Enum.filter(&(&1.kind == :tool))
        |> Enum.reject(&MapSet.member?(produced, &1.var))
        |> Enum.map(&"🔴 #{r.id}: {{tool:#{&1.var}}} referenced but no tool in this rule outputs `#{&1.var}`")
      end)

    case findings do
      [] -> {:ok, "OUTPUT REFERENCES", ["all {{tool:_}} references resolve"]}
      fs -> {:error, "OUTPUT REFERENCES", fs}
    end
  end

  defp priority_ties(rules) do
    ties = rules |> Enum.group_by(& &1.priority) |> Enum.filter(fn {_p, rs} -> length(rs) > 1 end)

    case ties do
      [] -> {:ok, "PRIORITY TIES", ["none"]}
      ts ->
        {:info, "PRIORITY TIES",
         Enum.map(ts, fn {p, rs} ->
           ids = Enum.map_join(rs, ", ", & &1.id)
           verdict = if mutually_exclusive_group?(rs), do: "OK (conditions mutually exclusive)", else: "⚠ ambiguous"
           "P#{p}: #{ids} — #{verdict}"
         end)}
    end
  end

  defp shadowing(rules) do
    findings =
      for low <- rules, high <- rules, low.id != high.id, num(low.priority) < num(high.priority) do
        if subset?(keyset(high), keyset(low)) and keyset(high) != MapSet.new() do
          "🔴 #{low.id} (P#{low.priority}) is unreachable — every input matching it also matches #{high.id} (P#{high.priority}), which wins"
        end
      end
      |> Enum.reject(&is_nil/1)

    case findings do
      [] -> {:ok, "UNREACHABLE RULES", ["none (no rule is fully shadowed by a higher-priority generalisation)"]}
      fs -> {:error, "UNREACHABLE RULES", fs}
    end
  end

  defp preemption(rules) do
    findings =
      for a <- rules, b <- rules, a.id < b.id, a.section != b.section,
          abs(num(a.priority) - num(b.priority)) == 1,
          a.when_op == :and, b.when_op == :and,
          length(a.atoms) >= 2, length(b.atoms) >= 2,
          co_satisfiable?(a, b) do
        {hi, lo} = if num(a.priority) > num(b.priority), do: {a, b}, else: {b, a}
        "⚠ #{hi.id} (P#{hi.priority}, #{hi.section}) preempts #{lo.id} (P#{lo.priority}, #{lo.section}) " <>
          "when both match — #{lo.section} silently ignored. Confirm priority order is intended."
      end

    case findings do
      [] -> {:ok, "PRIORITY PREEMPTION (heuristic)", ["none"]}
      fs -> {:warn, "PRIORITY PREEMPTION (heuristic)", Enum.uniq(fs)}
    end
  end

  defp drain_note do
    {:info, "COVERAGE DRAIN",
     [
       "Structural drains (above) route to [OTHERWISE].",
       "NOTE: full input-space coverage over semantic atoms is NOT soundly decidable",
       "statically — intended-behavior gaps need the Test layer (rma_tests.exs), not the parser."
     ]}
  end

  defp num(:otherwise), do: -1
  defp num(n), do: n
  defp keyset(rule), do: rule.atoms |> Enum.map(& &1.key) |> MapSet.new()
  defp subset?(a, b), do: MapSet.subset?(a, b)

  defp complementary_names?(a, b),
    do: String.replace(a, "not_", "") == b or String.replace(b, "not_", "") == a

  defp complementary_atoms?(x, y) do
    cond do
      x.kind == :memory and y.kind == :memory and x.key == y.key ->
        (x.op == "=" and y.op == "!=" and x.value == y.value) or
          (x.op == "!=" and y.op == "=" and x.value == y.value) or
          (x.op == "=" and y.op == "=" and x.value != y.value)

      true ->
        complementary_names?(x.key, y.key)
    end
  end

  defp co_satisfiable?(a, b),
    do: not Enum.any?(a.atoms, fn x -> Enum.any?(b.atoms, fn y -> complementary_atoms?(x, y) end) end)

  defp mutually_exclusive_group?(rules) do
    pairs = for a <- rules, b <- rules, a.id < b.id, do: {a, b}
    Enum.all?(pairs, fn {a, b} -> not co_satisfiable?(a, b) end)
  end
end

defmodule PromptBasic.Report do
  def print(prog, findings) do
    IO.puts("\n  PromptBasic Lens — static analysis")
    IO.puts("  rules: #{length(prog.rules)}   tools: #{length(prog.decl_tools)}   init_state: #{prog.init_state}\n")

    Enum.each(findings, fn {sev, title, lines} ->
      IO.puts("  #{icon(sev)} #{title}")
      Enum.each(lines, &IO.puts("       #{&1}"))
      IO.puts("")
    end)

    counts = Enum.frequencies_by(findings, fn {s, _, _} -> s end)
    IO.puts("  ── summary: #{Map.get(counts, :error, 0)} error · #{Map.get(counts, :warn, 0)} warn · #{Map.get(counts, :smell, 0)} smell ──\n")
  end

  defp icon(:error), do: "🔴"
  defp icon(:warn), do: "🟡"
  defp icon(:smell), do: "🟠"
  defp icon(:info), do: "🔎"
  defp icon(:ok), do: "✅"
end

path = System.argv() |> List.first() || "docs/pivot/PROMPT_BASIC_EXAMPLE1.md"
prog = PromptBasic.Parser.parse_file(path)
findings = PromptBasic.Analyzer.run(prog)
PromptBasic.Report.print(prog, findings)
