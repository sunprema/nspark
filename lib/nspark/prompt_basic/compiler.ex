defmodule Nspark.PromptBasic.Compiler do
  @moduledoc """
  Producer B: compile a graph's control-layer nodes into a PromptBasic `IR`.

  The graph is the source of truth (decision #1); the IR is a derived artifact. Rather than
  duplicate the parser's logic, the compiler **assembles a canonical bracket program from the
  graph and parses it through `Nspark.PromptBasic.Parser`** — so "graph → IR" provably yields
  the same IR shape as "text → IR", and `to_source/3` doubles as the Phase 5 exporter.

  ## How the canvas maps to PromptBasic (memo §3)

    * `state` node — declares a state. `metadata["initial"]` (truthy) marks the init state.
    * `memory` node — a `[MEMORY] <label> = <default>` declaration (`metadata["default"]`,
      falling back to `content`, falling back to `null`).
    * `tool` node — a `[TOOL] <label> -> <output>` declaration (`metadata["output"]`); `content`
      becomes the description line.
    * `rule` node — a `[WHEN] → actions` card. The card's **structure** comes from the graph:
      priority is `metadata["priority"]` (vertical stack order), `metadata["otherwise"]` makes it
      the `[OTHERWISE]` fallback, `metadata["section"]` groups it under a `#` heading, and
      `metadata["order"]` fixes document order (which sets the R-ids and tie resolution). The
      card's `content` holds the inspectable bracket body (`[WHEN]`, `[TOOL]`, `[MEMORY]`,
      `[STATE]`, `[RESPOND]`/`[ASK]`, `[STOP]`) — without the `[PRIORITY]` line.

  A rule's owning state and its transitions live in its `content` (the `[WHEN] state = X` guard
  and `[STATE] Y` writes) — one source of truth. The canvas draws containment/transition edges
  *from* those, so dragging an edge edits the rule body rather than a second representation.

  Muted nodes are excluded (parity with `Nspark.Compiler`).
  """

  alias Nspark.PromptBasic.IR

  @doc "Compile graph nodes (+ edges, reserved) into an `%IR{}`."
  @spec from_graph([map()], [map()], keyword()) :: IR.t()
  def from_graph(nodes, edges \\ [], opts \\ []) do
    nodes |> to_source(edges, opts) |> IR.from_text(opts)
  end

  @doc """
  The graph's rule nodes in the exact order the compiler emits them — i.e. the order
  whose indices line up 1:1 with the IR's `R1..Rn` rule ids. Lets callers map an IR
  rule back to the graph node that produced it (used by `Nspark.PromptBasic.Lens`).
  """
  @spec ordered_rule_nodes([map()]) :: [map()]
  def ordered_rule_nodes(nodes) do
    nodes
    |> Enum.reject(&muted?/1)
    |> Enum.filter(&(type(&1) == :rule))
    |> sort_rules()
  end

  @doc """
  Map each IR rule id (`R1..Rn`) to the graph node id that produced it, by aligning the
  compiler's rule-emit order with the parsed rule ids. Used to attribute lens findings and
  derived transition/containment edges back to specific graph nodes.
  """
  @spec rule_id_to_node_id([map()]) :: %{String.t() => String.t()}
  def rule_id_to_node_id(nodes) do
    ir = from_graph(nodes)

    nodes
    |> ordered_rule_nodes()
    |> Enum.zip(ir.rules)
    |> Map.new(fn {node, rule} -> {rule.id, id(node)} end)
  end

  @doc "Assemble graph nodes into canonical bracket PromptBasic source (also the exporter)."
  @spec to_source([map()], [map()], keyword()) :: String.t()
  def to_source(nodes, _edges \\ [], opts \\ []) do
    active = Enum.reject(nodes, &muted?/1)
    name = opts[:name] || "PROGRAM"

    states = Enum.filter(active, &(type(&1) == :state))
    mems = Enum.filter(active, &(type(&1) == :memory))
    tools = Enum.filter(active, &(type(&1) == :tool))
    rules = ordered_rule_nodes(active)

    [
      "[PROMPTBASIC #{name}]",
      setup_block(states, mems, tools),
      rules_block(rules)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  # ── setup (init state, memory, tools) ────────────────────────────────────────

  defp setup_block(states, mems, tools) do
    init = init_state(states)

    [
      if(init, do: "[STATE] #{init}", else: nil),
      mems |> Enum.map_join("\n", &memory_decl/1) |> nilify(),
      tools |> Enum.map_join("\n\n", &tool_decl/1) |> nilify()
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp init_state(states) do
    initial = Enum.find(states, &truthy(meta(&1)["initial"]))
    (initial || List.first(states)) |> case do
      nil -> nil
      node -> label(node)
    end
  end

  defp memory_decl(node), do: "[MEMORY] #{label(node)} = #{memory_default(node)}"

  defp memory_default(node) do
    meta(node)["default"] || presence(content(node)) || "null"
  end

  defp tool_decl(node) do
    out = meta(node)["output"] || "#{label(node)}_result"
    decl = "[TOOL] #{label(node)} -> #{out}"

    case presence(content(node)) do
      nil -> decl
      desc -> decl <> "\n" <> desc
    end
  end

  # ── rules ────────────────────────────────────────────────────────────────────

  defp rules_block([]), do: ""

  defp rules_block(rules) do
    {blocks, _section} =
      Enum.map_reduce(rules, :__none__, fn rule, prev_section ->
        section = presence(meta(rule)["section"])
        heading = if section && section != prev_section, do: "# #{section}\n", else: ""
        {heading <> rule_block(rule), section || prev_section}
      end)

    Enum.join(blocks, "\n\n")
  end

  defp rule_block(rule) do
    head =
      if truthy(meta(rule)["otherwise"]) do
        "[OTHERWISE]"
      else
        "[PRIORITY] #{meta(rule)["priority"] || 0}"
      end

    body = rule |> content() |> to_string() |> String.trim()
    if body == "", do: head, else: head <> "\n" <> body
  end

  # Otherwise-rules sink to the bottom; explicit `order` drives document order
  # (and therefore R-ids + tie resolution); input order is the stable fallback.
  defp sort_rules(rules) do
    rules
    |> Enum.with_index()
    |> Enum.sort_by(fn {r, i} ->
      {if(truthy(meta(r)["otherwise"]), do: 1, else: 0), meta(r)["order"] || i, i}
    end)
    |> Enum.map(&elem(&1, 0))
  end

  # ── field accessors (Ash structs and string-keyed snapshot maps) ─────────────

  defp type(%{type: t}), do: normalize_type(t)
  defp type(%{"type" => t}), do: normalize_type(t)
  defp type(_), do: nil

  defp normalize_type(t) when is_atom(t), do: t
  defp normalize_type(t) when is_binary(t), do: String.to_existing_atom(t)

  defp id(%{id: i}), do: i
  defp id(%{"id" => i}), do: i
  defp id(_), do: nil

  defp label(%{label: l}), do: l
  defp label(%{"label" => l}), do: l
  defp label(_), do: nil

  defp content(%{content: c}), do: c
  defp content(%{"content" => c}), do: c
  defp content(_), do: nil

  defp meta(%{metadata: m}) when is_map(m), do: m
  defp meta(%{"metadata" => m}) when is_map(m), do: m
  defp meta(_), do: %{}

  defp muted?(%{is_muted: m}), do: m == true
  defp muted?(%{"is_muted" => m}), do: m == true
  defp muted?(_), do: false

  defp truthy(true), do: true
  defp truthy("true"), do: true
  defp truthy(_), do: false

  defp presence(nil), do: nil
  defp presence(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: String.trim(s))
  defp presence(_), do: nil

  defp nilify(""), do: nil
  defp nilify(s), do: s
end
