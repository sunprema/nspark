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

  defp snap(nodes, extra \\ %{}), do: Map.merge(%{"nodes" => nodes}, extra)

  describe "diff/2 classification" do
    test "a new required variable is breaking" do
      old = snap([snode(id: "a", content: "Hi {name}")])
      new = snap([snode(id: "a", content: "Hi {name} from {company}")])

      d = VersionDiff.diff(old, new)
      assert d["level"] == :breaking
      assert d["variables"]["added"] == ["company"]
      assert d["variables"]["renamed"] == []
      assert "requires new variable {company}" in d["reasons"]
    end

    test "a variable rename (same referencing node) is breaking and reported as a rename" do
      old = snap([snode(id: "a", content: "Hi {name}")])
      new = snap([snode(id: "a", content: "Hi {customer}")])

      d = VersionDiff.diff(old, new)
      assert d["level"] == :breaking
      assert d["variables"]["renamed"] == [%{"from" => "name", "to" => "customer"}]
      # paired as a rename, so neither side lists it as a bare add/remove
      assert d["variables"]["added"] == []
      assert d["variables"]["removed"] == []
      assert "variable renamed {name} → {customer}" in d["reasons"]
    end

    test "dropping an agent output is breaking" do
      old = snap([snode(id: "a", type: "agent", metadata: %{"output_var" => "result"})])
      new = snap([snode(id: "a", type: "agent", metadata: %{"output_var" => ""})])

      d = VersionDiff.diff(old, new)
      assert d["level"] == :breaking
      assert d["outputs"]["removed"] == ["result"]
      assert "removed output `result`" in d["reasons"]
    end

    test "removing a variable is compatible" do
      old = snap([snode(id: "a", content: "{keep} and {drop}")])
      new = snap([snode(id: "a", content: "{keep}")])

      d = VersionDiff.diff(old, new)
      assert d["level"] == :compatible
      assert d["variables"]["removed"] == ["drop"]
      assert d["variables"]["renamed"] == []
    end

    test "a provider change is compatible" do
      old = snap([snode(id: "a", content: "hi")], %{"provider" => "anthropic"})
      new = snap([snode(id: "a", content: "hi")], %{"provider" => "openai"})

      d = VersionDiff.diff(old, new)
      assert d["level"] == :compatible
      assert d["provider"] == %{"from" => "anthropic", "to" => "openai"}
      assert "provider changed anthropic → openai" in d["reasons"]
    end

    test "a content-only edit is cosmetic with a line-level diff payload" do
      old = snap([snode(id: "a", content: "line one\nline two")])
      new = snap([snode(id: "a", content: "line one\nline two changed")])

      d = VersionDiff.diff(old, new)
      assert d["level"] == :cosmetic
      assert [%{"id" => "a", "change" => :content, "diff" => diff}] = d["nodes"]
      assert diff["added_lines"] == ["line two changed"]
      assert diff["removed_lines"] == ["line two"]
    end

    test "adding a node with no contract delta is cosmetic" do
      old = snap([snode(id: "a", content: "static")])
      new = snap([snode(id: "a", content: "static"), snode(id: "b", content: "also static")])

      d = VersionDiff.diff(old, new)
      assert d["level"] == :cosmetic
      assert [%{"id" => "b", "change" => :added}] = d["nodes"]
    end

    test "retyping a node is reported and stays cosmetic" do
      old = snap([snode(id: "a", type: "persona", content: "x")])
      new = snap([snode(id: "a", type: "context", content: "x")])

      d = VersionDiff.diff(old, new)
      assert d["level"] == :cosmetic
      assert [%{"change" => :retyped, "from" => "persona", "to" => "context"}] = d["nodes"]
    end

    test "level is the max severity across deltas (breaking dominates compatible)" do
      old = snap([snode(id: "a", content: "{x}")], %{"provider" => "anthropic"})
      new = snap([snode(id: "a", content: "{x} {y}")], %{"provider" => "openai"})

      d = VersionDiff.diff(old, new)
      assert d["level"] == :breaking
      assert d["variables"]["added"] == ["y"]
      assert d["provider"] == %{"from" => "anthropic", "to" => "openai"}
    end

    test "identical snapshots are cosmetic with empty deltas" do
      snapshot =
        snap([snode(id: "a", content: "{x}", type: "agent", metadata: %{"output_var" => "r"})])

      d = VersionDiff.diff(snapshot, snapshot)
      assert d["level"] == :cosmetic
      assert d["variables"] == %{"added" => [], "removed" => [], "renamed" => []}
      assert d["outputs"] == %{"added" => [], "removed" => []}
      assert d["provider"] == nil
      assert d["nodes"] == []
      assert d["reasons"] == []
    end

    test "removing a node that held a variable is compatible (contract delta wins)" do
      old = snap([snode(id: "a", content: "{x}"), snode(id: "b", content: "{y}")])
      new = snap([snode(id: "a", content: "{x}")])

      d = VersionDiff.diff(old, new)
      assert d["level"] == :compatible
      assert d["variables"]["removed"] == ["y"]
      assert [%{"id" => "b", "change" => :removed}] = d["nodes"]
    end
  end
end
