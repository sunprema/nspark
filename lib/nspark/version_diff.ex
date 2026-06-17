defmodule Nspark.VersionDiff do
  @moduledoc """
  Pure functions over graph snapshots that derive a version's **input contract**
  (the variables a calling app must supply and the outputs it produces) and,
  later, the classified diff between two versions.

  Like `Nspark.Compiler` and `Nspark.Diagnostics`, this module is pure — no Ash,
  no IO — so it is unit-testable in isolation and reusable on both the publish
  path and the on-demand "compare A↔B" read path.

  See `plans/semantic-graph-diff.md`. Phase 1 (this file) covers contract
  extraction; Phase 2 adds `diff/2`.

  Accepts the canonical string-keyed snapshot shape produced by
  `Nspark.Architecture.serialize_snapshot/2`. Field accessors also tolerate
  atom-keyed Ash structs so the same helpers work on live nodes.
  """

  # Canonical prompt-variable syntax: a single-brace `{name}` reference. This is
  # the ONE definition of "what is a variable"; `Nspark.Diagnostics` derives its
  # input-contract summary from `contract/1` here so the diagnostics panel and the
  # published contract can never disagree on what the graph requires of callers.
  @var_regex ~r/\{([a-zA-Z_]\w*)\}/

  @type contract :: %{
          required(String.t()) => %{required(String.t()) => term()}
        }

  @doc """
  Extract prompt-variable names from a content string.

  Returns variable names in order of appearance (with duplicates); callers that
  want a set should `Enum.uniq/1`. Non-binary input yields `[]`.
  """
  @spec variables_in(term()) :: [String.t()]
  def variables_in(content) when is_binary(content),
    do: @var_regex |> Regex.scan(content) |> Enum.map(fn [_, name] -> name end)

  def variables_in(_), do: []

  @doc """
  Derive the input/output contract of a snapshot.

  Returns:

      %{
        "variables" => %{"customer_name" => %{"required" => true, "refs" => [node_id, ...]}, ...},
        "outputs"   => ["result", "risk_score", ...],
        "provider"  => "anthropic" | nil
      }

  Each `{var}` is treated as a required string input **unless** it is referenced
  only by nodes that sit on a conditional branch — those are needed only when the
  branch fires, so they are marked `"required" => false`. A variable referenced by
  any unconditional node is required (conservative: if in doubt, required, so the
  SDK never lets a genuinely-needed variable go unsupplied). No typed schema yet.
  A variable produced by an agent node's `output_var` is bound internally by that
  sub-agent, so it is excluded from `variables` (it appears under `outputs`) even
  when a downstream node references it. `outputs` are the `output_var`s declared
  on agent nodes. `provider` is echoed
  only if the snapshot pins one; provider-agnostic versions get `nil` rather than
  a guess.

  Accepts either the full snapshot map (`%{"nodes" => [...], "edges" => [...]}`)
  or a bare list of nodes (no edges ⇒ every variable is required).
  """
  @spec contract(map() | [map()]) :: %{String.t() => term()}
  def contract(snapshot) do
    nodes = snapshot_nodes(snapshot)
    edges = snapshot_edges(snapshot)

    %{
      "variables" => variables_contract(nodes, edges),
      "outputs" => outputs(nodes),
      "provider" => provider(snapshot)
    }
  end

  # ── contract pieces ─────────────────────────────────────────────────────────

  defp variables_contract(nodes, edges) do
    optional_node_ids = conditional_branch_target_ids(nodes, edges)

    # A variable produced by an agent node's `output_var` is bound internally at
    # runtime by that sub-agent — it is NOT something the calling app supplies, so
    # it never belongs in the input contract even when a downstream node references
    # `{it}`. It surfaces under `outputs` instead. (Producing wins over consuming:
    # if a name is both produced and referenced, it is an output, not an input.)
    produced = MapSet.new(outputs(nodes))

    nodes
    |> Enum.flat_map(fn n ->
      id = node_id(n)
      n |> node_content() |> variables_in() |> Enum.map(&{&1, id})
    end)
    |> Enum.group_by(fn {name, _id} -> name end, fn {_name, id} -> id end)
    |> Enum.reject(fn {name, _ids} -> MapSet.member?(produced, name) end)
    |> Map.new(fn {name, ids} ->
      ids = Enum.uniq(ids)
      required = not Enum.all?(ids, &MapSet.member?(optional_node_ids, &1))
      {name, %{"required" => required, "refs" => ids}}
    end)
  end

  # Nodes that are the target of a conditional node along a yes/no branch edge.
  # Their content is included only when the branch fires, so any variable used
  # *exclusively* by such nodes is optional. (v1 looks one hop from the
  # conditional; deeper branch-only chains still resolve to required — the safe
  # side.)
  defp conditional_branch_target_ids(nodes, edges) do
    conditional_ids =
      for n <- nodes, node_type(n) == :conditional, into: MapSet.new(), do: node_id(n)

    for e <- edges,
        edge_branch(e) in ["yes", "no"],
        MapSet.member?(conditional_ids, edge_source(e)),
        into: MapSet.new(),
        do: edge_target(e)
  end

  defp outputs(nodes) do
    nodes
    |> Enum.filter(&(node_type(&1) == :agent))
    |> Enum.flat_map(fn n ->
      case node_metadata(n) do
        %{"output_var" => v} when is_binary(v) and v != "" -> [v]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  defp provider(snapshot) when is_map(snapshot) do
    case snapshot do
      %{"provider" => p} when is_binary(p) -> p
      %{provider: p} when is_atom(p) and not is_nil(p) -> to_string(p)
      _ -> nil
    end
  end

  defp provider(_), do: nil

  # ── diff (Phase 2) ───────────────────────────────────────────────────────────

  # Severity ordering for `level`. The overall level is the max across all deltas.
  @severity %{cosmetic: 0, compatible: 1, breaking: 2}

  @doc """
  Classify the change between two snapshots as `:breaking`, `:compatible`, or
  `:cosmetic`, with the supporting deltas.

  Returns:

      %{
        "level"     => :breaking | :compatible | :cosmetic,
        "variables" => %{"added" => [..], "removed" => [..], "renamed" => [%{"from"=>, "to"=>}], "tightened" => [..]},
        "outputs"   => %{"added" => [..], "removed" => [..]},
        "provider"  => %{"from" => .., "to" => ..} | nil,
        "nodes"     => [%{"id"=>, "label"=>, "change"=> :added|:removed|:retyped|:content, ...}],
        "reasons"   => ["requires new variable {foo}", ...]
      }

  Classification (conservative — unknown/ambiguous resolves to the stricter side):
  a new required variable, a renamed variable, or a dropped output is
  **breaking**; a removed variable, a provider change, or a new output is
  **compatible**; content-only or pure structural node changes are **cosmetic**.

  `level` is driven entirely by the contract deltas; per-node changes never
  exceed `:cosmetic` on their own (a node change that alters the contract is
  already reflected in the variable/output deltas).
  """
  @spec diff(map() | [map()], map() | [map()]) :: %{String.t() => term()}
  def diff(old_snapshot, new_snapshot) do
    old_c = contract(old_snapshot)
    new_c = contract(new_snapshot)

    {vars, var_level, var_reasons} = diff_variables(old_c, new_c)
    {outs, out_level, out_reasons} = diff_outputs(old_c, new_c)
    {prov, prov_level, prov_reasons} = diff_provider(old_c, new_c)
    nodes = diff_nodes(old_snapshot, new_snapshot)

    %{
      "level" => max_level([var_level, out_level, prov_level]),
      "variables" => vars,
      "outputs" => outs,
      "provider" => prov,
      "nodes" => nodes,
      "reasons" => var_reasons ++ out_reasons ++ prov_reasons
    }
  end

  defp diff_variables(old_c, new_c) do
    old_vars = old_c["variables"]
    new_vars = new_c["variables"]
    added = Map.keys(new_vars) -- Map.keys(old_vars)
    removed = Map.keys(old_vars) -- Map.keys(new_vars)

    # Rename heuristic: a removed var and an added var that are referenced by the
    # exact same set of (stable) node ids are almost certainly a rename. Both are
    # breaking, so this only sharpens the human-facing reason, not the level.
    {renamed, added, removed} = detect_renames(added, removed, old_vars, new_vars)

    # A newly *required* variable breaks callers; a new *optional* one (used only
    # inside a conditional branch) is additive. Likewise a variable that was
    # optional and is now required has been tightened — that breaks callers who
    # legitimately omitted it.
    {added_required, added_optional} = Enum.split_with(added, &required?(new_vars[&1]))

    tightened =
      for k <- Map.keys(old_vars),
          k in Map.keys(new_vars),
          not required?(old_vars[k]),
          required?(new_vars[k]),
          do: k

    delta = %{
      "added" => Enum.sort(added),
      "removed" => Enum.sort(removed),
      "renamed" => renamed,
      "tightened" => Enum.sort(tightened)
    }

    reasons =
      Enum.map(Enum.sort(added_required), &"requires new variable {#{&1}}") ++
        Enum.map(Enum.sort(added_optional), &"accepts new optional variable {#{&1}}") ++
        Enum.map(renamed, &"variable renamed {#{&1["from"]}} → {#{&1["to"]}}") ++
        Enum.map(Enum.sort(tightened), &"variable {#{&1}} is now always required") ++
        Enum.map(Enum.sort(removed), &"variable {#{&1}} no longer referenced")

    level =
      cond do
        added_required != [] or renamed != [] or tightened != [] -> :breaking
        added_optional != [] or removed != [] -> :compatible
        true -> :cosmetic
      end

    {delta, level, reasons}
  end

  defp required?(spec) when is_map(spec), do: Map.get(spec, "required", true) != false
  defp required?(_), do: true

  defp detect_renames(added, removed, old_vars, new_vars) do
    Enum.reduce(removed, {[], added, []}, fn r, {renames, avail_added, still_removed} ->
      r_refs = MapSet.new(old_vars[r]["refs"])

      case Enum.find(avail_added, fn a -> MapSet.new(new_vars[a]["refs"]) == r_refs end) do
        nil ->
          {renames, avail_added, [r | still_removed]}

        a ->
          {[%{"from" => r, "to" => a} | renames], avail_added -- [a], still_removed}
      end
    end)
  end

  defp diff_outputs(old_c, new_c) do
    added = old_c["outputs"] |> then(&(new_c["outputs"] -- &1)) |> Enum.sort()
    removed = new_c["outputs"] |> then(&(old_c["outputs"] -- &1)) |> Enum.sort()

    reasons =
      Enum.map(removed, &"removed output `#{&1}`") ++
        Enum.map(added, &"produces new output `#{&1}`")

    # A dropped output breaks downstream parsing; a new one is additive.
    level =
      cond do
        removed != [] -> :breaking
        added != [] -> :compatible
        true -> :cosmetic
      end

    {%{"added" => added, "removed" => removed}, level, reasons}
  end

  defp diff_provider(old_c, new_c) do
    case {old_c["provider"], new_c["provider"]} do
      {p, p} ->
        {nil, :cosmetic, []}

      {from, to} ->
        {%{"from" => from, "to" => to}, :compatible, ["provider changed #{from} → #{to}"]}
    end
  end

  defp diff_nodes(old_snapshot, new_snapshot) do
    old_by_id = old_snapshot |> snapshot_nodes() |> Map.new(&{node_id(&1), &1})
    new_by_id = new_snapshot |> snapshot_nodes() |> Map.new(&{node_id(&1), &1})

    removed =
      for {id, n} <- old_by_id,
          not Map.has_key?(new_by_id, id),
          do: %{"id" => id, "label" => node_label(n), "change" => :removed}

    added =
      for {id, n} <- new_by_id,
          not Map.has_key?(old_by_id, id),
          do: %{"id" => id, "label" => node_label(n), "change" => :added}

    changed =
      for {id, new_n} <- new_by_id,
          old_n = old_by_id[id],
          not is_nil(old_n),
          entry = node_change(old_n, new_n),
          into: [] do
        entry
      end

    (removed ++ added ++ changed) |> Enum.reject(&is_nil/1)
  end

  # nil → unchanged; otherwise a change entry. Retype takes precedence over content.
  defp node_change(old_n, new_n) do
    cond do
      node_type(old_n) != node_type(new_n) ->
        %{
          "id" => node_id(new_n),
          "label" => node_label(new_n),
          "change" => :retyped,
          "from" => to_string(node_type(old_n)),
          "to" => to_string(node_type(new_n))
        }

      node_content(old_n) != node_content(new_n) ->
        %{
          "id" => node_id(new_n),
          "label" => node_label(new_n),
          "change" => :content,
          "diff" => line_diff(node_content(old_n), node_content(new_n))
        }

      true ->
        nil
    end
  end

  # Compact, JSON-safe line-level diff via stdlib `List.myers_difference/2`.
  # (The plan referenced `String.myers_difference/2`, but that is grapheme-level;
  # line-level over split content is what the review UI needs and stays JSON-safe.)
  defp line_diff(old, new) do
    ops = List.myers_difference(lines(old), lines(new))

    %{
      "added_lines" => for({:ins, ls} <- ops, l <- ls, do: l),
      "removed_lines" => for({:del, ls} <- ops, l <- ls, do: l)
    }
  end

  defp lines(nil), do: []
  defp lines(s) when is_binary(s), do: String.split(s, "\n")
  defp lines(_), do: []

  defp max_level(levels) do
    Enum.max_by(levels, &Map.fetch!(@severity, &1))
  end

  # ── snapshot / node accessors (string-keyed snapshots and atom-keyed structs) ──

  defp snapshot_nodes(%{"nodes" => nodes}) when is_list(nodes), do: nodes
  defp snapshot_nodes(%{nodes: nodes}) when is_list(nodes), do: nodes
  defp snapshot_nodes(nodes) when is_list(nodes), do: nodes
  defp snapshot_nodes(_), do: []

  # A bare node list carries no edges, so optionality can't be derived from it —
  # those callers get every variable marked required (the safe default).
  defp snapshot_edges(%{"edges" => edges}) when is_list(edges), do: edges
  defp snapshot_edges(%{edges: edges}) when is_list(edges), do: edges
  defp snapshot_edges(_), do: []

  defp edge_source(%{"source_node_id" => id}), do: id
  defp edge_source(%{source_node_id: id}), do: id
  defp edge_source(_), do: nil

  defp edge_target(%{"target_node_id" => id}), do: id
  defp edge_target(%{target_node_id: id}), do: id
  defp edge_target(_), do: nil

  defp edge_branch(%{"metadata" => %{"branch" => b}}), do: b
  defp edge_branch(%{metadata: %{"branch" => b}}), do: b
  defp edge_branch(_), do: nil

  defp node_id(%{"id" => id}), do: id
  defp node_id(%{id: id}), do: id
  defp node_id(_), do: nil

  defp node_content(%{"content" => c}), do: c
  defp node_content(%{content: c}), do: c
  defp node_content(_), do: nil

  defp node_label(%{"label" => l}), do: l
  defp node_label(%{label: l}), do: l
  defp node_label(_), do: nil

  defp node_metadata(%{"metadata" => m}) when is_map(m), do: m
  defp node_metadata(%{metadata: m}) when is_map(m), do: m
  defp node_metadata(_), do: %{}

  defp node_type(%{"type" => t}) when is_binary(t), do: String.to_existing_atom(t)
  defp node_type(%{"type" => t}) when is_atom(t), do: t
  defp node_type(%{type: t}) when is_atom(t), do: t
  defp node_type(%{type: t}) when is_binary(t), do: String.to_existing_atom(t)
  defp node_type(_), do: nil
end
