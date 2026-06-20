defmodule Nspark.PromptBasic.IR do
  @moduledoc """
  The one normalized object that PromptBasic is drawn, linted, tested, and exported as.

  The IR is the canonical form a program takes once parsed (from bracket text) or compiled
  (from a graph). `Nspark.PromptBasic.Analyzer` (static lens) and `Nspark.PromptBasic.Selector`
  (deterministic execution) both operate on it. Because the struct's field names mirror the
  parser's parse tree (`rules`, `decl_mem`, `decl_tools`, `init_state`), an `%IR{}` is a drop-in
  wherever the raw parse map was used.

  See `docs/pivot/JSON_IR.md` for the interchange spec and `docs/pivot/BUILD_PLAN.md` Phase 1.

  ## Producers

    * `from_text/1` — bracket PromptBasic source → IR (Producer A; via the Parser)
    * `from_program/1` — wrap a raw parse map → IR

  ## Persistence

  `to_json/1` / `from_json/1` round-trip the IR through a string-keyed, JSON-safe map suitable
  for storage on a `GraphVersion` snapshot. The IR is a *compiled artifact*: it is fully
  recomputable from its source, so persisting it is a cache, not a new source of truth.
  """

  alias Nspark.PromptBasic.Parser

  @ir_version "1.0"

  defstruct name: nil,
            version: @ir_version,
            init_state: nil,
            decl_mem: %{},
            decl_tools: [],
            rules: []

  @type t :: %__MODULE__{
          name: String.t() | nil,
          version: String.t(),
          init_state: String.t() | nil,
          decl_mem: %{optional(String.t()) => String.t()},
          decl_tools: [map()],
          rules: [map()]
        }

  @doc "Compile bracket PromptBasic source text into an IR (Producer A)."
  @spec from_text(String.t(), keyword()) :: t()
  def from_text(source, opts \\ []) do
    source |> Parser.parse() |> from_program(opts)
  end

  @doc "Wrap a raw parse map (`%{rules, decl_mem, decl_tools, init_state}`) into an IR."
  @spec from_program(map(), keyword()) :: t()
  def from_program(program, opts \\ []) do
    %__MODULE__{
      name: Keyword.get(opts, :name, program[:name]),
      version: Keyword.get(opts, :version, @ir_version),
      init_state: program[:init_state],
      decl_mem: program[:decl_mem] || %{},
      decl_tools: program[:decl_tools] || [],
      rules: program[:rules] || []
    }
  end

  # ── mode-aware rendering ─────────────────────────────────────────────────────

  @doc """
  The distinct states referenced by a program: the declared `init_state`, every
  `[WHEN] state = X` guard, and every `[STATE] X` transition. Sorted, init first.
  """
  @spec states(t()) :: [String.t()]
  def states(%__MODULE__{} = ir) do
    guards =
      ir.rules
      |> Enum.flat_map(& &1.atoms)
      |> Enum.filter(&(&1.key == "state"))
      |> Enum.map(& &1.value)

    writes = Enum.flat_map(ir.rules, & &1.state_writes)

    others =
      ([ir.init_state] ++ guards ++ writes)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> List.delete(ir.init_state)
      |> Enum.sort()

    case ir.init_state do
      nil -> others
      init -> [init | others]
    end
  end

  @doc """
  Which way the canvas should render this program (memo §4):

    * `:flat` — 0 or 1 states → a priority ladder (decision table); skip state ceremony.
    * `:stateful` — more than one state → a state machine + per-state stacks.
  """
  @spec mode(t()) :: :flat | :stateful
  def mode(%__MODULE__{} = ir) do
    if length(states(ir)) > 1, do: :stateful, else: :flat
  end

  # ── JSON round-trip ─────────────────────────────────────────────────────────

  @doc """
  Serialize an IR to a JSON-safe, string-keyed map.

  Native Elixir shapes that JSON cannot represent are normalized here:
  atom enums (`when_op`, `kind`, `terminal`, ref `kind`) become strings, the
  `:otherwise` priority becomes `"otherwise"`, and `mem_writes` tuples become
  `%{"key", "value"}` maps. `from_json/1` is the exact inverse.
  """
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = ir) do
    %{
      "name" => ir.name,
      "version" => ir.version,
      "init_state" => ir.init_state,
      "memory" => ir.decl_mem,
      "tools" => Enum.map(ir.decl_tools, &tool_decl_to_json/1),
      "rules" => Enum.map(ir.rules, &rule_to_json/1)
    }
  end

  @doc "Inverse of `to_json/1`. Restores a JSON map (string keys) back to an `%IR{}`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      name: json["name"],
      version: json["version"] || @ir_version,
      init_state: json["init_state"],
      decl_mem: json["memory"] || %{},
      decl_tools: Enum.map(json["tools"] || [], &tool_decl_from_json/1),
      rules: Enum.map(json["rules"] || [], &rule_from_json/1)
    }
  end

  # ── rule ↔ json ─────────────────────────────────────────────────────────────

  defp rule_to_json(r) do
    %{
      "id" => r.id,
      "section" => r.section,
      "priority" => priority_to_json(r.priority),
      "when_op" => to_string(r.when_op),
      "atoms" => Enum.map(r.atoms, &atom_to_json/1),
      "tools" => Enum.map(r.tools, &tool_inv_to_json/1),
      "mem_writes" => Enum.map(r.mem_writes, fn {k, v} -> %{"key" => k, "value" => v} end),
      "state_writes" => r.state_writes,
      "refs" => Enum.map(r.refs, &ref_to_json/1),
      "has_stop" => r.has_stop,
      "terminal" => terminal_to_json(r.terminal)
    }
  end

  defp rule_from_json(j) do
    %{
      id: j["id"],
      section: j["section"],
      priority: priority_from_json(j["priority"]),
      when_op: String.to_existing_atom(j["when_op"] || "none"),
      atoms: Enum.map(j["atoms"] || [], &atom_from_json/1),
      tools: Enum.map(j["tools"] || [], &tool_inv_from_json/1),
      mem_writes: Enum.map(j["mem_writes"] || [], fn m -> {m["key"], m["value"]} end),
      state_writes: j["state_writes"] || [],
      refs: Enum.map(j["refs"] || [], &ref_from_json/1),
      has_stop: j["has_stop"] || false,
      terminal: terminal_from_json(j["terminal"])
    }
  end

  defp atom_to_json(a) do
    %{
      "raw" => a[:raw],
      "key" => a[:key],
      "op" => a[:op],
      "value" => a[:value],
      "kind" => to_string(a[:kind]),
      "literal" => a[:literal] || false
    }
  end

  defp atom_from_json(j) do
    %{
      raw: j["raw"],
      key: j["key"],
      op: j["op"],
      value: j["value"],
      kind: String.to_existing_atom(j["kind"] || "semantic"),
      literal: j["literal"] || false
    }
  end

  defp tool_decl_to_json(%{name: name, out: out}), do: %{"name" => name, "out" => out}
  defp tool_decl_from_json(j), do: %{name: j["name"], out: j["out"]}

  defp tool_inv_to_json(t),
    do: %{"name" => t.name, "args" => Map.get(t, :args, ""), "out" => Map.get(t, :out)}

  defp tool_inv_from_json(j), do: %{name: j["name"], args: j["args"] || "", out: j["out"]}

  defp ref_to_json(r), do: %{"kind" => to_string(r.kind), "var" => r.var}
  defp ref_from_json(j), do: %{kind: String.to_existing_atom(j["kind"]), var: j["var"]}

  defp priority_to_json(:otherwise), do: "otherwise"
  defp priority_to_json(n), do: n
  defp priority_from_json("otherwise"), do: :otherwise
  defp priority_from_json(n) when is_integer(n), do: n

  defp terminal_to_json(nil), do: nil
  defp terminal_to_json(t), do: to_string(t)
  defp terminal_from_json(nil), do: nil
  defp terminal_from_json(t), do: String.to_existing_atom(t)
end
