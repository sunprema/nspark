# Newtonian Spark — User Guide

Newtonian Spark is a visual architecture platform for AI agents. Instead of maintaining prompt documents, you build agent behavior as a structured graph of modular components — then compile, version, and deploy it as a callable API.

---

## Table of Contents

1. [Concepts](#concepts)
2. [Getting Access](#getting-access)
3. [The Studio](#the-studio)
4. [Node Types](#node-types)
5. [Building a Graph](#building-a-graph)
6. [Variables](#variables)
7. [Diagnostics](#diagnostics)
8. [The Live Compiler](#the-live-compiler)
9. [Knowledge Registry](#knowledge-registry)
10. [AI Architect](#ai-architect)
11. [Publishing and Versioning](#publishing-and-versioning)
12. [Deploying an Agent](#deploying-an-agent)
13. [Runtime API](#runtime-api)
14. [Multi-Agent Composition](#multi-agent-composition)
15. [Organization and Members](#organization-and-members)

---

## Concepts

| Term | What it is |
|---|---|
| **Graph** | Your agent's architecture — a directed acyclic graph of nodes connected by edges |
| **Node** | A single behavioral component (persona, rule, skill, etc.) |
| **Edge** | A dependency arrow from one node to another; determines compile order |
| **Variable** | A `{named_placeholder}` injected at runtime — written as `{customer_name}` |
| **Compiler** | Assembles the graph into a model-ready prompt in real time |
| **Graph Version** | An immutable snapshot of the graph created when you publish |
| **Deployment** | A published version made callable as an API endpoint |
| **Registry** | Org-wide reusable assets: Skills, Policies, Schemas, Memory Templates |
| **Package** | A bundled collection of registry assets installable onto any graph |

---

## Getting Access

Newtonian Spark uses invite-only onboarding. You will receive an invitation email from an org admin. Click the link in the email to accept and join the organization.

After logging in you land directly in the Studio at `/studio`.

If you belong to multiple organizations, use the org switcher in the top-right corner of the studio header to toggle between them.

---

## The Studio

The studio is a three-column workspace at `/studio`.

```
┌─────────────────┬───────────────────────────┬──────────────────┐
│   Left Rail     │      Canvas               │   Right Panel    │
│                 │                           │                  │
│  Node Library   │   Svelte Flow graph       │   Inspector      │
│  Variables      │                           │   ──────────     │
│  Registry       │                           │   Compiler       │
│  Packages       │                           │   Diagnostics    │
└─────────────────┴───────────────────────────┴──────────────────┘
```

**Header bar** — graph name + version selector, publish/deploy buttons, org switcher, AI Architect button.

**Canvas** — the primary workspace. Pan with mouse drag, zoom with scroll wheel. Press `F` to fit the graph to the viewport.

**Keyboard shortcuts on the canvas:**
- `F` — fit graph to view
- `Backspace` / `Delete` — delete selected nodes or edges
- `M` — mute / unmute selected node
- `Esc` — deselect

---

## Node Types

Each node represents a distinct behavioral concern. The compiler assembles them in a fixed canonical order regardless of how you arrange them on the canvas.

| Type | Color | Purpose | Compile position |
|---|---|---|---|
| **Persona** | Blue | Identity, role, tone — who the agent is | 1st |
| **Constraint** | Red | Rules, guardrails, compliance requirements | 2nd |
| **Context** | Green | Variables and runtime data injection points | 3rd |
| **Skill** | Indigo | Reusable capabilities (planning, retrieval, etc.) | 4th |
| **Memory** | Purple | Long-term or episodic knowledge references | 5th |
| **Conditional** | Gold ◇ | Runtime routing logic — routes to different branches | 6th |
| **Evaluation** | Teal | Self-check and validation rules | 7th |
| **Output** | Violet | Response schema and format requirements | 8th |
| **Agent** | Blue ⬡ | Reference to another deployed graph (sub-agent) | ORCHESTRATION |

### Node states

- **Active** — included in compilation, normal border
- **Muted** — grayed out, excluded from compilation (dashed border)
- **Warning** — amber border, validation issue detected
- **Error** — red border, compilation-blocking issue

---

## Building a Graph

### Create a graph

Click your current graph name in the header → **+ New Graph** → enter a name → **Create**.

### Add nodes

**From the left rail:** Click a node type name in the Node Library section to add it at a stacked position on the canvas.

**By dragging:** Drag a node type from the left rail and drop it anywhere on the canvas to place it at that position.

### Edit a node

Click any node on the canvas to select it. The right panel shows the Inspector:

- **Label** — the node's display name (inline edit in the inspector)
- **Content** — the node's instruction text, edited in CodeMirror with `{variable}` syntax highlighting and autocomplete
- **Mute** — excludes the node from compilation without deleting it
- **Delete** — removes the node and all its edges

### Connect nodes

Hover a node until the connection handles appear (small circles at the top and bottom). Drag from a source handle to a target handle on another node to create an edge.

Edges define dependency relationships. The compiler respects topological order within each node type section — a node connected downstream of another compiles after it.

For **Conditional nodes**, the right handle is the `yes` branch and the left handle is the `no` branch.

### Delete nodes and edges

Select one or more nodes (click, or shift-click multiple) then press `Backspace` or `Delete`. Deleting a node cascades to all its edges.

Click an edge then press `Backspace` or `Delete` to remove it without touching the nodes.

### Move nodes

Drag any node to reposition it. The position is persisted automatically.

---

## Variables

Variables are `{named_placeholders}` written directly in node content. They flow runtime data into the compiled prompt.

```
You are a customer service agent for {company_name}.
The customer is {customer_name} with account ID {account_id}.
```

### Variable Explorer

The left rail shows all variables auto-discovered across the graph. Clicking a variable:

- Highlights **producing nodes** (Context and Memory nodes that define the variable)
- Highlights **consuming nodes** (nodes that reference `{variable_name}`)

This lets you trace exactly where each piece of runtime data flows before making changes.

### Variable rules

- Defined in **Context** or **Memory** nodes
- Consumed in any node type
- Variables used in node content but not defined in any Context or Memory node trigger an `undefined_variable` diagnostic warning
- Variables defined in Context or Memory nodes but not referenced anywhere trigger an `unused_variable` diagnostic warning

---

## Diagnostics

The diagnostics panel runs continuously as you edit and shows the health of your graph.

Status bar at the bottom of the inspector shows:

- **✓ Ready** — no issues
- **⚠ N warnings** — graph will compile but may not behave as intended
- **✕ N errors** — graph cannot compile correctly

### Diagnostic checks

| Code | Level | Description |
|---|---|---|
| `cycle` | Error | Two or more nodes form a circular dependency |
| `floating_node` | Warning | A node has no edges — it is excluded from compile order |
| `no_persona` | Warning | No Persona node — agent has no defined identity |
| `multiple_personas` | Warning | More than one Persona node — conflicting identities |
| `no_output` | Warning | No Output node — response format is undefined |
| `empty_output` | Warning | Output node exists but has no schema |
| `multiple_outputs` | Warning | Multiple Output nodes — ambiguous response format |
| `undefined_variable` | Warning | `{variable}` used in a node but not defined in any Context or Memory |
| `unused_variable` | Warning | Variable defined in Context or Memory but referenced nowhere |
| `agent_no_graph` | Warning | Agent node has no sub-agent graph selected |
| `agent_no_output_var` | Warning | Agent node has no output variable configured |

Nodes with warnings or errors show a colored indicator on the canvas. Resolve all errors before deploying.

---

## The Live Compiler

The right panel's **Compiler** section shows the assembled prompt in real time as you edit.

### Controls

- **Raw / Rendered toggle** — switch between the raw Markdown prompt and the rendered HTML view
- **Copy** — copy the raw prompt to clipboard
- **Provider selector** — choose Anthropic, OpenAI, or Gemini to apply provider-specific transforms (wraps in `<prompt>` tags for Anthropic, plain Markdown for others)

### What the compiler shows

- **Token estimate** — estimated token count for the selected provider
- **Cost estimate** — estimated input cost at published pricing
- **Included / Excluded** — how many nodes compiled vs. were muted

### Compile order

Nodes compile in this fixed order, regardless of canvas position:

```
ORCHESTRATION   ← Agent (sub-agent) directives
MISSION         ← Persona nodes
OPERATIONAL RULES ← Constraint nodes
CONTEXT         ← Context nodes
SKILLS          ← Skill nodes
TOOLS           ← Tool nodes
MEMORY          ← Memory nodes
CONDITIONAL LOGIC ← Conditional nodes
EVALUATION      ← Evaluation nodes
OUTPUT FORMAT   ← Output nodes
```

Within each section, edges determine the order — nodes connected downstream of others compile after them.

---

## Knowledge Registry

The left rail's **Registry** tab lists reusable assets shared across your organization.

### Asset types

| Type | Purpose |
|---|---|
| **Skill** | Reusable capability instructions (planning, retrieval, citation, etc.) |
| **Policy** | Organization-wide rules (safety, tone, privacy) |
| **Schema** | Reusable output format definitions |
| **Memory Template** | Reusable memory structures |

### Using registry assets on a graph

**Drag** a registry item from the left rail onto the canvas. A **linked node** is created — its content mirrors the registry asset.

Linked nodes show a `◆` indicator in the inspector. Changes to the registry asset propagate to all linked nodes across all graphs.

### Converting a local node to a registry skill

If you have written a Skill node locally and want to share it:

1. Select the Skill node
2. In the inspector, click **Convert to Skill**
3. The node becomes linked to a new registry skill with the same content

### Detaching a linked node

To make a local copy that no longer syncs with the registry:

1. Select the linked node
2. In the inspector, click **Detach**
3. The node becomes a local copy — edits no longer affect the registry

### Packages

Packages are bundles of registry assets (a complete agent architecture). To install a package:

1. Open the **Packages** tab in the left rail
2. Click **Install** on any package
3. All nodes in the package are added to your canvas as linked nodes

---

## AI Architect

The AI Architect is a natural-language copilot that edits your graph structure directly.

### Opening the Architect

Click the **AI Architect** button in the studio header.

### What you can ask

**Generate** — create new nodes from a description:
> "Add a skill that teaches the agent to summarize research findings with citations."

**Decompose** — break a monolithic prompt into structured nodes:
> "Split this prompt into a persona, constraints, and context nodes."

**Optimize** — reduce token usage:
> "Reduce the token count of this graph by 20% without losing core behavior."

**Refactor** — convert duplicate logic into reusable skills:
> "Find repeated instructions and convert them into a shared skill."

**Explain** — understand graph behavior:
> "Why is the {customer_profile} variable required here?"

### Prompt-to-Graph import

Paste a legacy prompt into the Architect and ask it to analyze and build a graph:
> "Convert this prompt into a structured graph."

The Architect will extract variables, identify distinct concerns, and create nodes automatically. Review the result in the canvas before publishing.

### Reviewing Architect changes

All Architect changes appear on the canvas immediately. The graph is marked as **unsaved** (shown in the header). Review the nodes, run diagnostics, and check the live compiler output before publishing.

---

## Publishing and Versioning

### Saving vs. Publishing

- **All edits auto-persist** — moving, connecting, and editing nodes saves to the database immediately. You will never lose work.
- **Publishing** creates an immutable snapshot (a Graph Version) used for deployment. The header shows `● unsaved` when unpublished changes exist.

### Publish

Click **Publish** in the studio header. A new version is created with:
- A version number (auto-incremented)
- A full snapshot of all nodes and edges

### Version history

In the right-panel inspector (when no node is selected), the **Versions** tab lists all published versions. Click **Restore** on any version to revert the canvas to that state. The restored state is a new draft — it does not overwrite history.

---

## Deploying an Agent

Deploying makes a published version callable as a REST API endpoint.

### Prerequisites

- At least one published Graph Version must exist
- The diagnostics panel must show no blocking errors

### Deploy

1. Click **Deploy** in the studio header
2. Choose an environment: **Development**, **Staging**, or **Production**
3. The deployment is created with a unique endpoint slug

The deploy panel shows the endpoint slug (e.g. `my-agent-a1b2c3`). Your deployed endpoint is:

```
POST /api/v1/deployments/:deployment_id/run
```

Each environment is independent. Deploying to production does not affect staging.

---

## Runtime API

### Execute a deployed agent

```http
POST /api/v1/deployments/:deployment_id/run
Content-Type: application/json

{
  "variables": {
    "customer_name": "Alice",
    "account_id": "acct_123",
    "inventory": [...]
  }
}
```

The runtime:
1. Loads the pinned graph version
2. Runs any sub-agent orchestration (if Agent nodes are present)
3. Injects your variables into `{placeholder}` tokens
4. Returns the resolved prompt ready to send to your LLM

**Response:**

```json
{
  "prompt": "You are a customer service agent...",
  "sub_agent_calls": []
}
```

### Compile without deploying

```http
POST /api/v1/graphs/:graph_id/compile
Content-Type: application/json
```

Returns the compiled prompt from the current draft state. Useful for previewing during development.

---

## Multi-Agent Composition

Agent nodes let one graph call other deployed graphs as sub-agents before its own LLM call. All sub-agent results are resolved first, then injected as variables into the parent prompt.

### Adding an Agent node

1. Drag **Agent** from the Node Library onto the canvas
2. Select the node — the inspector shows:
   - **Sub-agent graph** — pick which graph this node calls
   - **Output variable** — name for the sub-agent's output (e.g. `research_result`)
   - **Input mapping** — map parent graph variables → sub-agent input variables
   - **On error** — `fail` (abort if the call fails) or `continue` (inject nil and proceed)
   - **Timeout** — per-call timeout in milliseconds (default 10,000ms)

### How orchestration works

```
User request
    │
    ▼
Platform runtime
    │
    ├─ Dispatch sub-agent calls (parallel where graph allows)
    │   ├─ Research Agent → {research_result}
    │   └─ Compliance Agent → {compliance_check}
    │
    ▼
Parent prompt assembled with all variables populated
    │
    ▼
Parent LLM call → final response
```

Sub-agents are dispatched **before** the parent LLM is called. The parent prompt never sees the directive blocks — they are stripped after orchestration and replaced with actual results.

### Parallel fan-out

Agent nodes with no dependency between them run in parallel automatically. These nodes show a `‖` badge on the canvas.

To create a parallel fan-out:
- Add multiple Agent nodes to the canvas
- Do **not** connect them to each other
- Connect them both downstream of the same upstream node

### Sequential pipeline

To chain agents in sequence (each feeds the next):
- Set Agent A's `output_var` to `research_result`
- Map Agent B's input to `research_result` in its Input Mapping

Agent B will be placed in the next dependency wave and run after Agent A completes.

### Conditional routing (diamond → agent branches)

Use a **Conditional** node to route to different sub-agents based on a runtime variable:

1. Add a **Conditional** node to the canvas
2. Set its content to a condition expression:
   - `{connectivity_error} == "true"` — check for a specific value
   - `{connectivity_error}` — truthy check
3. Connect the Conditional node's **yes** handle to one Agent node
4. Connect the Conditional node's **no** handle to another Agent node
5. Give both Agent nodes the **same output variable name**

At runtime, the condition is evaluated. Only the matching branch runs. The other branch is skipped and its output variable is set to nil. Downstream nodes receive the same variable regardless of which branch ran.

Supported condition formats:
- `{var} == "expected_value"` — exact string match
- `{var} != "expected_value"` — string inequality
- `{var}` — truthy (not nil, empty, "false", or "0")
- `!{var}` — falsy

### On-error behavior

| Setting | Behavior when sub-agent call fails |
|---|---|
| `fail` | Abort the entire orchestration; return an error to the caller |
| `continue` | Inject nil for the output variable; record the error in metadata; proceed |

Use `continue` for non-critical sub-agents (e.g. a cache lookup where falling back to nil is acceptable).

---

## Organization and Members

### Switching organizations

If you belong to multiple organizations, click your org name in the studio header to open the org switcher. Click any org to switch. All studio data (graphs, registry, deployments) is scoped to the active org.

### Inviting members

Organization owners and admins can invite new members:

1. Navigate to `/org/members`
2. Click **Invite Member**
3. Enter the email address and assign a role
4. An invitation email is sent with a unique accept link (valid 7 days)

### Roles

| Role | Permissions |
|---|---|
| **Owner** | Full access; manage members and billing |
| **Admin** | Full access; invite/remove members |
| **Editor** | Create and modify graphs, skills, deployments |
| **Viewer** | Read-only access to graphs and registry |

### Accepting an invitation

Click the link in your invitation email. If you already have an account, you will be added to the org immediately. If not, you will be prompted to create a password first.
