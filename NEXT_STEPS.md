# Newtonian Spark — Next Steps

Status snapshot and prioritized backlog. Reflects the codebase as of 2026-06-16.

## Where we are

**Domains (Ash, attribute multitenancy on `organization_id`):**

- `Nspark.Accounts` — `Organization` (tenant root, global), `User`/`Token` (auth, global), `Membership` (multi-org, per-org `Role`), `Invitation` (invite-only onboarding). All access-layer resources are **global**, not tenant-scoped.
- `Nspark.Projects` — `Project`.
- `Nspark.Architecture` — `Graph`, `Node`, `Edge`, `GraphVersion` + `NodeType`/`EdgeType` enums.
- `Nspark.Registry` — `Skill`, `Policy`, `Schema`, `MemoryTemplate`, `Package`, `PackageItem` (polymorphic bundling) + `AssetStatus`.

**User-facing studio (`/studio`, `NsparkWeb.StudioLive`):**

- Three-column blueprint shell (rail / Svelte Flow canvas / split inspector+compiler).
- Editable canvas: drag-to-persist positions, connect (create edge), add node from rail, delete (key + button, cascades edges), inspector label edit + mute + delete.
- CodeMirror 6 content editor with `{variable}` highlight + autocomplete; rail variable explorer (auto-discovered).
- Live compiler panel: `Nspark.Compiler` assembles non-muted nodes in compile order → rendered server-side with MDEx; updates after every mutation.

**Tests:** `test/nspark/compiler_test.exs`, `test/nspark_web/live/studio_live_test.exs` (12 total, green).

**Decisions of record:** editor = CodeMirror (edit) + MDEx (render), no TipTap; graph persistence = JSON-while-editing → normalized rows on save → JSON snapshot on publish; multi-org via `Membership`, invite-only; namespacing avoids `Skill`/`Schema`/`Tool` collisions. See `docs/HLD.md`.

---

## Priority 1 — close the foundational gaps

### 1.1 Active-organization session + tenant resolution
The studio currently falls back to the first/`nspark-demo` org (dev only) with `:live_user_optional`.

- [x] `/switch-org/:org_id` controller + `:live_user_and_tenant_required` on_mount hook
- [x] After login, read the user's `Membership`s; let them pick/switch an active org (header switcher).
- [x] Set the active org as the Ash tenant in the LiveView mount and any controllers (`Ash.PlugHelpers.set_tenant` / on_mount assigning tenant).
- [x] Gate the studio with `:live_user_required` (using `:live_user_and_tenant_required`).
- [x] Replace `demo_org/0` and the first-org fallback in `StudioLive`.
- [x] Redirect to `/studio` after successful login.

### 1.2 Authorization (RBAC)
Product resources currently have **no authorizer** (open in dev).

- [x] Add `Ash.Policy.Authorizer` + policies to `Project`/`Graph`/`Node`/`Edge`/registry resources.
- [x] Map the per-org `Role` (owner/admin/editor/viewer) to read/write/manage permissions.
- [x] Generate policy charts (`mix ash.generate_policy_charts`) to review.

### 1.3 Invitation delivery + accept UI
The `invite`/`accept` actions exist but there is no email or web flow.

- [x] Add an `Invitation` sender (`SendInvitationEmail`) to email the accept link.
- [x] Build accept route/controller (`GET /invitations/:token` → `accept_invitation`).
- [x] Org members + invitations management screen (`/org/members`, linked from studio header).

---

## Priority 2 — complete the core domain

### 2.1 Deployments domain
Last core domain from the HLD (not yet scaffolded).

- [x] `Nspark.Deployments.Deployment` — `environment` (dev/staging/prod), `status`, `endpoint_slug`, `deployed_version`; belongs_to project + graph version.
- [x] Publish flow: snapshot the graph into `GraphVersion.graph_snapshot` (canonical JSON), then deploy a pinned version.
- [x] Runtime API endpoints: `POST /api/v1/graphs/:id/compile` and `POST /api/v1/deployments/:id/run` (variable injection) — see HLD §8.

### 2.2 Graph persistence: save/publish/versions
Implement the three-tier model end to end (HLD §4).

- [x] Graph-level dirty state: `graph_dirty` assign, set true on any mutation, false after publish.
- [x] Publish → creates immutable `GraphVersion` snapshot (nodes + edges → canonical JSON), bumps `graph.graph_version`.
- [x] Version history UI in inspector: list of versions with date + "Restore" button (restore deletes+recreates canvas from snapshot).

---

## Priority 3 — studio depth

### 3.1 Compiler hardening
- [x] Copy-to-clipboard + raw/rendered toggle on the Live Compiler panel.
- [x] Real tokenizer per provider (replace the `chars/4` heuristic); cost estimate.
- [x] Topological ordering **within** a section using edges (not just inserted_at).
- [x] Model-specific transforms (OpenAI / Anthropic / Gemini) behind a provider abstraction.

### 3.2 Diagnostics panel (UX §9)
- [x] DAG validation: cycle detection, floating nodes, missing connections.
- [x] Variable diagnostics: undefined vs unused variables.
- [x] Output diagnostics: missing/invalid schema; conflicting/duplicate instructions.
- [x] Surface as a persistent panel with ✓ / ⚠ / ✕ states; mark node states on the canvas.

### 3.3 Variable explorer interactions (UX §4.2)
- [x] Click a variable → highlight consuming + producing nodes, show dependency path.

### 3.4 Registry in the studio
- [x] Drag a registry `Skill`/`Policy`/etc. onto the canvas → create a **linked** node (`Node.source_asset_id` set).
- [x] "Convert to Skill" / clone (detach) actions from the inspector.
- [x] Knowledge Registry browser in the rail (skills/policies/schemas/memory templates), search.

### 3.5 Canvas polish
- [x] Conditional-group wrapper rendering (the dashed `IF {mode} == …` frame from the reference).
- [x] Node type → richer card treatments; muted styling parity with the reference.
- [x] Minimap/controls theming; fit-to-selection; keyboard shortcuts.

---

## Priority 4 — platform / AI

- [x] **AI Architect** (HLD §7): NL copilot that edits graph structure; Prompt-to-Graph import (`Nspark.Architect` via `req` + `claude-opus-4-8` tool-use).
- [x] **Oban jobs** for compilation, deployment pipelines, version snapshots, AI jobs — `Nspark.Workers.ArchitectWorker` on `ai` queue; PubSub result delivery to LiveView.
- [x] **Packages** UX: bundle/install reusable architecture bundles across projects — packages browser in rail, click-to-install creates linked nodes.
- [x] Audit trail (`ash_paper_trail`) across graph/skill/deployment changes.

---

---

## Priority 5 — Multi-agent composition (see `MULTI_AGENT.md`)

### Phase 1 — Foundation ✓ (complete)

- [x] `:agent` added to `NodeType` enum (stored as `:text` in Postgres — no migration needed)
- [x] `AgentNode.svelte` — blue/indigo canvas component; shows agent name, version badge, input count, output var, on_error indicator
- [x] `ConditionalNode.svelte` — diamond SVG, `yes`/`no` handles, amber theme
- [x] Studio: Agent palette entry + drag-to-place; `update_agent_metadata` handler; inspector panel (sub-agent graph selector, output var, on-error toggle)
- [x] Edge metadata field (`edge.metadata :map`) — stores `branch`/`label` for conditional routing
- [x] Compiler: agent nodes compile to `[AGENT: output_var]...[\AGENT]` orchestration directives in an ORCHESTRATION section
- [x] Diagnostics: agent `output_var` treated as a produced variable; warns on missing `source_graph_id` or empty `output_var`
- [x] `Nspark.Orchestrator` — parse directives, sequential sub-agent dispatch, `on_error: continue/fail` policy, variable rendering
- [x] Deploy run endpoint wired through Orchestrator; returns `prompt` + `sub_agent_calls` metadata
- [x] `serialize_snapshot` includes node `metadata` (minus position) so agent directives reconstruct from published snapshots

### Phase 2 — Parallel + Conditional (in progress)

- [x] Parallel dispatch in Orchestrator — dependency-wave grouping; each wave dispatched via `Task.async` + `Task.await` with per-directive timeout
- [x] Timeout per Agent node (`metadata.timeout_ms`); inspector field; orchestrator enforces per-call timeout
- [x] Orchestration metadata surfaced in the deploy run response (`sub_agent_calls` with per-call duration + status)
- [x] Conditional node routing: diamond → Agent node branches based on runtime variable value
- [x] Studio: visualize parallel fan-out (multiple Agent nodes at same depth get a "parallel" indicator)

### Phase 3 — Depth + Observability

- [ ] Hierarchical orchestration (depth > 1 — sub-agents that are themselves orchestrators)
- [ ] Depth limit enforcement at compile time (configurable max, default 3)
- [ ] Execution trace: per-call logs surfaced in a future AgentOps panel
- [ ] Sub-agent output type checking against the referenced graph's Output node schema
- [ ] Cross-graph variable inspector in studio

---

## Known cleanups / notes

- `mdex` was added; a brand-new dep + NIF requires a **dev-server restart** (cannot hot-load).
- Dev sanity-check rows exist in the dev DB from earlier verification; `mix ash.reset` to clean.
- Demo data: `mix run priv/repo/demo_seed.exs` (idempotent) creates the `nspark-demo` org + "Agent Planner" graph.
- `CodeEditor.svelte` keeps the autofixer's advisory `bind:this`/`$effect` notes — intentional (CodeMirror mount + Svelte Flow writable-state bridge can't use `$derived`).
- `handle_event/3` grouping warning in `studio_live.ex` — pre-existing, clauses are logically grouped by concern not alphabetically; suppressing is low priority.
