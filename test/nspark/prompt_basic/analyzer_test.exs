defmodule Nspark.PromptBasic.AnalyzerTest do
  @moduledoc """
  Static-lens findings ported from `docs/pivot/lens_analyzer.exs` and the soundness
  boundary documented in `docs/pivot/DESIGN_MEMO_two_layer_lens.md` §5. These assert the
  real defects the lens caught by hand-review: the dead `escalated` state and write-only
  `order_id` in RMA, and the dead `last_carrier` memory in the flat logistics agent.
  """
  use ExUnit.Case, async: true

  alias Nspark.PromptBasic.{Analyzer, Parser}

  @rma Path.join(__DIR__, "../../support/fixtures/prompt_basic/PROMPT_BASIC_RMA.md")
  @logistics Path.join(__DIR__, "../../support/fixtures/prompt_basic/PROMPT_BASIC_EXAMPLE1.md")

  defp finding(findings, title), do: Enum.find(findings, fn {_s, t, _l} -> t == title end)
  defp severity(findings, title), do: finding(findings, title) |> elem(0)
  defp lines(findings, title), do: finding(findings, title) |> elem(2)
  defp text(findings, title), do: lines(findings, title) |> Enum.join("\n")

  describe "RMA (stateful)" do
    setup do
      {:ok, findings: @rma |> Parser.parse_file() |> Analyzer.run()}
    end

    test "flags the dead `escalated` state as an error", %{findings: findings} do
      assert severity(findings, "DEAD STATES") == :error
      assert text(findings, "DEAD STATES") =~ "escalated"
    end

    test "flags write-only `order_id` and dead `repair_eligible` memory", %{findings: findings} do
      assert severity(findings, "MEMORY USAGE") == :warn
      body = text(findings, "MEMORY USAGE")
      assert body =~ "order_id"
      assert body =~ "repair_eligible"
    end

    test "all tool invocations are declared and all outputs resolve", %{findings: findings} do
      assert severity(findings, "TOOL INVENTORY") == :ok
      assert severity(findings, "OUTPUT REFERENCES") == :ok
    end

    test "state guards make rules mutually exclusive — zero preemption collisions",
         %{findings: findings} do
      assert severity(findings, "PRIORITY PREEMPTION (heuristic)") == :ok
    end
  end

  describe "logistics (flat decision table)" do
    setup do
      {:ok, findings: @logistics |> Parser.parse_file() |> Analyzer.run()}
    end

    test "flags the dead `last_carrier` memory", %{findings: findings} do
      assert severity(findings, "MEMORY USAGE") == :warn
      assert text(findings, "MEMORY USAGE") =~ "last_carrier"
    end

    test "surfaces literal-phrased conditions as a paraphrase smell", %{findings: findings} do
      assert text(findings, "CONDITION INVENTORY") =~ "literal-phrased"
    end

    test "flat agent without state guards triggers the preemption heuristic (advisory only)",
         %{findings: findings} do
      assert severity(findings, "PRIORITY PREEMPTION (heuristic)") == :warn
    end
  end
end
