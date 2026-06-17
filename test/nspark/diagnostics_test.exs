defmodule Nspark.DiagnosticsTest do
  use ExUnit.Case, async: true

  alias Nspark.Diagnostics

  defp node(id, type, content, opts \\ []) do
    %{
      id: id,
      type: type,
      label: Keyword.get(opts, :label, id),
      content: content,
      metadata: Keyword.get(opts, :metadata, %{}),
      is_muted: Keyword.get(opts, :muted, false)
    }
  end

  defp edge(src, tgt, branch \\ nil) do
    meta = if branch, do: %{"branch" => branch}, else: %{}
    %{source_node_id: src, target_node_id: tgt, metadata: meta}
  end

  defp codes(diags), do: Enum.map(diags, & &1.code)

  describe "input contract (replaces undefined/unused variable warnings)" do
    test "a well-formed externalized prompt produces no variable warnings, only an info line" do
      # `customer_name` is provided by a Context node but referenced by no consumer
      # (the old `:unused_variable` false positive); `fraud_score` is referenced by
      # a consumer but provided by no node (the old `:undefined_variable` false
      # positive). Under the input-contract model both are simply caller inputs.
      nodes = [
        node("p", :persona, "You are a helper."),
        node("ctx", :context, "Account {customer_name}"),
        node("cons", :constraint, "Escalate when {fraud_score} is high"),
        node("out", :output, "Return JSON")
      ]

      edges = [edge("ctx", "p"), edge("p", "cons"), edge("cons", "out")]

      diags = Diagnostics.run(nodes, edges)

      refute Enum.any?(diags, &(&1.code in [:undefined_variable, :unused_variable]))
      assert codes(diags) == [:input_contract]

      [info] = diags
      assert info.level == :info
      assert info.message =~ "2 runtime variables"
      assert info.message =~ "all required"
    end

    test "conditional-branch-only variables are reported as optional, matching the contract" do
      nodes = [
        node("cond", :conditional, "tier == premium"),
        node("branch", :constraint, "Offer {discount_code}"),
        node("always", :constraint, "Greet {customer_name}")
      ]

      edges = [edge("cond", "branch", "yes")]

      info =
        Diagnostics.run(nodes, edges)
        |> Enum.find(&(&1.code == :input_contract))

      assert info.level == :info
      assert info.message =~ "2 runtime variables"
      assert info.message =~ "1 required"
      assert info.message =~ "1 optional"
    end

    test "a single input uses singular wording" do
      info =
        [node("a", :constraint, "Use {only_one}")]
        |> Diagnostics.run([])
        |> Enum.find(&(&1.code == :input_contract))

      assert info.message =~ "1 runtime variable,"
      assert info.message =~ "all required"
    end

    test "a graph with no variables emits no input-contract line" do
      nodes = [node("p", :persona, "hello"), node("out", :output, "json")]
      diags = Diagnostics.run(nodes, [edge("p", "out")])
      refute Enum.any?(diags, &(&1.code == :input_contract))
    end

    test "a variable on a muted node is excluded from the contract" do
      nodes = [
        node("live", :constraint, "Use {kept}"),
        node("muted", :constraint, "Use {dropped}", muted: true)
      ]

      info =
        Diagnostics.run(nodes, [])
        |> Enum.find(&(&1.code == :input_contract))

      assert info.message =~ "1 runtime variable,"
      refute info.message =~ "2 runtime"
    end
  end

  describe "structural checks still fire" do
    test "a cycle is reported as an error" do
      nodes = [node("a", :constraint, "x"), node("b", :constraint, "y")]
      edges = [edge("a", "b"), edge("b", "a")]

      diags = Diagnostics.run(nodes, edges)
      assert Enum.any?(diags, &(&1.level == :error and &1.code == :cycle))
    end

    test "missing persona and output are warnings" do
      diags = Diagnostics.run([node("a", :constraint, "do a thing"), node("b", :constraint, "do another")], [edge("a", "b")])
      assert :no_persona in codes(diags)
      assert :no_output in codes(diags)
    end

    test "muted nodes are excluded from structural checks" do
      # Two personas, but one is muted, so no multiple-personas warning.
      nodes = [
        node("p1", :persona, "first"),
        node("p2", :persona, "second", muted: true),
        node("out", :output, "json")
      ]

      diags = Diagnostics.run(nodes, [edge("p1", "out")])
      refute :multiple_personas in codes(diags)
    end
  end
end
