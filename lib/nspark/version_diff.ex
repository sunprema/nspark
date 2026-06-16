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
  # the ONE definition of "what is a variable"; `Nspark.Diagnostics` delegates
  # here so the contract and the `:undefined_variable` check can never disagree.
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

  v1 treats every referenced `{var}` as a required string input (no typed schema
  yet). `outputs` are the `output_var`s declared on agent nodes. `provider` is
  echoed only if the snapshot pins one; provider-agnostic versions get `nil`
  rather than a guess.

  Accepts either the full snapshot map (`%{"nodes" => [...]}`) or a bare list of
  nodes.
  """
  @spec contract(map() | [map()]) :: %{String.t() => term()}
  def contract(snapshot) do
    nodes = snapshot_nodes(snapshot)

    %{
      "variables" => variables_contract(nodes),
      "outputs" => outputs(nodes),
      "provider" => provider(snapshot)
    }
  end

  # ── contract pieces ─────────────────────────────────────────────────────────

  defp variables_contract(nodes) do
    nodes
    |> Enum.flat_map(fn n ->
      id = node_id(n)
      n |> node_content() |> variables_in() |> Enum.map(&{&1, id})
    end)
    |> Enum.group_by(fn {name, _id} -> name end, fn {_name, id} -> id end)
    |> Map.new(fn {name, ids} ->
      {name, %{"required" => true, "refs" => Enum.uniq(ids)}}
    end)
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

  # ── snapshot / node accessors (string-keyed snapshots and atom-keyed structs) ──

  defp snapshot_nodes(%{"nodes" => nodes}) when is_list(nodes), do: nodes
  defp snapshot_nodes(%{nodes: nodes}) when is_list(nodes), do: nodes
  defp snapshot_nodes(nodes) when is_list(nodes), do: nodes
  defp snapshot_nodes(_), do: []

  defp node_id(%{"id" => id}), do: id
  defp node_id(%{id: id}), do: id
  defp node_id(_), do: nil

  defp node_content(%{"content" => c}), do: c
  defp node_content(%{content: c}), do: c
  defp node_content(_), do: nil

  defp node_metadata(%{"metadata" => m}) when is_map(m), do: m
  defp node_metadata(%{metadata: m}) when is_map(m), do: m
  defp node_metadata(_), do: %{}

  defp node_type(%{"type" => t}) when is_binary(t), do: String.to_existing_atom(t)
  defp node_type(%{"type" => t}) when is_atom(t), do: t
  defp node_type(%{type: t}) when is_atom(t), do: t
  defp node_type(%{type: t}) when is_binary(t), do: String.to_existing_atom(t)
  defp node_type(_), do: nil
end
