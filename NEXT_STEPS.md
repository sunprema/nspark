# Newtonian Spark — Next Steps

Status snapshot and prioritized backlog. Reflects the codebase as of 2026-06-15.

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

- After login, read the user's `Membership`s; let them pick/switch an active org (header switcher).
- Set the active org as the Ash tenant in the LiveView mount and any controllers (`Ash.PlugHelpers.set_tenant` / on_mount assigning tenant).
- Gate the studio with `:live_user_required`.
- Replace `demo_org/0` and the first-org fallback in `StudioLive`.

### 1.2 Authorization (RBAC)
Product resources currently have **no authorizer** (open in dev).

- Add `Ash.Policy.Authorizer` + policies to `Project`/`Graph`/`Node`/`Edge`/registry resources.
- Map the per-org `Role` (owner/admin/editor/viewer) to read/write/manage permissions.
- Generate policy charts (`mix ash.generate_policy_charts`) to review.

### 1.3 Invitation delivery + accept UI
The `invite`/`accept` actions exist but there is no email or web flow.

- Add an `Invitation` sender (follow the `User.Senders` pattern) to email the token.
- Build accept route/LiveView (look up by token → `accept_invitation`).
- Org members + invitations management screen.

---

## Priority 2 — complete the core domain

### 2.1 Deployments domain
Last core domain from the HLD (not yet scaffolded).

- `Nspark.Deployments.Deployment` — `environment` (dev/staging/prod), `status`, `endpoint_slug`, `deployed_version`; belongs_to project + graph version.
- Publish flow: snapshot the graph into `GraphVersion.graph_snapshot` (canonical JSON), then deploy a pinned version.
- Runtime API endpoints: `POST /api/v1/graphs/:id/compile` and `POST /api/v1/deployments/:id/run` (variable injection) — see HLD §8.

### 2.2 Graph persistence: save/publish/versions
Implement the three-tier model end to end (HLD §4).

- Explicit Save + debounced autosave already partially covered by per-edit persistence; formalize a graph-level save/dirty state.
- Publish → create immutable `GraphVersion` snapshot (+ dependency + compiler snapshots).
- Version history UI: list, diff, rollback (`ash_paper_trail` is available for asset history).

---

## Priority 3 — studio depth

### 3.1 Compiler hardening
- Copy-to-clipboard + raw/rendered toggle on the Live Compiler panel.
- Real tokenizer per provider (replace the `chars/4` heuristic); cost estimate.
- Topological ordering **within** a section using edges (not just inserted_at).
- Model-specific transforms (OpenAI / Anthropic / Gemini) behind a provider abstraction.

### 3.2 Diagnostics panel (UX §9)
- DAG validation: cycle detection, floating nodes, missing connections.
- Variable diagnostics: undefined vs unused variables.
- Output diagnostics: missing/invalid schema; conflicting/duplicate instructions.
- Surface as a persistent panel with ✓ / ⚠ / ✕ states; mark node states on the canvas.

### 3.3 Variable explorer interactions (UX §4.2)
- Click a variable → highlight consuming + producing nodes, show dependency path.

### 3.4 Registry in the studio
- Drag a registry `Skill`/`Policy`/etc. onto the canvas → create a **linked** node (`Node.source_asset_id` set).
- "Convert to Skill" / clone (detach) actions from the inspector.
- Knowledge Registry browser in the rail (skills/policies/schemas/memory templates), search.

### 3.5 Canvas polish
- Conditional-group wrapper rendering (the dashed `IF {mode} == …` frame from the reference).
- Node type → richer card treatments; muted styling parity with the reference.
- Minimap/controls theming; fit-to-selection; keyboard shortcuts.

---

## Priority 4 — platform / AI

- **AI Architect** (HLD §7): NL copilot that edits graph structure; Prompt-to-Graph import (Instructor + provider abstraction; `ash_ai` is a dep).
- **Oban jobs** for compilation, deployment pipelines, version snapshots, AI jobs (`ash_oban` available).
- **Packages** UX: bundle/install reusable architecture bundles across projects.
- Audit trail (`ash_paper_trail`) across graph/skill/deployment changes.

---

## Known cleanups / notes

- `mdex` was added; a brand-new dep + NIF requires a **dev-server restart** (cannot hot-load).
- Dev sanity-check rows exist in the dev DB from earlier verification; `mix ash.reset` to clean.
- Demo data: `mix run priv/repo/demo_seed.exs` (idempotent) creates the `nspark-demo` org + "Agent Planner" graph.
- `CodeEditor.svelte` keeps the autofixer's advisory `bind:this`/`$effect` notes — intentional (CodeMirror mount + Svelte Flow writable-state bridge can't use `$derived`).
