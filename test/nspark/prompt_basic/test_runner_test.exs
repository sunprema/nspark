defmodule Nspark.PromptBasic.TestRunnerTest do
  @moduledoc """
  Phase 4: the Test layer. Scenarios run through the Selector against a graph's control
  layer, classified pass / fail / drain, with per-node attribution for canvas badges.
  """
  use ExUnit.Case, async: true

  alias Nspark.PromptBasic.TestRunner

  # A small RMA-style graph: a global escalation guard, an intake rule, and a fallback.
  # `wants_repair` is deliberately unhandled (the classic coverage gap).
  defp nodes do
    [
      %{id: "s_intake", type: :state, label: "intake", metadata: %{"initial" => true}},
      %{id: "s_verifying", type: :state, label: "verifying", metadata: %{}},
      %{id: "t_lookup", type: :tool, label: "lookup_order", metadata: %{"output" => "order"}},
      %{
        id: "r_intake",
        type: :rule,
        content:
          "[WHEN] state = intake AND user_wants_return\n[TOOL] lookup_order -> order\n[STATE] verifying\n[RESPOND]\nFound it.\n[STOP]",
        metadata: %{"priority" => 20, "section" => "INTAKE", "order" => 1}
      },
      %{
        id: "r_fallback",
        type: :rule,
        content: "[ASK]\nHow can I help?",
        metadata: %{"otherwise" => true, "order" => 99}
      }
    ]
  end

  test "a met expectation passes and attributes to the fired rule node" do
    scenarios = [
      %{
        name: "start return",
        given: %{state: "intake", conds: ["user_wants_return"]},
        expect: %{handled: true, state_to: "verifying", tool: "lookup_order"}
      }
    ]

    {[res], summary} = TestRunner.run(nodes(), scenarios)
    assert res.status == :pass
    assert res.fired == "R1"
    assert res.fired_node_id == "r_intake"
    assert summary.passed == 1
    assert summary.node_status["r_intake"] == :pass
  end

  test "an unhandled input is a coverage gap (drain), not a pass" do
    scenarios = [
      %{name: "repair gap", given: %{state: "intake", conds: ["wants_repair"]}, expect: %{}}
    ]

    {[res], summary} = TestRunner.run(nodes(), scenarios)
    assert res.drained
    assert res.fired == :otherwise
    assert res.status == :drain
    assert summary.drains == 1
    assert summary.drained == 1
  end

  test "a wrong expectation fails and marks the node red" do
    scenarios = [
      %{
        name: "wrong target",
        given: %{state: "intake", conds: ["user_wants_return"]},
        expect: %{state_to: "closed"}
      }
    ]

    {[res], summary} = TestRunner.run(nodes(), scenarios)
    assert res.status == :fail
    assert summary.failed == 1
    assert summary.node_status["r_intake"] == :fail
    assert hd(res.failures) =~ "state_to"
  end

  test "red wins when a node both passes and fails across scenarios" do
    scenarios = [
      %{name: "ok", given: %{state: "intake", conds: ["user_wants_return"]}, expect: %{handled: true}},
      %{name: "bad", given: %{state: "intake", conds: ["user_wants_return"]}, expect: %{state_to: "nope"}}
    ]

    {_results, summary} = TestRunner.run(nodes(), scenarios)
    assert summary.node_status["r_intake"] == :fail
  end

  test "string-keyed given/expect (from forms) works the same as atom-keyed" do
    scenarios = [
      %{
        "name" => "start return",
        given: %{"state" => "intake", "conds" => ["user_wants_return"]},
        expect: %{"handled" => true, "state_to" => "verifying"}
      }
    ]

    {[res], _summary} = TestRunner.run(nodes(), scenarios)
    assert res.status == :pass
  end

  test "summary tallies pass/fail/drain across a mixed suite" do
    scenarios = [
      %{name: "a", given: %{state: "intake", conds: ["user_wants_return"]}, expect: %{handled: true}},
      %{name: "b", given: %{state: "intake", conds: ["wants_repair"]}, expect: %{}},
      %{name: "c", given: %{state: "intake", conds: ["user_wants_return"]}, expect: %{tool: "issue_refund"}}
    ]

    {_results, summary} = TestRunner.run(nodes(), scenarios)
    assert summary.total == 3
    assert summary.passed == 1
    assert summary.drained == 1
    assert summary.failed == 1
  end
end
