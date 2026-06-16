defmodule Nspark.Compiler do
  @moduledoc """
  Assembles a graph's nodes into a model-ready prompt (Markdown), in compile
  order. The graph is the source of truth; the compiled prompt is a generated
  artifact (see docs/HLD.md §5).

  v1 scope: group nodes by type in the fixed assembly order and exclude muted
  nodes. Dependency resolution, topological sort within a section, and variable
  validation are future phases.
  """

  # Assembly order (HLD §5 Phase 5), with section headings. `tool` is placed
  # after skills; it is not in the HLD list but belongs with capabilities.
  @order [
    {:persona, "MISSION"},
    {:constraint, "OPERATIONAL RULES"},
    {:context, "CONTEXT"},
    {:skill, "SKILLS"},
    {:tool, "TOOLS"},
    {:memory, "MEMORY"},
    {:conditional, "CONDITIONAL LOGIC"},
    {:evaluation, "EVALUATION"},
    {:output, "OUTPUT FORMAT"}
  ]

  @type result :: %{
          markdown: String.t(),
          token_estimate: non_neg_integer(),
          included: non_neg_integer(),
          excluded: non_neg_integer()
        }

  @doc """
  Compile a list of node structs (anything with `:type`, `:label`, `:content`,
  `:is_muted`) into the assembled prompt plus basic stats.
  """
  @spec compile([map()]) :: result()
  def compile(nodes) when is_list(nodes) do
    active = Enum.reject(nodes, & &1.is_muted)

    markdown =
      for {type, heading} <- @order,
          group = Enum.filter(active, &(&1.type == type)),
          group != [] do
        body = group |> Enum.map_join("\n\n", &node_body/1)
        "# #{heading}\n\n#{body}"
      end
      |> Enum.join("\n\n")
      |> String.trim()

    %{
      markdown: markdown,
      token_estimate: estimate_tokens(markdown),
      included: length(active),
      excluded: length(nodes) - length(active)
    }
  end

  defp node_body(%{content: content} = node) when is_binary(content) do
    case String.trim(content) do
      "" -> "_#{node.label}_"
      trimmed -> trimmed
    end
  end

  defp node_body(node), do: "_#{node.label}_"

  # Rough heuristic until model-specific tokenization lands: ~4 chars/token.
  defp estimate_tokens(text), do: div(String.length(text), 4)
end
