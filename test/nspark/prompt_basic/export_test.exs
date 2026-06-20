defmodule Nspark.PromptBasic.ExportTest do
  @moduledoc "Phase 5: format-first export bundles the contract with the rendered program."
  use ExUnit.Case, async: true

  alias Nspark.PromptBasic.{Export, IR, Parser}

  defp nodes do
    [
      %{type: :state, label: "intake", metadata: %{"initial" => true}},
      %{type: :memory, label: "order_id", metadata: %{"default" => "null"}},
      %{type: :tool, label: "lookup_order", content: "Fetch order by id", metadata: %{"output" => "order"}},
      %{
        type: :rule,
        content:
          "[WHEN] state = intake AND user_wants_return\n[TOOL] lookup_order -> order\n[STATE] verifying\n[RESPOND]\nFound it.\n[STOP]",
        metadata: %{"priority" => 20, "section" => "INTAKE", "order" => 1}
      },
      %{
        type: :rule,
        content: "[ASK]\nHow can I help?",
        metadata: %{"otherwise" => true, "order" => 99}
      }
    ]
  end

  test "render bundles the execution contract ahead of the program" do
    out = Export.render(nodes())
    assert out =~ "# PromptBasic Execution Contract"
    assert out =~ "highest `[PRIORITY]`"
    # contract precedes the program
    assert :binary.match(out, "Execution Contract") < :binary.match(out, "[PRIORITY] 20")
  end

  test "program renders the control layer as bracket source" do
    prog = Export.program(nodes())
    assert prog =~ "[STATE] intake"
    assert prog =~ "[MEMORY] order_id = null"
    assert prog =~ "[TOOL] lookup_order -> order"
    assert prog =~ "[PRIORITY] 20"
    assert prog =~ "[WHEN] state = intake AND user_wants_return"
    assert prog =~ "[OTHERWISE]"
  end

  test "the exported program parses back to the same IR the graph compiles to" do
    prog = Export.program(nodes())
    assert IR.from_program(Parser.parse(prog)) == Nspark.PromptBasic.Compiler.from_graph(nodes())
  end

  test "contract/0 is self-contained (no file dependency)" do
    assert Export.contract() =~ "{{tool:var}}"
    assert Export.contract() =~ "{{memory:key}}"
  end
end
