defmodule Nspark.PromptBasic.Selector do
  @moduledoc """
  Deterministic rule selection — the executable half of the IR execution model.

  A `world` declares the facts of a scenario:

      %{state: "intake", memory: %{"item_received" => "true"}, conds: ["user_wants_return"]}

  `conds` are the semantic atoms a test author asserts are TRUE for this turn (the part an LLM
  would judge at runtime). state/memory atoms are evaluated deterministically against the world.

  Returns which rule fires, the tie set, and the resulting transition/actions — no LLM involved,
  so it tests the *logic structure* of the agent, including coverage gaps that drain to OTHERWISE.

  Promoted from `docs/pivot/promptbasic_engine.exs`; behavior matches the prototype that the
  Test layer and LLM-compliance harness validated (10 pass / 3 gaps / 0 regressions on RMA).
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

        %{
          rule: winner,
          matched: Enum.map(matching, fn {r, _} -> r.id end),
          tie: tie,
          result: result_of(winner)
        }
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

  defp drained,
    do: %{tools: [], state_to: nil, mem_writes: [], terminal: :ask, stop: true, drained: true}
end
