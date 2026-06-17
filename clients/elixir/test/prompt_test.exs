defmodule Nspark.PromptTest do
  use ExUnit.Case, async: true

  alias Nspark.Prompt
  alias Nspark.Error.{MissingVariables, UnknownVariables}

  defp make_prompt(text, variables) do
    Prompt.from_payload(%{
      "slug" => "demo",
      "version" => 1,
      "resolved_via" => "version:1",
      "prompt" => text,
      "input_schema" => %{"variables" => variables, "outputs" => [], "provider" => "anthropic"},
      "metadata" => %{},
      "stats" => %{}
    })
  end

  test "render substitutes declared variables" do
    p =
      make_prompt("Hello {name}, task is {task}.", %{
        "name" => %{"required" => true},
        "task" => %{"required" => true}
      })

    assert {:ok, "Hello Ada, task is refund."} =
             Prompt.render(p, %{"name" => "Ada", "task" => "refund"})
  end

  test "render accepts atom-keyed variables" do
    p = make_prompt("Hi {name}", %{"name" => %{"required" => true}})
    assert {:ok, "Hi Ada"} = Prompt.render(p, %{name: "Ada"})
  end

  test "render coerces non-string values" do
    p = make_prompt("Count: {n}", %{"n" => %{"required" => true}})
    assert {:ok, "Count: 42"} = Prompt.render(p, %{"n" => 42})
  end

  test "render returns MissingVariables when a required variable is absent" do
    p =
      make_prompt("Hi {name} re {task}", %{
        "name" => %{"required" => true},
        "task" => %{"required" => true}
      })

    assert {:error, %MissingVariables{missing: ["task"]}} = Prompt.render(p, %{"name" => "Ada"})
  end

  test "strict render rejects unknown variables" do
    p = make_prompt("Hi {name}", %{"name" => %{"required" => true}})

    assert {:error, %UnknownVariables{unknown: ["typo"]}} =
             Prompt.render(p, %{"name" => "Ada", "typo" => "x"})
  end

  test "lenient render ignores unknown variables" do
    p = make_prompt("Hi {name}", %{"name" => %{"required" => true}})
    assert {:ok, "Hi Ada"} = Prompt.render(p, %{"name" => "Ada", "extra" => "x"}, strict: false)
  end

  test "render! raises on a validation error" do
    p = make_prompt("Hi {name}", %{"name" => %{"required" => true}})
    assert_raise MissingVariables, fn -> Prompt.render!(p, %{}) end
  end

  test "required_variables reflects the contract" do
    p = make_prompt("{a}{b}", %{"a" => %{"required" => true}, "b" => %{"required" => true}})
    assert Prompt.required_variables(p) == MapSet.new(["a", "b"])
  end
end
