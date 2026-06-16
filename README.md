# Newtonian Spark

**Build AI agents like software.**

Newtonian Spark is a visual architecture platform that transforms agent behavior from unstructured prompt documents into maintainable, versioned, deployable systems.

Just as engineers use IDEs to organize source code, Newtonian Spark gives teams a structured environment to design, validate, compile, and deploy the logic that drives AI agents.

---

## What It Is

Most AI agents are built as long, fragile prompt strings. When behavior needs to change, someone edits raw text and hopes nothing breaks.

Newtonian Spark treats agent behavior as architecture:

- **Prompts** become modular logic components with explicit dependencies
- **Skills** become reusable assets shared across agents
- **Knowledge** becomes a composable, versioned resource
- **Deployment** becomes a controlled, environment-aware pipeline

---

## Core Features

### Visual Graph Studio

Design agent behavior on an interactive canvas. Each node represents a discrete piece of logic; edges define how they compose.

**Node types:**

| Type | Purpose |
|---|---|
| **Persona** | Identity, role, tone, and behavioral guidelines |
| **Constraint** | Rules, guardrails, and compliance requirements |
| **Context** | Runtime variables and dynamic data injection |
| **Conditional** | Branching logic with yes/no routing (diamond shape) |
| **Skill** | Reusable capability packages |
| **Memory** | Long-term and episodic knowledge references |
| **Tool** | External integrations and API calls |
| **Evaluation** | Self-check and quality validation rules |
| **Output** | Schema and format requirements |

**Variable system:** Write `{variable_name}` anywhere in node content. The studio automatically discovers all variables, highlights producers and consumers, and flags undefined or unused variables in the diagnostics panel.

**Conditional routing:** Diamond nodes branch the graph based on runtime conditions. Each outgoing edge carries a branch label (`yes`/`no`) stored in edge metadata, enabling the compiler to generate conditional assembly logic.

```
                  ┌─────────────────────┐
                  │     Context node    │
                  └──────────┬──────────┘
                             │
                   ◇ Connectivity Error? ◇
                  /  error.type == :connectivity  \
                no                                yes
               /                                    \
  ┌────────────────────┐               ┌──────────────────────┐
  │  Ignore            │               │  Continue            │
  │  Drop the request  │               │  Proceed with        │
  │  silently.         │               │  degraded context.   │
  └────────────────────┘               └──────────────────────┘
```

Both branch nodes are standard blueprint nodes — the diamond shape and the `no`/`yes` edge labels are all that distinguish a conditional from any other connection in the graph.

### Compiler

The graph is compiled into model-ready instructions on every change. The compiler:

- Assembles nodes in dependency order (Persona → Constraints → Context → Skills → Conditionals → Evaluations → Output)
- Detects circular dependencies, floating nodes, undefined variables, and conflicting instructions
- Surfaces warnings and errors in a real-time diagnostics panel

### Skill Registry

A central repository of reusable skills shared across agents and teams.

- **Linked skills** — live reference; updates propagate globally to all graphs using the skill
- **Cloned skills** — detached local copy for graph-specific customization
- Full version history, diff tracking, and rollback support

### AI Architect

A natural-language copilot embedded in the studio. Ask it to:

- "Add a rule requiring citations for all claims"
- "Find all nodes referencing inventory logic"
- "Convert duplicated instructions into a reusable skill"
- "Reduce prompt size by 20%"

The Architect modifies graph structure directly rather than editing raw text.

### Prompt-to-Graph Import

Paste a legacy prompt and the AI extracts logic, identifies variables, detects reusable skills, and generates the graph structure automatically.

### Deployment Layer

Deploy any graph version as a callable API endpoint.

- **Environments:** Development, Staging, Production
- **Runtime variable injection:** POST a JSON payload; the compiled graph resolves `{variable}` placeholders at call time
- **Version pinning:** Applications lock to a specific graph version for stability

### Organization & Access Control

- Multi-organization support with invite-only onboarding
- Role-based access: Viewer, Editor, Admin
- Full audit trail on all graph and registry changes

---

## Getting Started

### Prerequisites

- Elixir 1.16+
- PostgreSQL 14+
- Node.js 18+

### Setup

```bash
# Install dependencies and set up the database
mix setup

# Start the server
mix phx.server
```

Visit [localhost:4000](http://localhost:4000).

### Demo Data

Seed a demo organization and graph with sample nodes already wired up:

```bash
mix run priv/repo/demo_seed.exs
```

This creates an "Nspark Demo" org with an "Agent Planner" graph containing a full node chain including a conditional node — ready to explore in the studio.

---

## Tech Stack

| Layer | Technology |
|---|---|
| Backend | Elixir / Phoenix LiveView |
| Domain | Ash Framework + Spark DSL |
| Database | PostgreSQL (via AshPostgres) |
| Canvas | Live Svelte + SvelteFlow |
| Auth | AshAuthentication |

---

## Project Structure

```
lib/
  nspark/
    architecture/     # Graph, Node, Edge resources
    registry/         # Skill, Schema, Policy, Memory Template
    deployments/      # Deployment resource and versioning
    compiler.ex       # Graph → prompt compilation
    architect.ex      # AI Architect worker
    diagnostics.ex    # Real-time graph validation
  nspark_web/
    live/
      studio_live.ex  # Main visual studio LiveView

assets/
  svelte/
    GraphCanvas.svelte      # SvelteFlow canvas wrapper
    BlueprintNode.svelte    # Standard node component
    ConditionalNode.svelte  # Diamond-shaped conditional node
```

---

## Roadmap

- **Agent Marketplace** — discover and share skills across organizations
- **Multi-agent composition** — build agents from other agents
- **Execution tracing** — observe how compiled logic affects model outputs
- **Visual memory graphs** — inspect how memory influences reasoning
