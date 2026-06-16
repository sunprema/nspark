defmodule Nspark.SlugTest do
  use ExUnit.Case, async: true
  doctest Nspark.Slug

  describe "slugify/1" do
    test "collapses separators and trims" do
      assert Nspark.Slug.slugify("  Risk // Review!! ") == "risk-review"
    end

    test "falls back to 'prompt' for empty/garbage/non-binary input" do
      assert Nspark.Slug.slugify("***") == "prompt"
      assert Nspark.Slug.slugify("") == "prompt"
      assert Nspark.Slug.slugify(nil) == "prompt"
    end
  end

  describe "uniquify/2" do
    test "returns the base when it's free" do
      assert Nspark.Slug.uniquify("agent", ["other"]) == "agent"
    end

    test "appends an incrementing suffix past collisions" do
      assert Nspark.Slug.uniquify("agent", ["agent"]) == "agent-2"
      assert Nspark.Slug.uniquify("agent", ["agent", "agent-2", "agent-3"]) == "agent-4"
    end

    test "accepts a MapSet" do
      assert Nspark.Slug.uniquify("agent", MapSet.new(["agent"])) == "agent-2"
    end
  end
end
