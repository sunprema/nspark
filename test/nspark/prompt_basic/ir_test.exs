defmodule Nspark.PromptBasic.IRTest do
  @moduledoc """
  Phase 1: the IR is the one normalized object. These tests prove Producer A
  (bracket text → IR), JSON persistence round-trips losslessly, and an `%IR{}`
  is a drop-in for both the static lens and the deterministic selector.
  """
  use ExUnit.Case, async: true

  alias Nspark.PromptBasic.{Analyzer, IR, Parser, Selector}

  @rma Path.join(__DIR__, "../../support/fixtures/prompt_basic/PROMPT_BASIC_RMA.md")

  setup_all do
    source = File.read!(@rma)
    {:ok, source: source, ir: IR.from_text(source)}
  end

  describe "Producer A: text → IR" do
    test "carries the parser's program through unchanged", %{source: source, ir: ir} do
      prog = Parser.parse(source)
      assert ir.rules == prog.rules
      assert ir.decl_mem == prog.decl_mem
      assert ir.decl_tools == prog.decl_tools
      assert ir.init_state == prog.init_state
      assert ir.version == "1.0"
    end
  end

  describe "JSON persistence round-trip" do
    test "to_json/from_json is lossless for the full RMA program", %{ir: ir} do
      restored = ir |> IR.to_json() |> IR.from_json()
      assert restored == ir
    end

    test "to_json is JSON-safe (encodes and decodes cleanly)", %{ir: ir} do
      decoded = ir |> IR.to_json() |> Jason.encode!() |> Jason.decode!()
      restored = IR.from_json(decoded)
      assert restored == ir
    end

    test "tuples, atom enums and :otherwise priority survive the trip", %{ir: ir} do
      json = IR.to_json(ir)

      # mem_writes tuples become %{"key","value"} maps
      r2 = Enum.find(json["rules"], &(&1["id"] == "R2"))
      assert %{"key" => "order_id", "value" => "user_order_id"} in r2["mem_writes"]

      # the [OTHERWISE] fallback serializes its priority as a string
      assert Enum.any?(json["rules"], &(&1["priority"] == "otherwise"))

      # ...and restores to the :otherwise atom the Selector expects
      restored = IR.from_json(json)
      assert Enum.any?(restored.rules, &(&1.priority == :otherwise))
    end
  end

  describe "IR is a drop-in for the analysis layers" do
    test "the lens produces identical findings on the IR and the raw parse map",
         %{source: source, ir: ir} do
      assert Analyzer.run(ir) == Analyzer.run(Parser.parse(source))
    end

    test "the selector fires correctly against an IR", %{ir: ir} do
      res = Selector.fire(ir, %{state: "intake", conds: ["user_wants_return", "has_order_id"]})
      assert res.rule.id == "R2"
      assert res.result.state_to == "verifying"
    end

    test "a round-tripped IR still drives the selector (proves persisted IR is executable)",
         %{ir: ir} do
      restored = ir |> IR.to_json() |> IR.from_json()

      res =
        Selector.fire(restored, %{
          state: "choosing_resolution",
          conds: ["wants_refund", "wants_replacement"]
        })

      assert res.rule.id == "R6"
      assert res.tie == ["R6", "R7"]
    end
  end
end
