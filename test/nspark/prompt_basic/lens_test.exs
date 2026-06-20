defmodule Nspark.PromptBasic.LensTest do
  @moduledoc """
  Phase 2: the graph lens. Asserts that static findings are resolved back to the
  specific graph node ids they affect (dead state → state node, dead memory →
  memory node, unresolved ref / unreachable / undeclared tool → rule node), so the
  Studio can render per-node badges through the diagnostics pipeline.
  """
  use ExUnit.Case, async: true

  alias Nspark.PromptBasic.Lens

  # A graph with deliberate defects, each on a known node id.
  defp nodes do
    [
      %{id: "s_intake", type: :state, label: "intake", metadata: %{"initial" => true}},
      %{id: "s_verifying", type: :state, label: "verifying", metadata: %{}},
      # entered by R1 but no rule reads `state = escalated` → dead state
      %{id: "s_escalated", type: :state, label: "escalated", metadata: %{}},
      # declared but never read or written → dead memory
      %{id: "m_unused", type: :memory, label: "repair_eligible", metadata: %{"default" => "false"}},
      # declared and never invoked → unused tool
      %{id: "t_unused", type: :tool, label: "issue_refund", metadata: %{"output" => "refund"}},
      %{
        id: "r_global",
        type: :rule,
        label: "escalation guard",
        content: "[WHEN] user_angry\n[STATE] escalated\n[RESPOND]\n{{tool:ticket}}\n[STOP]",
        metadata: %{"priority" => 100, "section" => "GLOBAL", "order" => 1}
      },
      %{
        id: "r_intake",
        type: :rule,
        label: "start return",
        content:
          "[WHEN] state = intake AND user_wants_return\n[STATE] verifying\n[RESPOND]\nok\n[STOP]",
        metadata: %{"priority" => 20, "section" => "INTAKE", "order" => 2}
      },
      # reads `state = verifying`, so verifying is NOT dead — escalated is the only dead state
      %{
        id: "r_verify",
        type: :rule,
        label: "verify",
        content: "[WHEN] state = verifying AND order_eligible\n[STATE] intake\n[RESPOND]\nok\n[STOP]",
        metadata: %{"priority" => 30, "section" => "VERIFYING", "order" => 3}
      },
      %{
        id: "r_other",
        type: :rule,
        label: "fallback",
        content: "[ASK]\nhow can I help?",
        metadata: %{"otherwise" => true, "order" => 99}
      }
    ]
  end

  defp by_code(diags, code), do: Enum.filter(diags, &(&1.code == code))

  setup do
    {:ok, diags: Lens.diagnostics(nodes())}
  end

  test "returns nothing for a graph with no control layer" do
    assert Lens.diagnostics([%{id: "p", type: :persona, label: "P", metadata: %{}}]) == []
  end

  test "dead state is an error tagged on the state node", %{diags: diags} do
    [d] = by_code(diags, :pb_dead_state)
    assert d.level == :error
    assert d.node_ids == ["s_escalated"]
    assert d.message =~ "escalated"
  end

  test "dead memory is a warning tagged on the memory node", %{diags: diags} do
    [d] = by_code(diags, :pb_dead_memory)
    assert d.level == :warning
    assert d.node_ids == ["m_unused"]
  end

  test "unused tool is a warning tagged on the tool node", %{diags: diags} do
    [d] = by_code(diags, :pb_unused_tool)
    assert d.level == :warning
    assert d.node_ids == ["t_unused"]
  end

  test "unresolved {{tool:_}} ref is an error tagged on the rule node", %{diags: diags} do
    [d] = by_code(diags, :pb_unresolved_ref)
    assert d.level == :error
    assert d.node_ids == ["r_global"]
    assert d.message =~ "ticket"
  end

  test "clean rules produce no unreachable/tie findings", %{diags: diags} do
    assert by_code(diags, :pb_unreachable) == []
    assert by_code(diags, :pb_tie) == []
  end

  test "every diagnostic carries the pipeline shape" do
    for d <- Lens.diagnostics(nodes()) do
      assert %{level: _, code: _, message: _, node_ids: ids} = d
      assert is_list(ids)
    end
  end
end
