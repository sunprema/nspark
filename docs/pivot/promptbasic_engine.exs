# PromptBasic shared engine — Parser + Selector.
# Loaded by both lens_analyzer.exs (static analysis) and rma_tests.exs (scenario tests).
# No top-level execution: this file only defines modules.

defmodule PromptBasic.Parser do
  @moduledoc "Line-based parser for the bracket PromptBasic format."

  def parse_file(path), do: path |> File.read!() |> parse()

  def parse(source) do
    lines = String.split(source, "\n")

    init = %{
      mode: :setup,
      section: nil,
      current: nil,
      rules: [],
      decl_mem: %{},
      decl_tools: [],
      init_state: nil,
      counter: 0
    }

    state =
      Enum.reduce(lines, init, fn raw, acc -> handle(String.trim(raw), acc) end)
      |> flush()

    %{
      rules: Enum.reverse(state.rules),
      decl_mem: state.decl_mem,
      decl_tools: Enum.reverse(state.decl_tools),
      init_state: state.init_state
    }
  end

  defp handle("", acc), do: acc
  defp handle("---", acc), do: acc
  defp handle("[PROMPTBASIC" <> _, acc), do: acc
  defp handle("#" <> rest, acc), do: %{acc | section: String.trim(rest)}

  defp handle("[PRIORITY]" <> rest, acc) do
    acc = flush(acc)
    n = rest |> String.trim() |> String.to_integer()
    %{acc | mode: :rule, current: new_rule(acc, n)}
  end

  defp handle("[OTHERWISE]" <> _, acc) do
    acc = flush(acc)
    %{acc | mode: :rule, current: new_rule(acc, :otherwise)}
  end

  defp handle("[STATE]" <> rest, %{mode: :setup} = acc), do: %{acc | init_state: String.trim(rest)}
  defp handle("[STATE]" <> rest, acc), do: put_cur(acc, :state_writes, &[String.trim(rest) | &1])

  defp handle("[MEMORY]" <> rest, %{mode: :setup} = acc) do
    {k, v} = kv(rest)
    %{acc | decl_mem: Map.put(acc.decl_mem, k, v)}
  end

  defp handle("[MEMORY]" <> rest, acc) do
    {k, v} = kv(rest)
    put_cur(acc, :mem_writes, &[{k, v} | &1])
  end

  defp handle("[TOOL]" <> rest, %{mode: :setup} = acc),
    do: %{acc | decl_tools: [parse_tool_decl(rest) | acc.decl_tools]}

  defp handle("[TOOL]" <> rest, acc) do
    acc = put_cur(acc, :tools, &[parse_tool_inv(rest) | &1])
    scan_refs(rest, acc)
  end

  defp handle("[WHEN]" <> rest, acc) do
    {op, atoms} = parse_when(String.trim(rest), acc)
    update_cur(acc, fn r -> %{r | when_op: op, atoms: atoms} end)
  end

  defp handle("[ASK]" <> _, acc), do: set_terminal(acc, :ask)
  defp handle("[RESPOND]" <> _, acc), do: set_terminal(acc, :respond)
  defp handle("[STOP]" <> _, acc), do: update_cur(acc, &Map.put(&1, :has_stop, true))
  defp handle(line, %{mode: :rule} = acc), do: scan_refs(line, acc)
  defp handle(_line, acc), do: acc

  defp new_rule(acc, priority) do
    %{
      id: "R#{acc.counter + 1}",
      section: acc.section,
      priority: priority,
      when_op: :none,
      atoms: [],
      tools: [],
      mem_writes: [],
      state_writes: [],
      refs: [],
      has_stop: false,
      terminal: nil
    }
  end

  defp flush(%{current: nil} = acc), do: acc

  defp flush(%{current: r} = acc) do
    r = %{
      r
      | atoms: Enum.reverse(r.atoms),
        tools: Enum.reverse(r.tools),
        mem_writes: r.mem_writes |> Enum.reverse() |> Enum.uniq(),
        state_writes: r.state_writes |> Enum.reverse() |> Enum.uniq(),
        refs: r.refs |> Enum.reverse() |> Enum.uniq()
    }

    %{acc | rules: [r | acc.rules], current: nil, counter: acc.counter + 1}
  end

  defp put_cur(%{current: nil} = acc, _k, _f), do: acc
  defp put_cur(acc, key, f), do: update_cur(acc, &Map.update!(&1, key, f))
  defp update_cur(%{current: nil} = acc, _f), do: acc
  defp update_cur(acc, f), do: %{acc | current: f.(acc.current)}
  defp set_terminal(acc, t), do: update_cur(acc, &Map.put(&1, :terminal, &1.terminal || t))

  defp kv(rest) do
    [k, v] = String.split(rest, "=", parts: 2)
    {String.trim(k), String.trim(v)}
  end

  defp parse_tool_decl(rest) do
    case Regex.run(~r/(\w+)\s*->\s*(\w+)/, rest) do
      [_, name, out] -> %{name: name, out: out}
      _ -> %{name: String.trim(rest), out: nil}
    end
  end

  defp parse_tool_inv(rest) do
    case Regex.run(~r/(\w+)\s*(?:\(([^)]*)\))?\s*->\s*(\w+)/, rest) do
      [_, name, args, out] -> %{name: name, args: String.trim(args), out: out}
      [_, name, out] -> %{name: name, args: "", out: out}
      _ -> %{name: String.trim(rest), args: "", out: nil}
    end
  end

  defp scan_refs(line, acc) do
    refs =
      Regex.scan(~r/\{\{(tool|memory):(\w+)\}\}/, line)
      |> Enum.map(fn [_, kind, var] -> %{kind: String.to_atom(kind), var: var} end)

    case refs do
      [] -> acc
      _ -> update_cur(acc, fn r -> %{r | refs: Enum.reverse(refs) ++ r.refs} end)
    end
  end

  defp parse_when(text, acc) do
    cond do
      String.contains?(text, " OR ") -> {:or, text |> String.split(" OR ") |> atoms(acc)}
      String.contains?(text, " AND ") -> {:and, text |> String.split(" AND ") |> atoms(acc)}
      true -> {:single, atoms([text], acc)}
    end
  end

  defp atoms(parts, acc), do: Enum.map(parts, &parse_atom(String.trim(&1), acc))

  defp parse_atom(part, acc) do
    mem_keys = Map.keys(acc.decl_mem)

    atom =
      cond do
        String.contains?(part, "!=") ->
          [k, v] = String.split(part, "!=", parts: 2)
          %{raw: part, key: String.trim(k), op: "!=", value: String.trim(v)}

        String.contains?(part, "=") ->
          [k, v] = String.split(part, "=", parts: 2)
          %{raw: part, key: String.trim(k), op: "=", value: String.trim(v)}

        Regex.match?(~r/"/, part) ->
          [_, key] = Regex.run(~r/^(\w+)/, part)
          %{raw: part, key: key, op: nil, value: nil, literal: true}

        true ->
          %{raw: part, key: part, op: nil, value: nil}
      end

    kind = if atom.key in mem_keys or atom.key == "state", do: :memory, else: :semantic
    Map.put(atom, :kind, kind) |> Map.put_new(:literal, false)
  end
end

defmodule PromptBasic.Selector do
  @moduledoc """
  Deterministic rule selection — the executable half of the IR execution model.

  A `world` declares the facts of a scenario:
      %{state: "intake", memory: %{"item_received" => "true"}, conds: ["user_wants_return", ...]}

  `conds` are the semantic atoms a test author asserts are TRUE for this turn (the part an LLM
  would judge at runtime). state/memory atoms are evaluated deterministically against the world.

  Returns which rule fires, the tie set, and the resulting transition/actions — no LLM involved,
  so it tests the *logic structure* of the agent, including coverage gaps that drain to OTHERWISE.
  """

  def fire(prog, world) do
    world = normalize(prog, world)
    rules = Enum.reject(prog.rules, &(&1.priority == :otherwise))

    matching =
      rules
      |> Enum.with_index()
      |> Enum.filter(fn {r, _i} -> eval_when(r, world, prog) end)

    case matching do
      [] ->
        %{rule: :otherwise, matched: [], tie: [], result: drained()}

      _ ->
        # highest priority wins; document order breaks ties (stable via index)
        {winner, _} =
          Enum.min_by(matching, fn {r, i} -> {-r.priority, i} end)

        tie =
          matching
          |> Enum.filter(fn {r, _} -> r.priority == winner.priority end)
          |> Enum.map(fn {r, _} -> r.id end)

        %{rule: winner, matched: Enum.map(matching, fn {r, _} -> r.id end), tie: tie, result: result_of(winner)}
    end
  end

  defp normalize(prog, world) do
    %{
      state: Map.get(world, :state, prog.init_state),
      memory: Map.merge(prog.decl_mem, Map.get(world, :memory, %{})),
      conds: MapSet.new(Map.get(world, :conds, []))
    }
  end

  defp eval_when(%{when_op: :none}, _w, _p), do: false

  defp eval_when(rule, world, prog) do
    truths = Enum.map(rule.atoms, &eval_atom(&1, world, prog))

    case rule.when_op do
      :and -> Enum.all?(truths)
      :or -> Enum.any?(truths)
      :single -> hd(truths)
    end
  end

  defp eval_atom(%{key: "state", op: op, value: v}, world, _prog) do
    case op do
      "=" -> world.state == v
      "!=" -> world.state != v
      _ -> false
    end
  end

  defp eval_atom(%{kind: :memory, key: k, op: op, value: v}, world, _prog) do
    cur = world.memory |> Map.get(k) |> to_string()

    case op do
      "=" -> cur == v
      "!=" -> cur != v
      _ -> false
    end
  end

  defp eval_atom(%{key: k}, world, _prog), do: MapSet.member?(world.conds, k)

  defp result_of(rule) do
    %{
      tools: Enum.map(rule.tools, & &1.name),
      state_to: List.last(rule.state_writes),
      mem_writes: rule.mem_writes,
      terminal: rule.terminal,
      stop: rule.has_stop
    }
  end

  defp drained, do: %{tools: [], state_to: nil, mem_writes: [], terminal: :ask, stop: true, drained: true}
end
