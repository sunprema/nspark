defmodule Nspark.Compiler do
  @moduledoc """
  Assembles a graph's nodes into a model-ready prompt (Markdown), in compile
  order. The graph is the source of truth; the compiled prompt is a generated
  artifact (see docs/HLD.md §5).

  Implemented pipeline phases:
  - Phase 4: Topological ordering within sections via Kahn's algorithm on edges
  - Phase 5: Assembly in canonical section order
  - Phase 6: Provider-specific transforms (Anthropic / OpenAI / Gemini)
  """

  @order [
    {:agent, "ORCHESTRATION"},
    {:persona, "MISSION"},
    {:constraint, "OPERATIONAL RULES"},
    {:context, "CONTEXT"},
    {:skill, "SKILLS"},
    {:tool, "TOOLS"},
    {:memory, "MEMORY"},
    {:conditional, "CONDITIONAL LOGIC"},
    {:evaluation, "EVALUATION"},
    {:output, "OUTPUT FORMAT"}
  ]

  @providers %{
    anthropic: %{name: "Claude 3.5 Sonnet", chars_per_token: 3.5, input_usd_per_1m: 3.0},
    openai: %{name: "GPT-4o", chars_per_token: 3.8, input_usd_per_1m: 5.0},
    gemini: %{name: "Gemini 1.5 Pro", chars_per_token: 4.0, input_usd_per_1m: 1.25}
  }

  @type provider :: :anthropic | :openai | :gemini
  @type result :: %{
          markdown: String.t(),
          token_estimate: non_neg_integer(),
          cost_estimate: float(),
          provider: provider(),
          included: non_neg_integer(),
          excluded: non_neg_integer(),
          resolved_assets: [map()]
        }

  @doc """
  Compile nodes into the assembled prompt plus stats.

  Options:
  - `:provider` — `:anthropic` (default), `:openai`, or `:gemini`
  - `:resolved_assets` — manifest of Registry assets already resolved into the
    nodes (see `Nspark.Registry.resolve_skills/2`); echoed into the result so
    the compiler output reports which asset versions it assembled.

  Edges (optional) are used to topologically order nodes within each section.
  Both Ash resource structs and plain string-keyed maps (from snapshots) are
  accepted for nodes and edges.
  """
  @spec compile([map()], [map()], keyword()) :: result()
  def compile(nodes, edges \\ [], opts \\ []) do
    provider = Keyword.get(opts, :provider, :anthropic)
    resolved_assets = Keyword.get(opts, :resolved_assets, [])
    active = Enum.reject(nodes, &node_muted?/1)
    cond_contexts = build_conditional_contexts(active, edges)

    raw =
      for {type, heading} <- @order,
          group = Enum.filter(active, &(node_type(&1) == type)),
          group != [] do
        sorted = topo_sort_group(group, edges)
        body = sorted |> Enum.map_join("\n\n", fn n ->
          when_expr = if node_type(n) == :agent, do: Map.get(cond_contexts, node_id(n)), else: nil
          node_body(n, when_expr)
        end)
        "# #{heading}\n\n#{body}"
      end
      |> Enum.join("\n\n")
      |> String.trim()

    markdown = apply_provider_transform(raw, provider)

    cfg = Map.get(@providers, provider, @providers.anthropic)
    token_estimate = round(String.length(markdown) / cfg.chars_per_token)
    cost_estimate = token_estimate / 1_000_000 * cfg.input_usd_per_1m

    %{
      markdown: markdown,
      token_estimate: token_estimate,
      cost_estimate: Float.round(cost_estimate, 6),
      provider: provider,
      included: length(active),
      excluded: length(nodes) - length(active),
      resolved_assets: resolved_assets
    }
  end

  @doc "Returns `[{atom, display_name}]` for all supported providers."
  def providers, do: Enum.map(@providers, fn {k, v} -> {k, v.name} end)

  @doc "Returns `%{node_id => compile_position}` (1-based) for active (non-muted) nodes."
  @spec node_order([map()], [map()]) :: %{String.t() => pos_integer()}
  def node_order(nodes, edges \\ []) do
    active = Enum.reject(nodes, &node_muted?/1)

    @order
    |> Enum.flat_map(fn {type, _heading} ->
      group = Enum.filter(active, &(node_type(&1) == type))
      if group == [], do: [], else: topo_sort_group(group, edges)
    end)
    |> Enum.with_index(1)
    |> Map.new(fn {n, i} -> {node_id(n), i} end)
  end

  # ── topological sort within a node-type section ────────────────────────────

  # Fast path: no edges means nothing to sort.
  defp topo_sort_group(nodes, []), do: nodes
  defp topo_sort_group([_] = nodes, _edges), do: nodes

  defp topo_sort_group(nodes, edges) do
    node_ids = MapSet.new(nodes, &node_id/1)

    intra =
      Enum.filter(edges, fn e ->
        MapSet.member?(node_ids, edge_src(e)) and MapSet.member?(node_ids, edge_tgt(e))
      end)

    if intra == [], do: nodes, else: kahn_sort(nodes, intra)
  end

  defp kahn_sort(nodes, edges) do
    node_map = Map.new(nodes, &{node_id(&1), &1})
    ids = Map.keys(node_map)

    {in_deg, adj} =
      Enum.reduce(edges, {Map.new(ids, &{&1, 0}), Map.new(ids, &{&1, []})}, fn e, {deg, adj} ->
        s = edge_src(e)
        t = edge_tgt(e)
        {Map.update(deg, t, 1, &(&1 + 1)), Map.update(adj, s, [t], &[t | &1])}
      end)

    queue =
      in_deg
      |> Enum.filter(fn {_, d} -> d == 0 end)
      |> Enum.map(fn {id, _} -> id end)
      |> Enum.sort_by(&stable_idx(node_map[&1], nodes))

    result = kahn_walk(queue, adj, in_deg, node_map, nodes)

    if length(result) == length(nodes), do: result, else: nodes
  end

  defp kahn_walk([], _adj, _deg, _nm, _orig), do: []

  defp kahn_walk([id | rest], adj, deg, nm, orig) do
    {deg, ready} =
      Enum.reduce(Map.get(adj, id, []), {deg, []}, fn nid, {d, r} ->
        new_d = Map.update!(d, nid, &(&1 - 1))
        {new_d, if(new_d[nid] == 0, do: [nid | r], else: r)}
      end)

    ready = Enum.sort_by(ready, &stable_idx(nm[&1], orig))
    [nm[id] | kahn_walk(rest ++ ready, adj, deg, nm, orig)]
  end

  # Stable tiebreaker: position of the node in the original list.
  defp stable_idx(node, orig),
    do: Enum.find_index(orig, &(node_id(&1) == node_id(node))) || 0

  # ── provider transforms ────────────────────────────────────────────────────

  defp apply_provider_transform("", _provider), do: ""

  defp apply_provider_transform(markdown, :anthropic) do
    "<prompt>\n#{markdown}\n</prompt>"
  end

  defp apply_provider_transform(markdown, _provider), do: markdown

  # ── field accessors (Ash structs and plain string-keyed maps) ─────────────

  defp node_id(%{id: id}), do: id
  defp node_id(%{"id" => id}), do: id
  defp node_id(n), do: inspect(n)

  # Muted flag, tolerant of both atom-keyed live nodes and string-keyed snapshot
  # nodes (`serialize_snapshot/2`). Missing/`nil` means not muted.
  defp node_muted?(%{is_muted: m}), do: m == true
  defp node_muted?(%{"is_muted" => m}), do: m == true
  defp node_muted?(_), do: false

  defp node_type(%{type: t}), do: t
  defp node_type(%{"type" => t}) when is_atom(t), do: t
  defp node_type(%{"type" => t}), do: String.to_existing_atom(t)

  defp edge_src(%{source_node_id: id}), do: id
  defp edge_src(%{"source_node_id" => id}), do: id

  defp edge_tgt(%{target_node_id: id}), do: id
  defp edge_tgt(%{"target_node_id" => id}), do: id

  # ── node_body/2 (context-aware: threads when_expr for agent nodes) ────────────

  defp node_body(%{type: :agent, metadata: meta, label: label}, when_expr) when is_map(meta) do
    agent_directive(label, meta, when_expr)
  end

  defp node_body(%{"type" => type, "metadata" => meta, "label" => label}, when_expr)
       when (type == "agent" or type == :agent) and is_map(meta) do
    agent_directive(label, meta, when_expr)
  end

  defp node_body(n, _when_expr), do: node_body(n)

  # ── node_body/1 (fallback: no conditional context) ────────────────────────────

  defp node_body(%{type: :agent, metadata: meta, label: label}) when is_map(meta) do
    agent_directive(label, meta, nil)
  end

  defp node_body(%{"type" => type, "metadata" => meta, "label" => label})
       when (type == "agent" or type == :agent) and is_map(meta) do
    agent_directive(label, meta, nil)
  end

  defp node_body(%{content: c, label: l}) when is_binary(c) do
    case String.trim(c) do
      "" -> "_#{l}_"
      t -> t
    end
  end

  defp node_body(%{label: l}), do: "_#{l}_"

  defp node_body(%{"content" => c, "label" => l}) when is_binary(c) do
    case String.trim(c) do
      "" -> "_#{l}_"
      t -> t
    end
  end

  defp node_body(%{"label" => l}), do: "_#{l}_"

  defp node_body(_), do: "_?_"

  # ── agent directive assembly ──────────────────────────────────────────────────

  defp agent_directive(label, meta, when_expr) do
    output_var = Map.get(meta, "output_var") || "result"
    deployment_id = Map.get(meta, "source_deployment_id") || "latest"
    on_error = Map.get(meta, "on_error", "fail")
    timeout_ms = Map.get(meta, "timeout_ms") || 10_000
    input_mapping = Map.get(meta, "input_mapping") || %{}

    inputs_text =
      if map_size(input_mapping) > 0 do
        Enum.map_join(input_mapping, "\n", fn {param, var} -> "  #{param}: {#{var}}" end)
      else
        "  (none)"
      end

    when_line = if when_expr, do: "\nwhen: #{when_expr}", else: ""

    "[AGENT: #{output_var}]\ncall: #{label} (deployment: #{deployment_id})\ninputs:\n#{inputs_text}\noutput: {#{output_var}}\non_error: #{on_error}\ntimeout: #{timeout_ms}#{when_line}\n[/AGENT]"
  end

  # ── conditional context: map agent node IDs to their when-expression ──────────

  defp build_conditional_contexts(nodes, edges) do
    node_map = Map.new(nodes, &{node_id(&1), &1})

    edges
    |> Enum.flat_map(fn e ->
      src_id = edge_src(e)
      tgt_id = edge_tgt(e)
      branch = edge_branch(e)

      with %{} = src <- Map.get(node_map, src_id),
           :conditional <- node_type(src),
           %{} = tgt <- Map.get(node_map, tgt_id),
           :agent <- node_type(tgt),
           expr when is_binary(expr) and expr != "" <- node_content_field(src),
           b when b in ["yes", "no"] <- branch do
        [{tgt_id, build_when_expr(expr, b)}]
      else
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp build_when_expr(expr, "yes"), do: expr
  defp build_when_expr(expr, "no") do
    cond do
      String.contains?(expr, " == ") -> String.replace(expr, " == ", " != ", global: false)
      String.contains?(expr, " != ") -> String.replace(expr, " != ", " == ", global: false)
      true -> "!#{expr}"
    end
  end

  defp edge_branch(%{metadata: %{"branch" => b}}), do: b
  defp edge_branch(%{"metadata" => %{"branch" => b}}), do: b
  defp edge_branch(_), do: nil

  defp node_content_field(%{content: c}), do: c
  defp node_content_field(%{"content" => c}), do: c
  defp node_content_field(_), do: nil
end
