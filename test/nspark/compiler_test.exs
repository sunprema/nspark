defmodule Nspark.CompilerTest do
  use ExUnit.Case, async: true

  alias Nspark.Compiler

  defp node(type, label, content, muted \\ false),
    do: %{type: type, label: label, content: content, is_muted: muted}

  test "assembles sections in compile order and excludes muted nodes" do
    nodes = [
      node(:output, "out", "Return ONLY JSON"),
      node(:persona, "p", "You are a planner"),
      node(:constraint, "c", "Be terse", true),
      node(:context, "ctx", "Use {inventory}")
    ]

    result = Compiler.compile(nodes)

    assert result.included == 3
    assert result.excluded == 1
    assert result.token_estimate > 0
    # MISSION (persona) -> CONTEXT -> OUTPUT FORMAT, in that order
    assert result.markdown =~ ~r/# MISSION.*# CONTEXT.*# OUTPUT FORMAT/s
    assert result.markdown =~ "You are a planner"
    refute result.markdown =~ "Be terse"
  end

  test "empty graph compiles to empty markdown" do
    assert %{markdown: "", included: 0, excluded: 0, token_estimate: 0} = Compiler.compile([])
  end

  test "falls back to the label when content is blank" do
    result = Compiler.compile([node(:persona, "My Persona", "")])
    assert result.markdown =~ "_My Persona_"
  end
end
