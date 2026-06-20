defmodule Nspark.PromptBasic.TestRunner do
  @moduledoc """
  The Test layer (BUILD_PLAN Phase 4): run author-defined scenarios through the deterministic
  `Selector` to catch the gaps the static lens structurally cannot see (memo §6).

  A scenario is a slice of intended behavior:

      %{
        name: "intake: start a return",
        given: %{state: "intake", memory: %{"item_received" => "true"}, conds: ["user_wants_return"]},
        expect: %{handled: true, state_to: "verifying", tool: "lookup_order"}
      }

  `conds` are the semantic atoms the author asserts are TRUE this turn (what an LLM would judge
  at runtime); state/memory are matched deterministically. No LLM is involved — this tests the
  agent's *logic structure*, including inputs that silently drain to `[OTHERWISE]`.

  Every `expect` key is optional; only the provided ones are checked. Expectations are expressed
  as stable facts (handled / target state / tool name), never IR rule ids — rule ids shift with
  compile order, so storing them would make saved scenarios fragile.

  `run/2` returns `{results, summary}` where `summary` carries per-node attribution so the canvas
  can paint a green/red dot on each rule and a "drains" count on the fallback.
  """

  alias Nspark.PromptBasic.{Compiler, Selector}

  @type scenario :: %{
          optional(:name) => String.t(),
          required(:given) => map(),
          optional(:expect) => map()
        }

  @type result :: %{
          scenario: scenario(),
          fired: String.t() | :otherwise,
          fired_node_id: String.t() | nil,
          drained: boolean(),
          status: :pass | :fail | :drain,
          failures: [String.t()],
          tie: [String.t()]
        }

  @type summary :: %{
          total: non_neg_integer(),
          passed: non_neg_integer(),
          failed: non_neg_integer(),
          drained: non_neg_integer(),
          node_status: %{String.t() => :pass | :fail},
          drains: non_neg_integer()
        }

  @doc "Run scenarios against the graph's current control layer. Returns `{results, summary}`."
  @spec run([map()], [scenario()]) :: {[result()], summary()}
  def run(nodes, scenarios) do
    ir = Compiler.from_graph(nodes)
    rule_node = Compiler.rule_id_to_node_id(nodes)
    results = Enum.map(scenarios, &check(ir, rule_node, &1))
    {results, summarize(results)}
  end

  defp check(ir, rule_node, scenario) do
    res = Selector.fire(ir, normalize_given(scenario[:given] || %{}))
    drained = res.rule == :otherwise
    fired = if drained, do: :otherwise, else: res.rule.id
    failures = failures(scenario[:expect] || %{}, res, drained)

    %{
      scenario: scenario,
      fired: fired,
      fired_node_id: if(drained, do: nil, else: rule_node[res.rule.id]),
      drained: drained,
      status: status(failures, drained),
      failures: failures,
      tie: res.tie
    }
  end

  # Author input arrives string-keyed (from forms/JSON); the Selector world uses
  # atom-keyed :state/:memory/:conds. Accept either.
  defp normalize_given(given) do
    %{
      state: given[:state] || given["state"],
      memory: given[:memory] || given["memory"] || %{},
      conds: given[:conds] || given["conds"] || []
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp failures(expect, res, drained) do
    Enum.flat_map(expect, fn
      {k, nil} when k in [:handled, :state_to, :tool, "handled", "state_to", "tool"] ->
        []

      {k, want} when k in [:handled, "handled"] ->
        cmp("handled", want, not drained)

      {k, want} when k in [:state_to, "state_to"] ->
        cmp("state_to", want, res.result.state_to)

      {k, want} when k in [:tool, "tool"] ->
        if want in res.result.tools,
          do: [],
          else: ["tool #{inspect(want)} not called (called: #{inspect(res.result.tools)})"]

      _ ->
        []
    end)
  end

  defp cmp(_field, want, want), do: []
  defp cmp(field, want, got), do: ["#{field}: expected #{inspect(want)}, got #{inspect(got)}"]

  # A drained scenario with no failed expectations is a coverage GAP, not a pass:
  # the input was unhandled. Only a handled scenario meeting its expectations passes.
  defp status([], true), do: :drain
  defp status([], false), do: :pass
  defp status(_failures, _drained), do: :fail

  defp summarize(results) do
    node_status =
      Enum.reduce(results, %{}, fn r, acc ->
        case r.fired_node_id do
          nil -> acc
          id -> Map.update(acc, id, node_mark(r.status), &merge_mark(&1, node_mark(r.status)))
        end
      end)

    %{
      total: length(results),
      passed: Enum.count(results, &(&1.status == :pass)),
      failed: Enum.count(results, &(&1.status == :fail)),
      drained: Enum.count(results, &(&1.status == :drain)),
      node_status: node_status,
      drains: Enum.count(results, & &1.drained)
    }
  end

  defp node_mark(:fail), do: :fail
  defp node_mark(_), do: :pass

  # Red wins: a rule that fired in any failing scenario is flagged, even if it also passed others.
  defp merge_mark(:fail, _), do: :fail
  defp merge_mark(_, :fail), do: :fail
  defp merge_mark(_, _), do: :pass
end
