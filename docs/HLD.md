# High-Level Technical Design (HLD)

# Newtonian Spark

Version 2.0

---

# 1. Architectural Vision

Newtonian Spark is an Agent Architecture Platform.

The system enables teams to design, validate, version, compile, deploy, and reuse agent behavior as structured knowledge assets.

Prompts are treated as compiled artifacts rather than primary storage.

The platform architecture is built around:

- Graphs
- Skills
- Policies
- Memory Templates
- Output Schemas
- Packages
- Deployments

---

# 2. Technology Stack

## Backend

### Language

Elixir

### Web Framework

Phoenix

### Real-Time Layer

Phoenix LiveView

### Domain Layer

Ash Framework

### DSL Layer

Spark DSL

Used for:

- Validation
- Compiler Rules
- Node Definitions
- Package Definitions
- Skill Specifications

### Database

PostgreSQL

### Background Processing

Oban

Used for:

- AI Architect jobs
- Graph compilation
- Deployment pipelines
- Version snapshots

---

## Frontend

### Interactive UI

Svelte

### Integration

Live Svelte

### Graph Engine

Svelte Flow

### Content Editing

CodeMirror 6

Node `content` is prompt-as-code (Markdown instructions with `{variable}` tokens), so it is edited in a code editor rather than a WYSIWYG.

A custom CodeMirror extension provides `{variable}` highlighting and autocompletion, wired into the Variable Explorer and the compiler's variable analysis.

### Markdown Rendering

MDEx

Server-side Markdown rendering (CommonMark + GFM, AST access, syntax highlighting, sanitization) for the Live Compiler panel, node previews, and compiled-prompt display. Rendering stays in Elixir; no JS Markdown renderer is shipped.

### State Management

Svelte Stores

---

## AI Layer

### Structured Generation

Instructor

### Providers

OpenAI

Anthropic

Google Gemini

Provider abstraction layer required.

---

# 3. Domain Architecture

## Core Domain Objects

```text
Organization
│
├ Projects
│
├ Knowledge Registry
│   ├ Skills
│   ├ Policies
│   ├ Schemas
│   └ Memory Templates
│
├ Graphs
│
├ Packages
│
├ Deployments
│
└ Versions
```

---

## Module & Naming Conventions

The product's "Skill" concept collides with Claude/agent "skills" and `ash_ai` tooling, and several other domain names (`Schema`, `Tool`, `Memory`) collide with Ash/Ecto/Spark and `ash_ai` primitives. To avoid ambiguity, **no domain resource is ever defined as a bare `Nspark.<Name>`** — every resource lives under a domain-scoped namespace.

### Ash Domains and Resource Modules

| Ash Domain          | Resources                                                      |
| ------------------- | ------------------------------------------------------------- |
| `Nspark.Accounts`   | `Organization`, `User`                                        |
| `Nspark.Projects`   | `Project`                                                     |
| `Nspark.Architecture` | `Graph`, `Node`, `Edge`, `GraphVersion`                     |
| `Nspark.Registry`   | `Skill`, `Policy`, `Schema`, `MemoryTemplate`, `Package`      |
| `Nspark.Deployments` | `Deployment`                                                 |

Fully-qualified examples: `Nspark.Registry.Skill`, `Nspark.Registry.Schema`, `Nspark.Architecture.Node`.

### Collision Rules

- **Skill** — The product capability is always `Nspark.Registry.Skill`. Never a bare `Nspark.Skill`. When ambiguous in UI/docs, call it a "Registry Skill" to distinguish it from Claude/agent skills and `ash_ai` skills.
- **Tool** — The graph node type `:tool` is an enum value on `Nspark.Architecture.Node`, **not** a standalone resource. This avoids collision with `ash_ai` tools and Ash actions-as-tools. If a first-class Tool resource is later needed, namespace it `Nspark.Registry.Tool`.
- **Schema** — The reusable output schema is `Nspark.Registry.Schema`; never a bare `Nspark.Schema` (collides with Ash/Ecto/Spark schema concepts).
- **Memory** — The reusable memory structure is `Nspark.Registry.MemoryTemplate`.
- **Node types** — All nine node types (`persona`, `constraint`, `context`, `conditional`, `skill`, `memory`, `tool`, `evaluation`, `output`) are enum values on the `type` attribute of `Nspark.Architecture.Node`, **not** separate modules. This keeps node typing data-driven and avoids nine more module-name collisions.

---

# 4. Ash Resources

## Organization

Represents tenant boundary.

### Attributes

- id
- name
- slug
- settings

### Relationships

- has_many projects
- has_many users
- has_many skills
- has_many packages

---

## Project

Logical workspace.

### Attributes

- id
- name
- description
- status

### Relationships

- belongs_to organization
- has_many graphs
- has_many deployments

---

## Graph

Primary architecture artifact.

### Attributes

- id
- name
- description
- graph_version

### Relationships

- belongs_to project
- has_many nodes
- has_many edges

---

## Node

Graph component.

### Attributes

- id
- type
- label
- content
- metadata
- is_muted
- source_asset_id

### Node Types

- persona
- constraint
- context
- conditional
- skill
- memory
- tool
- evaluation
- output

---

## Edge

Dependency relationship.

### Attributes

- id
- source_node_id
- target_node_id
- edge_type

### Edge Types

- compile
- dependency
- reference

---

## Skill

Reusable capability.

### Attributes

- id
- name
- description
- content
- version
- status

### Relationships

- belongs_to organization

---

## Policy

Reusable governance rule.

Examples:

- Safety
- Compliance
- Legal
- Tone

---

## Schema

Reusable output definition.

Examples:

- JSON
- Markdown
- XML

---

## MemoryTemplate

Reusable memory structure.

Examples:

- Episodic Memory
- Working Memory
- Retrieval Memory

---

## Package

Reusable architecture bundle.

### Contains

- Persona
- Skills
- Policies
- Output Schemas

Example:

```text
Research Agent Package

├ Persona
├ Research Skill
├ Citation Policy
└ Output Schema
```

### Membership Model

The package's persona is stored inline (`persona_content`). Other parts are bundled via a `PackageItem` join that uses a **polymorphic reference** (`asset_type` + `asset_id`), so one package can hold mixed asset types (skill, policy, schema, memory_template) without a separate join table per type. There is no DB foreign key on `asset_id`; integrity is enforced in application logic.

Registry assets share an `AssetStatus` (`draft`/`published`/`deprecated`) and a `version` integer. The linked-vs-cloned distinction is **not** stored here — it lives on the consuming `Node` via `source_asset_id` (set = linked, null = cloned/local).

---

## GraphVersion

Immutable graph snapshot.

### Attributes

- version_number
- author
- changelog
- graph_snapshot

---

## Deployment

Published runtime endpoint.

### Attributes

- environment
- status
- endpoint_slug
- deployed_version

---

## Graph Persistence Model

Nodes and edges are Ash resources (normalized rows), **but the live editing loop does not round-trip to the database on every interaction.** The working graph lives as structured JSON in client/server state during editing and is reconciled to normalized rows on save. This gives a fast canvas and queryable durable data without trading one for the other.

### Three Tiers

**1. Live editing state — JSON (ephemeral)**

The working graph is structured JSON held in Svelte stores and mirrored in LiveView assigns. Svelte Flow operates directly on this representation. Edits (drag, connect, type) mutate client state only; no DB write per interaction. The compiler and diagnostics run against this in-memory JSON to drive the live preview.

**2. Persisted draft — normalized rows (durable source of truth at rest)**

On save, the working graph is reconciled to `Nspark.Architecture.Node` and `Nspark.Architecture.Edge` rows under the `Graph`. These rows are the canonical editable state and what cross-graph features query: variable analysis, registry dependency (`source_asset_id`), global search, diagnostics.

- Saves are **debounced autosave** (on idle / structural change) plus an explicit **Save**.
- Reconciliation is a **diff/upsert** against current rows (insert new, update changed, delete removed) inside a single Ash transaction (bulk actions).

**3. Immutable snapshot — JSON (on publish)**

On publish, current rows are serialized to canonical JSON and stored in `GraphVersion.graph_snapshot` (alongside dependency and compiler snapshots — see §10). Immutable. Deployed endpoints compile from a **pinned version's snapshot**, never from live draft rows.

### Canonical Serialization Contract

A **single canonical JSON shape** is defined once and used by all four surfaces: (a) consumed by Svelte Flow, (b) held in LiveView assigns, (c) reconciled to normalized rows, (d) stored in `graph_snapshot`. This prevents three divergent graph representations.

Node and edge IDs are **client-generated UUIDs**, stable across JSON, rows, and snapshots. This keeps Svelte Flow ids stable and makes diff/upsert reconciliation trivial.

Restoring a version rehydrates rows from its snapshot into a new draft; the snapshot itself stays immutable.

---

# 5. Compiler Architecture

## Philosophy

Graphs are compiled into model-ready instructions.

The graph itself is the source of truth.

Compiled prompts are generated artifacts.

---

## Compilation Pipeline

### Phase 1

Graph Validation

Checks:

- DAG integrity
- Missing nodes
- Floating nodes
- Invalid references

---

### Phase 2

Dependency Resolution

Resolve:

- Skills
- Policies
- Schemas
- Memory Templates

---

### Phase 3

Variable Analysis

Extract:

```text
{inventory}

{episodic_memory}

{customer_profile}
```

Build dependency graph.

---

### Phase 4

Topological Sort

Determine execution order.

---

### Phase 5

Assembly

Compiler Order:

1. Persona
2. Constraints
3. Context
4. Skills
5. Memory
6. Conditional Logic
7. Evaluation Rules
8. Output Schema

---

### Phase 6

Model Optimization

Apply model-specific transforms.

Examples:

- GPT
- Claude
- Gemini
- Llama

---

### Phase 7

Output Generation

Generate:

- Prompt Markdown
- JSON Configuration
- API Runtime Artifact

---

# 6. Compiler Diagnostics

Compiler returns:

```json
{
  "status": "warning",
  "errors": [],
  "warnings": ["floating_node", "unused_variable"]
}
```

---

## Validation Rules

### Graph

- Circular dependency detection
- Floating node detection

### Variables

- Undefined variables
- Unused variables

### Output

- Missing output schema

### Governance

- Duplicate policies
- Conflicting constraints

---

# 7. AI Architect Pipeline

## Import & Architect

### Step 1

Receive raw prompt.

### Step 2

Chunk and classify instructions.

### Step 3

Extract:

- Skills
- Variables
- Constraints
- Memory references

### Step 4

Generate graph structure.

### Step 5

Run diagnostics.

### Step 6

Suggest reusable assets.

### Step 7

Create graph transaction.

---

## Refactor Mode

AI can:

- Create skills
- Merge duplicated logic
- Create packages
- Optimize token usage
- Explain graph behavior

---

# 8. Deployment Architecture

## Environments

- Development
- Staging
- Production

---

## Runtime API

### Compile Endpoint

POST /api/v1/graphs/:graph_id/compile

Returns compiled artifact.

---

### Execute Endpoint

POST /api/v1/deployments/:deployment_id/run

Payload:

```json
{
  "variables": {
    "inventory": [],
    "customer_profile": {}
  }
}
```

Returns compiled runtime prompt.

---

# 9. Multi-Tenancy

Ash tenant isolation.

Every resource scoped by:

```text
organization_id
```

Includes:

- Graphs
- Skills
- Policies
- Packages
- Deployments

---

# 10. Versioning Strategy

Every publish action creates:

- Graph Snapshot
- Dependency Snapshot
- Compiler Snapshot

Immutable.

Supports:

- Rollback
- Diffing
- Auditing

---

# 11. Security

## Input Protection

Sanitize imported prompts.

Validate uploaded assets.

---

## Access Control

Role-based permissions.

Roles:

- Owner
- Admin
- Editor
- Viewer

### Membership Model

Users belong to organizations **many-to-many** through a `Membership` join resource that carries the per-org `role`. A user can be a member of multiple organizations with a different role in each.

`User`, `Token`, `Membership`, and `Invitation` are **global** (not multi-tenant) — they are the access layer that maps global identities onto tenant organizations. Keeping them global avoids the tenant-bootstrap problem: a user's memberships can be resolved at login *before* any tenant is set. Only product resources (Project, Graph, Node, …) are scoped by `organization_id`.

### Onboarding (Invite-Only)

There is no self-serve organization creation. Users join an organization via an `Invitation`:

1. An admin/owner invites an email with a role (`invite` action) — generates a single-use token, status `pending`, 7-day expiry.
2. The token is delivered out of band (email — sender is a follow-up).
3. A logged-in user accepts by token (`accept` action), which atomically marks the invitation `accepted` and creates the corresponding `Membership`.

Tenant resolution after login reads the user's memberships and sets the active organization as the Ash tenant. RBAC policy enforcement on resources is future work.

---

## Audit Trail

Track:

- Graph changes
- Skill updates
- Deployments
- Publishing events

---

# 12. Future Architecture

## Agent Marketplace

Share packages and skills.

---

## Multi-Agent Systems

Graphs may reference other graphs.

---

## Visual Memory Graphs

Inspect memory dependencies.

---

## Execution Tracing

Observe runtime reasoning paths.

---

## Agent Registry

Organization-wide knowledge repository.

Single source of truth for agent behavior.
