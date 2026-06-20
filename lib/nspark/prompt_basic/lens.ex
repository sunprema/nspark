defmodule Nspark.PromptBasic.Lens do
  @moduledoc """
  Runs the PromptBasic static lens over a *graph* and emits diagnostics tagged with the
  graph node ids they affect — so the Studio can render per-node badges and panel entries
  through the existing `Nspark.Diagnostics` pipeline (same `%{level, code, message, node_ids}`
  shape).

  `Nspark.PromptBasic.Analyzer` is the canonical lens over the IR (text-oriented findings).
  This module re-derives the **node-mappable** subset from the same IR and resolves each
  finding to the rule/state/memory/tool node that produced it:

    * `:pb_dead_state` (error) — a state is entered but no rule matches `when state = X`
    * `:pb_dead_memory` / `:pb_write_only_memory` (warning) — declared-but-unused / written-never-read
    * `:pb_unresolved_ref` (error) — `{{tool:x}}` with no producing tool in the rule
    * `:pb_unreachable` (error) — a lower-priority rule fully shadowed by a higher one
    * `:pb_undeclared_tool` (error) / `:pb_unused_tool` (warning)
    * `:pb_tie` (warning) — same-priority rules that are not provably mutually exclusive
    * `:pb_preemption` (warning, advisory heuristic) — adjacent multi-condition rules that collide

  The shared soundness predicates are mirrored from the Analyzer; the two must stay in sync
  (see docs/pivot/DESIGN_MEMO_two_layer_lens.md §5).
  """

  alias Nspark.PromptBasic.Compiler

  @doc "Lens diagnostics for a graph's nodes. Empty when there is no control layer."
  @spec diagnostics([map()]) :: [Nspark.Diagnostics.t()]
  def diagnostics(nodes) do
    if Enum.any?(nodes, &(node_type(&1) in [:rule, :state])) do
      run(Compiler.from_graph(nodes), nodes)
    else
      []
    end
  end

  defp run(ir, nodes) do
    rules = Enum.reject(ir.rules, &(&1.priority == :otherwise))
    id_to_node = Compiler.rule_id_to_node_id(nodes)
    states = label_index(nodes, :state)
    mems = label_index(nodes, :memory)
    tools = label_index(nodes, :tool)

    List.flatten([
      dead_states(ir, rules, states),
      dead_memory(ir, rules, mems),
      unresolved_refs(rules, id_to_node),
      unreachable(rules, id_to_node),
      tool_checks(ir, rules, id_to_node, tools),
      ties(rules, id_to_node),
      preemption(rules, id_to_node)
    ])
  end

  # ── checks ────────────────────────────────────────────────────────────────────

  defp dead_states(ir, rules, states) do
    written = rules |> Enum.flat_map(& &1.state_writes) |> MapSet.new()
    read = rules |> Enum.flat_map(& &1.atoms) |> Enum.filter(&(&1.key == "state")) |> Enum.map(& &1.value) |> MapSet.new()
    dead = written |> MapSet.difference(read) |> MapSet.delete(ir.init_state)

    for s <- MapSet.to_list(dead) do
      diag(:error, :pb_dead_state, "State “#{s}” is entered via [STATE] but no rule matches `when state = #{s}` — the user's next message dead-ends to the fallback.", [states[s]])
    end
  end

  defp dead_memory(ir, rules, mems) do
    declared = ir.decl_mem |> Map.keys() |> MapSet.new()
    read = rules |> Enum.flat_map(& &1.atoms) |> Enum.filter(&(&1.kind == :memory and &1.key != "state")) |> Enum.map(& &1.key) |> MapSet.new()
    written = rules |> Enum.flat_map(& &1.mem_writes) |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    dead = MapSet.difference(declared, MapSet.union(read, written))
    write_only = MapSet.difference(written, read)

    for(k <- MapSet.to_list(dead),
        do: diag(:warning, :pb_dead_memory, "Memory “#{k}” is declared but never read or written — dead memory.", [mems[k]])) ++
      for(k <- MapSet.to_list(write_only),
          do: diag(:warning, :pb_write_only_memory, "Memory “#{k}” is written but no [WHEN] ever reads it.", [mems[k]]))
  end

  defp unresolved_refs(rules, id_to_node) do
    Enum.flat_map(rules, fn r ->
      produced = r.tools |> Enum.map(& &1.out) |> MapSet.new()
      bad = r.refs |> Enum.filter(&(&1.kind == :tool)) |> Enum.reject(&MapSet.member?(produced, &1.var)) |> Enum.map(& &1.var)

      case bad do
        [] -> []
        vars -> [diag(:error, :pb_unresolved_ref, "#{r.id}: references #{Enum.map_join(vars, ", ", &"{{tool:#{&1}}}")} but no tool in this rule outputs it.", [id_to_node[r.id]])]
      end
    end)
  end

  defp unreachable(rules, id_to_node) do
    for low <- rules, high <- rules, low.id != high.id, num(low.priority) < num(high.priority),
        keyset(high) != MapSet.new(), subset?(keyset(high), keyset(low)), uniq: true do
      diag(:error, :pb_unreachable, "#{low.id} (P#{low.priority}) is unreachable — every input matching it also matches higher-priority #{high.id} (P#{high.priority}), which wins.", [id_to_node[low.id]])
    end
  end

  defp tool_checks(ir, rules, id_to_node, tools) do
    declared = ir.decl_tools |> Enum.map(& &1.name) |> MapSet.new()
    invoked = rules |> Enum.flat_map(& &1.tools) |> Enum.map(& &1.name) |> MapSet.new()
    unused = MapSet.difference(declared, invoked)
    undeclared = MapSet.difference(invoked, declared)

    for(name <- MapSet.to_list(unused),
        do: diag(:warning, :pb_unused_tool, "Tool “#{name}” is declared but never invoked.", [tools[name]])) ++
      for name <- MapSet.to_list(undeclared) do
        node_ids = rules |> Enum.filter(fn r -> name in Enum.map(r.tools, & &1.name) end) |> Enum.map(&id_to_node[&1.id])
        diag(:error, :pb_undeclared_tool, "Tool “#{name}” is invoked but never declared.", node_ids)
      end
  end

  defp ties(rules, id_to_node) do
    rules
    |> Enum.group_by(& &1.priority)
    |> Enum.filter(fn {_p, rs} -> length(rs) > 1 and not mutually_exclusive_group?(rs) end)
    |> Enum.map(fn {p, rs} ->
      ids = Enum.map_join(rs, ", ", & &1.id)
      diag(:warning, :pb_tie, "Rules at priority #{p} (#{ids}) can match the same input — resolution order is ambiguous.", Enum.map(rs, &id_to_node[&1.id]))
    end)
  end

  defp preemption(rules, id_to_node) do
    for a <- rules, b <- rules, a.id < b.id, a.section != b.section,
        abs(num(a.priority) - num(b.priority)) == 1,
        a.when_op == :and, b.when_op == :and,
        length(a.atoms) >= 2, length(b.atoms) >= 2,
        co_satisfiable?(a, b), uniq: true do
      {hi, lo} = if num(a.priority) > num(b.priority), do: {a, b}, else: {b, a}
      diag(:warning, :pb_preemption, "#{hi.id} (P#{hi.priority}) preempts #{lo.id} (P#{lo.priority}) when both match — #{lo.section} is silently ignored. Confirm the priority order is intended.", [id_to_node[hi.id], id_to_node[lo.id]])
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp diag(level, code, message, node_ids) do
    %{level: level, code: code, message: message, node_ids: node_ids |> Enum.reject(&is_nil/1) |> Enum.uniq()}
  end

  defp label_index(nodes, type) do
    nodes
    |> Enum.reject(&muted?/1)
    |> Enum.filter(&(node_type(&1) == type))
    |> Map.new(&{node_label(&1), node_id(&1)})
  end

  # ── soundness predicates (mirrored from Analyzer — keep in sync) ──────────────

  defp num(:otherwise), do: -1
  defp num(n), do: n
  defp keyset(rule), do: rule.atoms |> Enum.map(& &1.key) |> MapSet.new()
  defp subset?(a, b), do: MapSet.subset?(a, b)

  defp complementary_names?(a, b),
    do: String.replace(a, "not_", "") == b or String.replace(b, "not_", "") == a

  defp complementary_atoms?(x, y) do
    if x.kind == :memory and y.kind == :memory and x.key == y.key do
      (x.op == "=" and y.op == "!=" and x.value == y.value) or
        (x.op == "!=" and y.op == "=" and x.value == y.value) or
        (x.op == "=" and y.op == "=" and x.value != y.value)
    else
      complementary_names?(x.key, y.key)
    end
  end

  defp co_satisfiable?(a, b),
    do: not Enum.any?(a.atoms, fn x -> Enum.any?(b.atoms, fn y -> complementary_atoms?(x, y) end) end)

  defp mutually_exclusive_group?(rules) do
    pairs = for a <- rules, b <- rules, a.id < b.id, do: {a, b}
    Enum.all?(pairs, fn {a, b} -> not co_satisfiable?(a, b) end)
  end

  # ── node field accessors (Ash structs and string-keyed snapshot maps) ─────────

  defp node_type(%{type: t}), do: norm(t)
  defp node_type(%{"type" => t}), do: norm(t)
  defp node_type(_), do: nil
  defp norm(t) when is_atom(t), do: t
  defp norm(t) when is_binary(t), do: String.to_existing_atom(t)

  defp node_id(%{id: id}), do: id
  defp node_id(%{"id" => id}), do: id

  defp node_label(%{label: l}), do: l
  defp node_label(%{"label" => l}), do: l

  defp muted?(%{is_muted: m}), do: m == true
  defp muted?(%{"is_muted" => m}), do: m == true
  defp muted?(_), do: false
end
