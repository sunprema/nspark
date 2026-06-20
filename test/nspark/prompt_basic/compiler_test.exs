defmodule Nspark.PromptBasic.CompilerTest do
  @moduledoc """
  Phase 3 / Producer B: the graph → IR compiler. The headline assertion is the DoD —
  a graph of `rule`/`state`/`memory`/`tool` nodes compiles to the *same IR shape* the
  bracket parser produces for the equivalent program — plus mode detection (flat ladder
  vs. state machine) and muted-node exclusion.
  """
  use ExUnit.Case, async: true

  alias Nspark.PromptBasic.{Compiler, IR}

  # A 2-state slice modelled as graph nodes (priority/section/order from structure,
  # the [WHEN]/actions body as inspectable content).
  defp rma_nodes do
    [
      %{type: :state, label: "intake", metadata: %{"initial" => true}},
      %{type: :state, label: "verifying", metadata: %{}},
      %{type: :state, label: "escalated", metadata: %{}},
      %{type: :memory, label: "order_id", metadata: %{"default" => "null"}},
      %{
        type: :tool,
        label: "lookup_order",
        content: "Fetches order details by id",
        metadata: %{"output" => "order"}
      },
      %{
        type: :tool,
        label: "create_support_ticket",
        content: "Escalates to a human",
        metadata: %{"output" => "ticket"}
      },
      %{
        type: :rule,
        content:
          "[WHEN] user_angry\n[TOOL] create_support_ticket -> ticket\n[STATE] escalated\n" <>
            "[RESPOND]\nA specialist will help.\n[STOP]",
        metadata: %{"priority" => 100, "section" => "GLOBAL", "order" => 1}
      },
      %{
        type: :rule,
        content:
          "[WHEN] state = intake AND user_wants_return AND has_order_id\n" <>
            "[TOOL] lookup_order -> order\n[MEMORY] order_id = user_order_id\n[STATE] verifying\n" <>
            "[RESPOND]\nFound it.\n[STOP]",
        metadata: %{"priority" => 20, "section" => "INTAKE", "order" => 2}
      },
      %{
        type: :rule,
        content: "[ASK]\nHow can I help?",
        metadata: %{"otherwise" => true, "section" => "FALLBACK", "order" => 99}
      }
    ]
  end

  @equivalent_source """
  [PROMPTBASIC MINI]

  [STATE] intake

  [MEMORY] order_id = null

  [TOOL] lookup_order -> order
  Fetches order details by id

  [TOOL] create_support_ticket -> ticket
  Escalates to a human

  # GLOBAL
  [PRIORITY] 100
  [WHEN] user_angry
  [TOOL] create_support_ticket -> ticket
  [STATE] escalated
  [RESPOND]
  A specialist will help.
  [STOP]

  # INTAKE
  [PRIORITY] 20
  [WHEN] state = intake AND user_wants_return AND has_order_id
  [TOOL] lookup_order -> order
  [MEMORY] order_id = user_order_id
  [STATE] verifying
  [RESPOND]
  Found it.
  [STOP]

  # FALLBACK
  [OTHERWISE]
  [ASK]
  How can I help?
  """

  describe "DoD: graph → IR == text → IR" do
    test "a graph compiles to the same IR shape as the equivalent bracket program" do
      assert Compiler.from_graph(rma_nodes()) == IR.from_text(@equivalent_source)
    end

    test "the assembled source round-trips through the parser" do
      source = Compiler.to_source(rma_nodes())
      assert IR.from_text(source) == Compiler.from_graph(rma_nodes())
    end
  end

  describe "structure extracted from the graph" do
    setup do
      {:ok, ir: Compiler.from_graph(rma_nodes())}
    end

    test "init state, memory and tool declarations", %{ir: ir} do
      assert ir.init_state == "intake"
      assert ir.decl_mem == %{"order_id" => "null"}
      assert Enum.map(ir.decl_tools, & &1.name) == ["lookup_order", "create_support_ticket"]
    end

    test "rules carry priority, section and document order (R-ids)", %{ir: ir} do
      [r1, r2, r3] = ir.rules
      assert {r1.id, r1.priority, r1.section} == {"R1", 100, "GLOBAL"}
      assert {r2.id, r2.priority, r2.section} == {"R2", 20, "INTAKE"}
      assert {r3.id, r3.priority} == {"R3", :otherwise}
    end

    test "the intake rule's body parses into atoms, tool, memory write and transition", %{ir: ir} do
      r2 = Enum.at(ir.rules, 1)
      assert r2.when_op == :and
      # Atom order is not significant to AND/OR evaluation; assert the set.
      assert MapSet.new(r2.atoms, & &1.key) ==
               MapSet.new(["state", "user_wants_return", "has_order_id"])
      assert Enum.map(r2.tools, & &1.name) == ["lookup_order"]
      assert {"order_id", "user_order_id"} in r2.mem_writes
      assert r2.state_writes == ["verifying"]
    end
  end

  describe "mode-aware rendering" do
    test "more than one state → :stateful (state machine)" do
      assert rma_nodes() |> Compiler.from_graph() |> IR.mode() == :stateful
    end

    test "a flat decision table (no state guards) → :flat (priority ladder)" do
      nodes = [
        %{type: :rule, content: "[WHEN] shipment_lost\n[RESPOND]\nLost.\n[STOP]",
          metadata: %{"priority" => 10, "order" => 1}},
        %{type: :rule, content: "[WHEN] has_tracking_number\n[RESPOND]\nHere.\n[STOP]",
          metadata: %{"priority" => 6, "order" => 2}}
      ]

      ir = Compiler.from_graph(nodes)
      assert IR.mode(ir) == :flat
      assert IR.states(ir) == []
    end
  end

  describe "tolerance and filtering" do
    test "string-keyed snapshot nodes compile identically to atom-keyed nodes" do
      atom_keyed = rma_nodes()
      string_keyed = Enum.map(atom_keyed, &stringify/1)
      assert Compiler.from_graph(string_keyed) == Compiler.from_graph(atom_keyed)
    end

    test "muted nodes are excluded" do
      muted = %{
        type: :rule,
        content: "[WHEN] never\n[RESPOND]\nx\n[STOP]",
        is_muted: true,
        metadata: %{"priority" => 5, "order" => 0}
      }

      ir = Compiler.from_graph([muted | rma_nodes()])
      assert length(ir.rules) == 3
      refute Enum.any?(ir.rules, &("never" in Enum.map(&1.atoms, fn a -> a.key end)))
    end
  end

  defp stringify(node) do
    Map.new(node, fn
      {:metadata, v} -> {"metadata", v}
      {k, v} when is_atom(v) -> {to_string(k), to_string(v)}
      {k, v} -> {to_string(k), v}
    end)
  end
end
