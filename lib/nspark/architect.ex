defmodule Nspark.Architect do
  @moduledoc """
  NL → Graph import pipeline powered by Claude claude-opus-4-8.

  Accepts a raw prompt/description and returns a structured list of nodes
  and edges that can be applied to a graph via `apply_to_graph/5`.
  """

  @anthropic_url "https://api.anthropic.com/v1/messages"
  @model "claude-opus-4-8"

  @doc """
  Parse a raw prompt into a graph structure `{:ok, %{nodes: [...], edges: [...]}}`.
  """
  def from_prompt(text) when is_binary(text) and text != "" do
    api_key = Application.get_env(:nspark, :anthropic_api_key, "")

    if api_key == "" do
      {:error, "ANTHROPIC_API_KEY is not configured."}
    else
      call_api(text, api_key)
    end
  end

  def from_prompt(_), do: {:error, "Prompt cannot be empty."}

  @doc """
  Apply architect result (from `from_prompt/1`) to a graph, creating nodes and
  edges. Returns `{:ok, %{nodes: [Node.t()], edges: [Edge.t()]}}`.
  """
  def apply_to_graph(%{"nodes" => raw_nodes, "edges" => raw_edges}, graph, actor, tenant) do
    opts = [tenant: tenant, actor: actor]

    Nspark.Repo.transaction(fn ->
      # Place nodes in a simple grid: 3 columns, 220px spacing.
      id_map =
        raw_nodes
        |> Enum.with_index()
        |> Enum.reduce(%{}, fn {n, idx}, acc ->
          col = rem(idx, 3)
          row = div(idx, 3)

          node =
            Ash.create!(
              Nspark.Architecture.Node,
              %{
                type: safe_node_type(n["type"]),
                label: n["label"] || "Node",
                content: n["content"],
                is_muted: false,
                graph_id: graph.id,
                metadata: %{"position" => %{"x" => col * 320 + 60, "y" => row * 200 + 60}}
              },
              opts
            )

          Map.put(acc, n["temp_id"] || to_string(idx), node.id)
        end)

      edges =
        Enum.flat_map(raw_edges, fn e ->
          src = Map.get(id_map, e["source"])
          tgt = Map.get(id_map, e["target"])

          if src && tgt do
            edge_type = safe_edge_type(e["edge_type"])

            edge =
              Ash.create!(
                Nspark.Architecture.Edge,
                %{graph_id: graph.id, source_node_id: src, target_node_id: tgt, edge_type: edge_type},
                opts
              )

            [edge]
          else
            []
          end
        end)

      nodes = Map.values(id_map)
      %{node_ids: nodes, edge_ids: Enum.map(edges, & &1.id)}
    end)
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  defp call_api(text, api_key) do
    body = %{
      model: @model,
      max_tokens: 4096,
      thinking: %{type: "adaptive"},
      tools: [architect_tool()],
      tool_choice: %{type: "tool", name: "architect_graph"},
      messages: [
        %{role: "user", content: user_message(text)}
      ]
    }

    case Req.post(@anthropic_url,
           json: body,
           headers: [
             {"x-api-key", api_key},
             {"anthropic-version", "2023-06-01"},
             {"content-type", "application/json"}
           ],
           receive_timeout: 60_000
         ) do
      {:ok, %{status: 200, body: %{"content" => content}}} ->
        extract_tool_result(content)

      {:ok, %{status: status, body: body}} ->
        msg = get_in(body, ["error", "message"]) || inspect(body)
        {:error, "API error #{status}: #{msg}"}

      {:error, reason} ->
        {:error, "Network error: #{inspect(reason)}"}
    end
  end

  defp extract_tool_result(content) do
    case Enum.find(content, &(&1["type"] == "tool_use")) do
      %{"input" => input} -> {:ok, input}
      nil -> {:error, "Claude did not return a structured graph. Try a more detailed prompt."}
    end
  end

  defp architect_tool do
    %{
      name: "architect_graph",
      description: "Decompose a prompt into a structured agent graph of typed nodes and dependency edges.",
      input_schema: %{
        type: "object",
        required: ["nodes", "edges"],
        properties: %{
          nodes: %{
            type: "array",
            description: "Graph nodes representing agent components.",
            items: %{
              type: "object",
              required: ["temp_id", "type", "label", "content"],
              properties: %{
                temp_id: %{type: "string", description: "Unique temporary ID used in edge references (e.g. 'n1')."},
                type: %{
                  type: "string",
                  enum: ["persona", "constraint", "context", "conditional", "skill", "memory", "tool", "evaluation", "output"],
                  description: "Node type."
                },
                label: %{type: "string", description: "Short human-readable label (3-6 words)."},
                content: %{type: "string", description: "Full prompt text for this node. Use {variable} for runtime inputs."}
              }
            }
          },
          edges: %{
            type: "array",
            description: "Dependency edges between nodes (source output flows into target).",
            items: %{
              type: "object",
              required: ["source", "target"],
              properties: %{
                source: %{type: "string", description: "temp_id of source node."},
                target: %{type: "string", description: "temp_id of target node."},
                edge_type: %{
                  type: "string",
                  enum: ["dependency", "conditional", "data_flow"],
                  default: "dependency"
                }
              }
            }
          }
        }
      }
    }
  end

  defp user_message(text) do
    """
    You are an AI Architect for Newtonian Spark, a visual platform for designing AI agents as modular graphs.

    Decompose the following prompt into a structured agent graph. Use the `architect_graph` tool to return nodes and edges.

    Node types:
    - **persona** — System role / identity (who the AI is). Usually one node.
    - **constraint** — Operational rules, safety guardrails, what the agent must NOT do.
    - **context** — Runtime context injected at execution time. Use `{variable}` references.
    - **conditional** — Branching logic based on conditions (`{variable} == value`).
    - **skill** — A specific capability or task the agent can perform.
    - **memory** — Working memory or retrieval references.
    - **tool** — External API or tool integration.
    - **evaluation** — Quality check, self-reflection, or output validation step.
    - **output** — Final output format and structure. Usually one node.

    Guidelines:
    - 4-10 nodes for most agents. Don't over-fragment.
    - Always include a `persona` node and an `output` node.
    - Use `{variable_name}` syntax in content for runtime variables.
    - Connect nodes with edges showing which nodes feed into which.
    - Use descriptive `label` values (3-6 words).
    - Keep `content` concise but complete — this becomes the actual prompt section.

    Prompt to architect:
    ---
    #{text}
    ---
    """
  end

  @valid_node_types ~w(persona constraint context conditional skill memory tool evaluation output)a
  defp safe_node_type(t) when is_binary(t) do
    atom = String.to_existing_atom(t)
    if atom in @valid_node_types, do: atom, else: :context
  rescue
    _ -> :context
  end

  @valid_edge_types ~w(dependency conditional data_flow)a
  defp safe_edge_type(nil), do: :dependency

  defp safe_edge_type(t) when is_binary(t) do
    atom = String.to_existing_atom(t)
    if atom in @valid_edge_types, do: atom, else: :dependency
  rescue
    _ -> :dependency
  end
end
