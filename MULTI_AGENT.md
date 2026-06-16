# Multi-Agent Composition

## What It Is

A graph can reference another deployed graph as a sub-agent. The parent agent orchestrates the call, injects the sub-agent's output as a variable, and continues reasoning with it.

This is how "agents from other agents" works in Newtonian Spark: composition is a first-class graph primitive, not a runtime hack.

---

## Core Concepts

### Orchestrator Graph

A graph that contains one or more Agent nodes. Compiles into a prompt that receives sub-agent outputs as pre-populated variables before the LLM is called.

### Sub-agent Graph

Any existing graph with an Output node defining its response schema. No special configuration needed — any deployed graph is a potential sub-agent.

### Agent Node

A new node type (`:agent`) on the canvas. References a deployed graph by ID. Declares:
- Which parent graph variables to pass as inputs
- What variable name to inject the sub-agent's output under

### Pre-call Orchestration

Sub-agent calls happen **before** the parent LLM call, not during it. The platform collects all sub-agent outputs, resolves all `{variable}` placeholders, then invokes the parent LLM with a fully populated prompt. The parent LLM never makes API calls itself — it reasons over pre-fetched results.

```
User request
     │
     ▼
Platform runtime
     │
     ├─ Resolve static variables
     │
     ├─ Dispatch sub-agent calls (parallel where possible)
     │   ├─ Sub-agent A → {result_a}
     │   └─ Sub-agent B → {result_b}
     │
     ▼
Parent prompt assembled with all variables populated
     │
     ▼
Parent LLM call → final response
```

---

## Composition Patterns

### 1. Sequential Pipeline

Each agent's output feeds the next.

```
[Input] → [Research Agent] → {research_result} → [Writer Agent] → [Output]
```

### 2. Conditional Dispatch

A diamond node routes to different sub-agents based on context.

```
                  ◇ Connectivity Error? ◇
                 /                         \
               no                          yes
              /                              \
  [Inventory Agent]                   [Cached Inventory Agent]
  {inventory_result}                  {inventory_result}
```

Both branches output to the same variable name, so the parent graph downstream is identical regardless of which path ran.

### 3. Parallel Fan-Out

Multiple Agent nodes at the same graph depth run in parallel. Their outputs merge into the next stage.

```
          [Orchestrator]
         /               \
[Research Agent]    [Compliance Agent]
{research}          {compliance_check}
         \               /
          [Synthesis Agent]
```

### 4. Hierarchical

An orchestrator graph whose sub-agents are themselves orchestrators. Depth limit enforced at compile time to prevent cycles.

---

## Data Model Changes

### New Node Type

Add `:agent` to `Nspark.Architecture.NodeType` enum.

```elixir
use Ash.Type.Enum, values: [
  :persona, :constraint, :context, :conditional,
  :skill, :memory, :tool, :evaluation, :output,
  :agent   # ← new
]
```

### Agent Node Metadata Contract

The `:agent` node stores its wiring in `metadata` (no schema change required for MVP):

```json
{
  "source_graph_id": "uuid-of-referenced-graph",
  "source_deployment_id": "uuid-of-pinned-deployment",
  "output_var": "research_result",
  "input_mapping": {
    "query": "user_query",
    "context": "session_context"
  },
  "timeout_ms": 10000,
  "on_error": "continue"
}
```

| Field | Purpose |
|---|---|
| `source_graph_id` | Design-time reference — which graph this Agent node calls |
| `source_deployment_id` | Deploy-time pin — which deployment version to call (resolved at deploy time if null) |
| `output_var` | Variable name injected into parent graph: `{research_result}` |
| `input_mapping` | Maps sub-agent input variable names → parent graph variable names |
| `timeout_ms` | Per-call timeout; orchestrator fails fast if exceeded |
| `on_error` | `"continue"` (inject empty/null and proceed) or `"fail"` (abort orchestration) |

The `on_error: "continue"` field is exactly the "if connectivity error: continue, else: ignore" pattern — a node-level fault tolerance policy stored in metadata.

### Future: Proper FK

Once the pattern is validated, migrate `source_graph_id` and `source_deployment_id` from metadata to proper nullable columns on `Node` with DB-level foreign keys.

---

## Studio Changes

### Agent Node on the Canvas

Visual design: rounded rectangle with an embedded graph preview badge — distinct from blueprint nodes but not diamond-shaped (diamonds are for conditionals only).

```
┌────────────────────────────────┐
│  ⬡ AGENT                       │
│  Research Agent          v2.1  │
│  ──────────────────────────    │
│  in:  {user_query}             │
│  out: {research_result}        │
└────────────────────────────────┘
```

- Top handle: target (receives edges from parent nodes)
- Bottom handle: source (emits `{output_var}` to downstream nodes)
- Badge shows sub-agent name + pinned version
- Environment indicator (dev / staging / prod)

### Palette Entry

Add "Agent" to the left-rail node palette. Dragging it onto the canvas opens a graph picker modal — browse deployed graphs within the org.

### Node Inspector Panel (right rail)

When an Agent node is selected:
- **Sub-agent**: dropdown to select/change the referenced graph
- **Version**: pin to a specific deployment or track latest
- **Output variable**: editable — becomes `{name}` in downstream nodes
- **Input mapping**: table of sub-agent input → parent variable
- **On error**: `continue` / `fail` toggle
- **Contract preview**: shows the sub-agent's declared inputs (its Context nodes) and output schema (its Output node) — read-only, fetched from the referenced graph

### Variable System

The Agent node's `output_var` is treated as a **produced** variable in the diagnostics:
- Downstream nodes that reference `{research_result}` will resolve cleanly
- If the sub-agent's Output schema is known, type checking is possible in a future pass
- The variable explorer highlights the Agent node as the producer

### Cross-Graph Visualization

Clicking the sub-agent badge in the inspector opens the referenced graph in a side panel (read-only), showing what the sub-agent does. This replaces having to navigate away to understand the dependency.

---

## Compiler Changes

### Phase 2 — Dependency Resolution

For each `:agent` node, fetch the referenced graph's Output node schema. Store it in the compiler context as a known variable type.

### Phase 3 — Variable Analysis

Agent node `output_var` is registered as a produced variable. Sub-agent input mappings are validated — referenced parent variables must exist and be defined upstream.

### Phase 4 — Topological Sort

Agent nodes participate in the sort like any other node. Their `output_var` is treated as a dependency for downstream nodes.

### Phase 5 — Assembly

Agent nodes compile to an **orchestration directive** rather than prompt text:

```
[AGENT: research_result]
call: Research Agent (deployment: abc-123)
inputs:
  query: {user_query}
  context: {session_context}
output: {research_result}
on_error: continue
[/AGENT]
```

The runtime interprets these directives. The parent LLM never sees them — they are stripped after orchestration and replaced with the actual sub-agent output.

### New Validation Rules

- **Cycle detection**: Agent node → sub-graph → another Agent node pointing back = compile error
- **Missing sub-agent**: Referenced graph has no active deployment = compile warning
- **Unmapped inputs**: Sub-agent expects a variable the parent graph doesn't produce = compile warning
- **Depth limit**: Max orchestration depth of 3 (configurable) to prevent runaway chains

---

## Runtime Changes

### Orchestration Engine

New module: `Nspark.Orchestrator`

Responsibilities:
1. Parse compiled artifact for `[AGENT: ...]` directives
2. Resolve input variables from current runtime context
3. Dispatch sub-agent calls (parallel where the graph allows)
4. Collect outputs; inject into variable context
5. Handle errors per `on_error` policy
6. Assemble final resolved prompt
7. Call parent LLM

```elixir
defmodule Nspark.Orchestrator do
  def run(compiled_artifact, variables, opts) do
    {directives, prompt_template} = parse(compiled_artifact)

    sub_results =
      directives
      |> resolve_inputs(variables)
      |> dispatch_parallel()
      |> collect(opts[:timeout])

    variables_merged = Map.merge(variables, sub_results)

    resolved_prompt = render(prompt_template, variables_merged)

    {:ok, resolved_prompt}
  end
end
```

### Deployment Execute Endpoint

Existing endpoint extended:

```
POST /api/v1/deployments/:deployment_id/run
{
  "variables": {
    "user_query": "What is in stock?",
    "session_context": {}
  }
}
```

Response adds orchestration metadata:

```json
{
  "prompt": "...",
  "sub_agent_calls": [
    {
      "node": "research_result",
      "deployment_id": "...",
      "duration_ms": 320,
      "status": "ok"
    }
  ]
}
```

### Error Handling

Per `on_error` policy on the Agent node:

| Policy | Behaviour |
|---|---|
| `"continue"` | Inject `nil` / empty string for `{output_var}`; add warning to response metadata |
| `"fail"` | Abort orchestration; return error to caller |

The "if connectivity error: continue, else: ignore" pattern maps directly to `on_error: "continue"` on the Agent node.

---

## Implementation Phases

### Phase 1 — Foundation (MVP)

- [ ] Add `:agent` to `NodeType` enum + migration
- [ ] Agent node metadata contract (JSON schema documented)
- [ ] `AgentNode.svelte` canvas component
- [ ] Graph picker modal in studio
- [ ] Node inspector: sub-agent reference + output variable + on_error
- [ ] Compiler: parse agent directives, variable analysis, cycle detection
- [ ] `Nspark.Orchestrator` — sequential only, single depth
- [ ] Deploy endpoint: orchestration pass before LLM call
- [ ] Demo: Research Agent → Writer Agent pipeline

### Phase 2 — Parallel + Conditional

- [ ] Parallel dispatch in orchestrator (async Task.await_many)
- [ ] Conditional node routing to Agent nodes
- [ ] Studio: visualize parallel fan-out
- [ ] Timeout configuration per Agent node
- [ ] Orchestration metadata in API response

### Phase 3 — Depth + Observability

- [ ] Hierarchical orchestration (depth > 1)
- [ ] Depth limit enforcement at compile time
- [ ] Execution trace: per-call logs surfaced in AgentOps
- [ ] Sub-agent output type checking against Output schema
- [ ] Cross-graph variable inspector in studio

---

## Open Questions

1. **Environment resolution**: When a graph has Agent nodes, which deployment of the sub-agent does the orchestrator call? Track-latest vs explicit pin? Recommendation: default to same environment as parent (dev calls dev, prod calls prod), with an explicit override available.

2. **Streaming**: Should sub-agent calls stream their responses back, or collect fully before injecting? For MVP, collect fully. Streaming sub-agent responses into a parent prompt assembly is a complex UX problem.

3. **Auth between agents**: Sub-agent endpoints require auth. Should agent-to-agent calls use a service token scoped to the org, or the initiating user's session? Recommendation: org-level service token issued at deploy time, rotatable.

4. **Cross-org composition**: Can an agent reference a graph from another org (marketplace)? Out of scope for Phase 1. Requires a trust model for cross-org calls.

5. **Cost attribution**: Sub-agent LLM calls incur cost. How is this surfaced? Per-call cost tracking in the orchestration trace, rolled up to the parent deployment's usage.
