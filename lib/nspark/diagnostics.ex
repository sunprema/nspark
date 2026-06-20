defmodule Nspark.Diagnostics do
  @moduledoc """
  Graph validation checks. Operates on Ash resource structs (live editing)
  or string-keyed maps (snapshot replay). Returns a list of diagnostic maps
  with :level, :code, :message, and :node_ids.

  See docs/PRD.md "Compiler Diagnostics" and UX §9.
  """

  @type level :: :error | :warning | :info
  @type t :: %{
          level: level(),
          code: atom(),
          message: String.t(),
          node_ids: [String.t()]
        }

  @doc """
  Run all checks against the current graph. Only active (non-muted) nodes
  are checked; edges reference the full set.

  Returns a list of `t()` maps: errors and warnings (structural problems)
  first, then a closing informational summary of the input contract.
  """
  @spec run([map()], [map()]) :: [t()]
  def run(nodes, edges) do
    active = Enum.reject(nodes, &muted?/1)

    # A control-layer (PromptBasic) graph is a different artifact than a context-layer
    # prompt graph: its memory/tool nodes are referenced by token (not edges) and a
    # persona/output schema isn't required — the PromptBasic lens governs it instead.
    # So the context-layer-only checks (floating declarations, persona, output) are
    # suppressed when a control layer is present, to avoid false-positive noise.
    control_layer? = Enum.any?(active, &(node_type(&1) in [:rule, :state]))

    []
    |> check_cycle(active, edges)
    |> check_floating(active, edges, control_layer?)
    |> check_no_persona(active, control_layer?)
    |> check_multiple_personas(active)
    |> check_no_output(active, control_layer?)
    |> check_empty_output(active)
    |> check_multiple_outputs(active)
    |> check_agent_nodes(active)
    |> check_input_contract(active, edges)
    |> Enum.reverse()
  end

  # ── checks ────────────────────────────────────────────────────────────────────

  defp check_cycle(diags, nodes, _edges) when length(nodes) < 2, do: diags

  defp check_cycle(diags, nodes, edges) do
    case cycle_node_ids(nodes, edges) do
      [] ->
        diags

      ids ->
        [
          %{
            level: :error,
            code: :cycle,
            message: "Circular dependency detected — these nodes form a cycle.",
            node_ids: ids
          }
          | diags
        ]
    end
  end

  defp check_floating(diags, nodes, _edges, _control?) when length(nodes) < 2, do: diags

  defp check_floating(diags, nodes, edges, control_layer?) do
    connected = edge_node_id_set(edges)

    # Node types that are legitimately edge-less and must never count as "floating":
    # rule/state carry their transitions in the rule body, and in a control-layer
    # graph memory/tool are referenced by token ({{tool:_}}, state =), not by edges.
    exempt = if control_layer?, do: [:rule, :state, :memory, :tool], else: [:rule, :state]

    floating =
      nodes
      |> Enum.reject(&(node_type(&1) in exempt))
      |> Enum.filter(fn n -> not MapSet.member?(connected, node_id(n)) end)

    case floating do
      [] ->
        diags

      ns ->
        count = length(ns)

        [
          %{
            level: :warning,
            code: :floating_node,
            message:
              "#{count} node#{if count > 1, do: "s have", else: " has"} no connections and #{if count > 1, do: "are", else: "is"} excluded from compile order.",
            node_ids: Enum.map(ns, &node_id/1)
          }
          | diags
        ]
    end
  end

  # A control-layer (PromptBasic) agent defines its behavior via rules, not a
  # persona block, so this context-layer check is suppressed for those graphs.
  defp check_no_persona(diags, _nodes, true), do: diags
  defp check_no_persona(diags, [], _control?), do: diags

  defp check_no_persona(diags, nodes, _control?) do
    if Enum.any?(nodes, &(node_type(&1) == :persona)),
      do: diags,
      else: [
        %{
          level: :warning,
          code: :no_persona,
          message: "No Persona node — agent has no defined identity or role.",
          node_ids: []
        }
        | diags
      ]
  end

  defp check_multiple_personas(diags, nodes) do
    case Enum.filter(nodes, &(node_type(&1) == :persona)) do
      [_] -> diags
      [] -> diags
      ns ->
        [
          %{
            level: :warning,
            code: :multiple_personas,
            message:
              "#{length(ns)} Persona nodes — conflicting identities may produce inconsistent output.",
            node_ids: Enum.map(ns, &node_id/1)
          }
          | diags
        ]
    end
  end

  # Likewise: a control-layer agent's output is the matched rule's [RESPOND]/[ASK],
  # so an Output-schema node isn't required for those graphs.
  defp check_no_output(diags, _nodes, true), do: diags
  defp check_no_output(diags, [], _control?), do: diags

  defp check_no_output(diags, nodes, _control?) do
    if Enum.any?(nodes, &(node_type(&1) == :output)),
      do: diags,
      else: [
        %{
          level: :warning,
          code: :no_output,
          message: "No Output node — response schema is undefined.",
          node_ids: []
        }
        | diags
      ]
  end

  defp check_empty_output(diags, nodes) do
    empty =
      nodes
      |> Enum.filter(&(node_type(&1) == :output))
      |> Enum.filter(fn n ->
        c = node_content(n)
        is_nil(c) or String.trim(c) == ""
      end)

    case empty do
      [] ->
        diags

      ns ->
        [
          %{
            level: :warning,
            code: :empty_output,
            message: "Output node has no schema defined.",
            node_ids: Enum.map(ns, &node_id/1)
          }
          | diags
        ]
    end
  end

  defp check_multiple_outputs(diags, nodes) do
    outputs = Enum.filter(nodes, &(node_type(&1) == :output))

    case outputs do
      [_] ->
        diags

      [] ->
        diags

      ns ->
        [
          %{
            level: :warning,
            code: :multiple_outputs,
            message:
              "#{length(ns)} Output nodes — response format may be ambiguous.",
            node_ids: Enum.map(ns, &node_id/1)
          }
          | diags
        ]
    end
  end

  # Every `{var}` in a prompt graph is a *runtime input* the calling app supplies
  # — a Context/Memory node is a template section that references inputs, not a
  # definition that binds their values. So there is no such thing as an
  # "undefined" or "unused" variable to warn about; that producer/consumer view
  # contradicts the published input contract (a well-formed externalized prompt
  # would otherwise light up with false-positive warnings for its entire API).
  #
  # Instead we surface the contract itself, derived from the SAME source the
  # publish path uses (`Nspark.VersionDiff.contract/1`), so the diagnostics panel
  # and the frozen contract can never disagree about what the graph requires.
  defp check_input_contract(diags, nodes, edges) do
    vars = Nspark.VersionDiff.contract(%{nodes: nodes, edges: edges})["variables"]

    case map_size(vars) do
      0 ->
        diags

      total ->
        optional = Enum.count(vars, fn {_name, spec} -> Map.get(spec, "required") == false end)

        [
          %{
            level: :info,
            code: :input_contract,
            message: input_contract_message(total, total - optional, optional),
            node_ids: []
          }
          | diags
        ]
    end
  end

  defp input_contract_message(total, _required, 0),
    do: "Input contract: #{total} runtime variable#{plural(total)}, all required, supplied by the calling app."

  defp input_contract_message(total, required, optional),
    do:
      "Input contract: #{total} runtime variable#{plural(total)} — #{required} required, " <>
        "#{optional} optional (reached only on conditional branches) — supplied by the calling app."

  defp plural(1), do: ""
  defp plural(_), do: "s"

  defp check_agent_nodes(diags, nodes) do
    agent_nodes = Enum.filter(nodes, &(node_type(&1) == :agent))

    Enum.reduce(agent_nodes, diags, fn n, acc ->
      meta = node_metadata(n) || %{}
      acc
      |> then(fn a ->
        if Map.get(meta, "source_graph_id") in [nil, ""] do
          [%{level: :warning, code: :agent_no_graph, message: "Agent node \"#{node_label(n)}\" has no sub-agent graph selected.", node_ids: [node_id(n)]} | a]
        else
          a
        end
      end)
      |> then(fn a ->
        if Map.get(meta, "output_var") in [nil, ""] do
          [%{level: :warning, code: :agent_no_output_var, message: "Agent node \"#{node_label(n)}\" has no output variable set.", node_ids: [node_id(n)]} | a]
        else
          a
        end
      end)
    end)
  end

  # ── content / metadata / label accessors ──────────────────────────────────────

  defp node_content(%{content: c}), do: c
  defp node_content(%{"content" => c}), do: c
  defp node_content(_), do: nil

  defp node_metadata(%{metadata: m}), do: m
  defp node_metadata(%{"metadata" => m}), do: m
  defp node_metadata(_), do: nil

  defp node_label(%{label: l}), do: l
  defp node_label(%{"label" => l}), do: l
  defp node_label(_), do: "?"

  # ── cycle detection via Kahn's algorithm ─────────────────────────────────────
  # Nodes absent from the topological sort are in cycles.

  defp cycle_node_ids(nodes, edges) do
    ids = Enum.map(nodes, &node_id/1)
    id_set = MapSet.new(ids)

    {in_deg, adj} =
      Enum.reduce(edges, {Map.new(ids, &{&1, 0}), Map.new(ids, &{&1, []})}, fn e, {deg, adj} ->
        s = edge_src(e)
        t = edge_tgt(e)

        if MapSet.member?(id_set, s) and MapSet.member?(id_set, t) do
          {Map.update(deg, t, 1, &(&1 + 1)), Map.update(adj, s, [t], &[t | &1])}
        else
          {deg, adj}
        end
      end)

    queue = for {id, 0} <- in_deg, do: id
    sorted_set = kahn_drain(queue, adj, in_deg, MapSet.new())

    for n <- nodes, not MapSet.member?(sorted_set, node_id(n)), do: node_id(n)
  end

  defp kahn_drain([], _adj, _deg, visited), do: visited

  defp kahn_drain([id | rest], adj, deg, visited) do
    {deg, ready} =
      Enum.reduce(Map.get(adj, id, []), {deg, []}, fn nid, {d, r} ->
        new_d = Map.update!(d, nid, &(&1 - 1))
        {new_d, if(new_d[nid] == 0, do: [nid | r], else: r)}
      end)

    kahn_drain(rest ++ ready, adj, deg, MapSet.put(visited, id))
  end

  # ── field accessors (Ash structs and plain string-keyed maps) ─────────────────

  defp node_id(%{id: id}), do: id
  defp node_id(%{"id" => id}), do: id

  defp node_type(%{type: t}), do: t
  defp node_type(%{"type" => t}) when is_atom(t), do: t
  defp node_type(%{"type" => t}), do: String.to_existing_atom(t)

  defp muted?(%{is_muted: m}), do: m
  defp muted?(%{"is_muted" => m}), do: m
  defp muted?(_), do: false

  defp edge_src(%{source_node_id: id}), do: id
  defp edge_src(%{"source_node_id" => id}), do: id

  defp edge_tgt(%{target_node_id: id}), do: id
  defp edge_tgt(%{"target_node_id" => id}), do: id

  defp edge_node_id_set(edges) do
    Enum.reduce(edges, MapSet.new(), fn e, acc ->
      acc |> MapSet.put(edge_src(e)) |> MapSet.put(edge_tgt(e))
    end)
  end
end
