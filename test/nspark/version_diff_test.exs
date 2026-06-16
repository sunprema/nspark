defmodule Nspark.VersionDiffTest do
  use ExUnit.Case, async: true

  alias Nspark.VersionDiff

  # String-keyed snapshot node, matching `Architecture.serialize_snapshot/2`.
  defp snode(attrs) do
    %{
      "id" => "n",
      "type" => "persona",
      "label" => "Node",
      "content" => nil,
      "metadata" => %{}
    }
    |> Map.merge(Map.new(attrs, fn {k, v} -> {to_string(k), v} end))
  end

  describe "variables_in/1" do
    test "extracts single-brace variable names in order, with duplicates" do
      assert VersionDiff.variables_in("Hi {name}, your id is {name} ({account_id})") ==
               ["name", "name", "account_id"]
    end

    test "ignores non-matching braces and non-binary input" do
      assert VersionDiff.variables_in("no vars here") == []
      assert VersionDiff.variables_in("{ spaced }") == []
      assert VersionDiff.variables_in(nil) == []
      assert VersionDiff.variables_in(123) == []
    end
  end

  describe "contract/1 variables" do
    test "collects required variables across nodes with the referencing node ids" do
      snapshot = %{
        "nodes" => [
          snode(id: "a", type: "persona", content: "You are {role}. Greet {customer_name}."),
          snode(id: "b", type: "context", content: "Account: {customer_name}")
        ]
      }

      assert %{"variables" => vars} = VersionDiff.contract(snapshot)

      assert vars["role"] == %{"required" => true, "refs" => ["a"]}
      assert vars["customer_name"] == %{"required" => true, "refs" => ["a", "b"]}
      assert map_size(vars) == 2
    end

    test "deduplicates repeated references from the same node" do
      snapshot = %{"nodes" => [snode(id: "a", content: "{x} and {x} again")]}
      assert %{"variables" => %{"x" => %{"refs" => ["a"]}}} = VersionDiff.contract(snapshot)
    end

    test "nodes without content contribute no variables" do
      snapshot = %{"nodes" => [snode(id: "a", content: nil), snode(id: "b", content: "")]}
      assert %{"variables" => vars} = VersionDiff.contract(snapshot)
      assert vars == %{}
    end
  end

  describe "contract/1 outputs" do
    test "collects agent output_vars and ignores blanks/non-agents" do
      snapshot = %{
        "nodes" => [
          snode(id: "a", type: "agent", metadata: %{"output_var" => "risk_score"}),
          snode(id: "b", type: "agent", metadata: %{"output_var" => "result"}),
          snode(id: "c", type: "agent", metadata: %{"output_var" => ""}),
          snode(id: "d", type: "agent", metadata: %{}),
          snode(id: "e", type: "persona", content: "{ignored}")
        ]
      }

      assert %{"outputs" => outputs} = VersionDiff.contract(snapshot)
      assert Enum.sort(outputs) == ["result", "risk_score"]
    end

    test "deduplicates identical output vars" do
      snapshot = %{
        "nodes" => [
          snode(id: "a", type: "agent", metadata: %{"output_var" => "result"}),
          snode(id: "b", type: "agent", metadata: %{"output_var" => "result"})
        ]
      }

      assert %{"outputs" => ["result"]} = VersionDiff.contract(snapshot)
    end
  end

  describe "contract/1 provider and shape" do
    test "echoes a pinned provider, otherwise nil" do
      assert %{"provider" => "anthropic"} =
               VersionDiff.contract(%{"provider" => "anthropic", "nodes" => []})

      assert %{"provider" => nil} = VersionDiff.contract(%{"nodes" => []})
    end

    test "accepts a bare list of nodes" do
      assert %{"variables" => %{"y" => _}} =
               VersionDiff.contract([snode(id: "a", content: "{y}")])
    end

    test "empty snapshot yields an empty contract" do
      assert VersionDiff.contract(%{"nodes" => []}) ==
               %{"variables" => %{}, "outputs" => [], "provider" => nil}
    end
  end
end
