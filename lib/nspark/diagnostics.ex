defmodule Nspark.Diagnostics do
  @moduledoc """
  Graph validation checks. Operates on Ash resource structs (live editing)
  or string-keyed maps (snapshot replay). Returns a list of diagnostic maps
  with :level, :code, :message, and :node_ids.

  See docs/PRD.md "Compiler Diagnostics" and UX §9.
  """

  @type level :: :error | :warning
  @type t :: %{
          level: level(),
          code: atom(),
          message: String.t(),
          node_ids: [String.t()]
        }

  @doc """
  Run all checks against the current graph. Only active (non-muted) nodes
  are checked; edges reference the full set.

  Returns a list of `t()` maps, errors before warnings.
  """
  @spec run([map()], [map()]) :: [t()]
  def run(nodes, edges) do
    active = Enum.reject(nodes, &muted?/1)

    []
    |> check_cycle(active, edges)
    |> check_floating(active, edges)
    |> check_no_persona(active)
    |> check_multiple_personas(active)
    |> check_no_output(active)
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

  defp check_floating(diags, nodes, _edges) when length(nodes) < 2, do: diags

  defp check_floating(diags, nodes, edges) do
    connected = edge_node_id_set(edges)
    floating = Enum.filter(nodes, fn n -> not MapSet.member?(connected, node_id(n)) end)

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

  defp check_no_persona(diags, []), do: diags

  defp check_no_persona(diags, nodes) do
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

  defp check_no_output(diags, []), do: diags

  defp check_no_output(diags, nodes) do
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
