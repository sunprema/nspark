defmodule Nspark.PromptBasic.SelectorTest do
  @moduledoc """
  Test-layer scenarios ported from `docs/pivot/rma_tests.exs`.

  Each scenario is a slice of intended behavior the static lens cannot infer:
  "given this state + these true conditions, the agent should do X." The deterministic
  Selector runs real priority/state/memory resolution — no LLM. Prototype result on the
  RMA agent was 10 pass · 3 coverage gaps · 0 regressions; the gaps are encoded here as
  explicit "drains to OTHERWISE" assertions so the coverage holes stay visible.
  """
  use ExUnit.Case, async: true

  alias Nspark.PromptBasic.{Parser, Selector}

  @rma Path.join(__DIR__, "../../support/fixtures/prompt_basic/PROMPT_BASIC_RMA.md")

  setup_all do
    {:ok, prog: Parser.parse_file(@rma)}
  end

  defp fire(prog, given) do
    res = Selector.fire(prog, given)
    fired = if res.rule == :otherwise, do: :otherwise, else: res.rule.id
    {fired, res}
  end

  describe "happy-path specs" do
    test "intake: start return with order id → verifying, lookup_order", %{prog: prog} do
      {fired, res} = fire(prog, %{state: "intake", conds: ["user_wants_return", "has_order_id"]})
      assert fired == "R2"
      assert res.result.state_to == "verifying"
      assert "lookup_order" in res.result.tools
    end

    test "intake: start return without order id → ask (R3)", %{prog: prog} do
      {fired, res} = fire(prog, %{state: "intake", conds: ["user_wants_return", "no_order_id"]})
      assert fired == "R3"
      assert res.rule != :otherwise
    end

    test "verifying: eligible → choosing_resolution", %{prog: prog} do
      {_fired, res} = fire(prog, %{state: "verifying", conds: ["order_eligible"]})
      assert res.result.state_to == "choosing_resolution"
    end

    test "verifying: not eligible → closed", %{prog: prog} do
      {_fired, res} = fire(prog, %{state: "verifying", conds: ["order_not_eligible"]})
      assert res.result.state_to == "closed"
    end

    test "choose refund → awaiting_return + label (R6)", %{prog: prog} do
      {fired, res} = fire(prog, %{state: "choosing_resolution", conds: ["wants_refund"]})
      assert fired == "R6"
      assert res.result.state_to == "awaiting_return"
      assert "generate_return_label" in res.result.tools
    end

    test "awaiting: item received → inspecting + flag_inspection", %{prog: prog} do
      {_fired, res} =
        fire(prog, %{state: "awaiting_return", memory: %{"item_received" => "true"}, conds: []})

      assert res.result.state_to == "inspecting"
      assert "flag_inspection" in res.result.tools
    end

    test "awaiting: status check while not received → handled (R9)", %{prog: prog} do
      {fired, res} =
        fire(prog, %{
          state: "awaiting_return",
          memory: %{"item_received" => "false"},
          conds: ["user_asks_status"]
        })

      assert fired == "R9"
      assert res.rule != :otherwise
    end

    test "inspecting: pass + refund → closed + issue_refund", %{prog: prog} do
      {_fired, res} =
        fire(prog, %{
          state: "inspecting",
          memory: %{"inspection_passed" => "true", "resolution_choice" => "refund"},
          conds: []
        })

      assert res.result.state_to == "closed"
      assert "issue_refund" in res.result.tools
    end

    test "global guard: angry user from any state → escalated (R1)", %{prog: prog} do
      {fired, res} = fire(prog, %{state: "awaiting_return", conds: ["user_angry"]})
      assert fired == "R1"
      assert res.result.state_to == "escalated"
      assert "create_support_ticket" in res.result.tools
    end
  end

  describe "tie resolution" do
    test "refund + replacement both true → tie [R6, R7], R6 wins on document order", %{prog: prog} do
      {fired, res} =
        fire(prog, %{state: "choosing_resolution", conds: ["wants_refund", "wants_replacement"]})

      assert fired == "R6"
      assert res.tie == ["R6", "R7"]
    end
  end

  describe "coverage gaps (drain to OTHERWISE — the lens structurally cannot see these)" do
    test "user chooses repair (offered in prompt) but no rule exists", %{prog: prog} do
      {fired, res} = fire(prog, %{state: "choosing_resolution", conds: ["wants_repair"]})
      assert fired == :otherwise
      assert res.result[:drained] == true
    end

    test "escalated user asks for an update — dead state strands a real message", %{prog: prog} do
      {fired, res} = fire(prog, %{state: "escalated", conds: ["user_asks_status"]})
      assert fired == :otherwise
      assert res.result[:drained] == true
    end

    test "inspection passes but resolution was repair", %{prog: prog} do
      {fired, res} =
        fire(prog, %{
          state: "inspecting",
          memory: %{"inspection_passed" => "true", "resolution_choice" => "repair"},
          conds: []
        })

      assert fired == :otherwise
      assert res.result[:drained] == true
    end
  end
end
