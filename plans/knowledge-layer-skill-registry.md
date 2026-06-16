# Plan — Knowledge Layer: Operationalize the Skill Registry

Source requirement: `KNOWLEDGE_LAYER_REQUIREMENTS.md`
Status: **Not started**
Owner: —
Last updated: 2026-06-16

## Objective

The `Nspark.Registry` domain and `Skill` resource already exist. This phase is
**integration, not new architecture**: make reusable Skills a first-class
workflow that flows through Registry → Graph → Compiler → Deployments → AI
Architect, so editing a Skill once is reflected everywhere it is used.

## Decisions of record

- **Linked nodes store NO content.** A linked Skill node drops its own `content`;
  the compiler resolves content from the Skill at compile time. Single source of
  truth. (Today `create_linked_node/4` copies content — this changes.)
- **Versioning = integer bump, no `SkillVersion` table.** `publish` bumps the
  version int and flips status to `active`. Reproducibility/rollback come from
  the **frozen GraphVersion snapshot**, not from re-fetching old Skill content.
  A `SkillVersion` table can be added later if version pinning lands.
- **Resolution timing differs by surface:**
  - Studio authoring + live `/compile` → resolve the Skill's **latest active**
    version every compile (authors always see current).
  - Publish → `GraphVersion` snapshot → resolve and **freeze** content into the
    snapshot; also record a resolved-skill-version manifest.
  - Deployment `/run` → uses the frozen snapshot; no re-resolution. Skill edits
    reach a deployment only on the **next publish**.
- **Scope = Skill only.** Policy / Schema / Memory Template linked nodes remain
  copy-based for now (they are non-goals this phase). Do not generalize the
  resolution engine prematurely.

## Non-goals (this phase)

Marketplace · cross-org sharing · multi-agent composition · Policy/Schema/Memory
resources · Skill version pinning.

---

## Success criteria

The phase is complete when:

- [x] Skills are routinely reused across graphs (create → drag → linked node works end to end).
- [x] Linked Skills compile correctly; missing references fail validation.
- [x] Users can see a Skill's dependencies and blast radius before editing it.
- [x] Deployments capture the graph version **and** resolved Skill versions.
- [x] Skills can be created, managed, and proactively extracted from duplicated
      logic across graphs.

---

## Phase 1 — Registry ↔ Graph integration  ✅

A linked Skill must feel different from a local node, and the source of truth
must be obvious.

- [x] **Create Skill from scratch** — "+ New Skill" button under the REGISTRY
      rail header opens a modal (name / description / content) calling
      `Skill.create` (draft). (Was a gap: previously skills could only be derived
      from a node or created in AshAdmin.)
- [x] Stop copying content on link: `create_linked_node/4` sets `content: nil`
      for `skill` nodes (non-skill linked types keep their copy — out of scope).
- [x] Inspector: a linked Skill node hides the CodeMirror editor and shows the
      resolved Skill content **read-only** under a "⟳ MANAGED BY REGISTRY"
      banner.
- [x] Linked Skill nodes are visually distinct on the canvas — `⟳` badge +
      `class:linked` tint and dashed left border in `BlueprintNode.svelte`; no
      content preview (content lives in the Skill).
- [x] "Navigate to source Skill" — the inspector's "Open '<name>' ↗" button opens
      the Skill's impact modal (`inspect_skill`).
- [x] Data migration `20260616180901` nulls `content` on existing linked skill
      nodes (data-only Ecto migration — does not touch resource snapshots).
- [x] `convert_to_skill` leaves a content-less linked node; `detach_node` now
      **clones** the resolved content back into the node (was leaving it empty).

## Phase 2 — Compiler resolution  ✅

Compile flow: Validate → **Resolve Registry Assets** → Resolve Variables →
Topological Sort → Assemble.

- [x] `Nspark.Registry.resolve_skills(nodes, opts)` — batch-loads linked Skills,
      swaps in current content, returns `%{nodes, manifest, problems}` where
      `manifest` is `[%{id, name, version}]`. (Returns a map, not `{:ok}/{:error}`,
      so studio can render *and* warn; the API branches on `problems`.)
- [x] Missing or **deprecated** Skill reference → `Nspark.Registry.resolution_diagnostics/1`
      emits `:error`-level diagnostics surfaced in the existing panel (was a silent
      `_label_`). Note: domain enum is `draft/published/deprecated` — the spec's
      "active/archived" maps to `published`/`deprecated`.
- [x] `Compiler.compile/3` stays pure (resolved nodes in). Wired `resolve_skills`
      ahead of it at the live call sites: `refresh/1` and `graph_controller`
      (the latter returns 422 on unresolved references).
- [x] Compiler output reports resolved versions: `compile/3` echoes
      `resolved_assets: [%{id, name, version}]` into the result; studio compiler
      panel shows "N linked skills" with a `name vN` tooltip; API returns
      `compiled.resolved_skills`.
- [x] Tests: `test/nspark/registry/resolution_test.exs` (resolve, missing,
      deprecated, snapshot maps, pass-through). Full suite green (22 tests).

## Phase 3 — Dependency awareness  ✅

Show consumers and blast radius before shared logic is edited.

- [x] Skill usage aggregates: `Nspark.Registry.skill_usage_index/1` +
      `skill_usage/2` — linked-node count, distinct consuming graphs, and
      dependent deployments (scanned from active deployments' frozen snapshots,
      so it works now without waiting on Phase 4's manifest).
- [x] "Used By" list shown in a skill detail/impact modal, opened via the ⓘ
      button on each skill in the Registry rail; rail items also show a `▦ N`
      usage badge with a tooltip.
- [x] Impact analysis surface: modal shows "Affected Graphs · Affected
      Deployments · Linked Nodes" before editing. (Verified live: 2 graphs / 2
      nodes / 0 deployments.)
- [x] Block/confirm publish when blast radius is non-trivial — the skill modal's
      **Publish** button carries a `data-confirm` summarizing affected graphs +
      live deployments (and that deployments hold their pinned version until each
      graph is re-published). Delivered with the Skill lifecycle work below.
- [x] Tests: `test/nspark/registry/usage_test.exs` (node/graph counts,
      empty usage, deployment snapshot scan). Full suite green (25 tests).

## Phase 4 — Version alignment in deployments  ✅

A deployment must record graph version **and** resolved Skill versions for
rollback, auditing, and reproducible compilation.

- [x] On publish, `publish_graph/5` resolves Skills and **freezes** their content
      into the `GraphVersion` snapshot, so a deployed prompt never changes when a
      Skill is later edited. (Test proves a post-publish skill edit leaves the
      snapshot untouched.)
- [x] `GraphVersion.resolved_skills` manifest (`[%{id, name, version}]`) recorded
      at publish for O(1) impact/audit/rollback lookups. Migration
      `20260616171204_add_graph_version_resolved_skills`.
- [x] Deployment `run` path uses the frozen snapshot only — verified
      `deployment_controller`/`orchestrator` never call `resolve_skills`; the run
      response now echoes `resolved_skills` from the pinned version.
- [x] Resolved versions surfaced in the studio version-history panel (`▦ N` badge
      with a `name vN` tooltip); publish is **blocked** with a clear flash when a
      linked Skill is missing/deprecated.
- [x] Tests: `test/nspark/architecture/publish_resolution_test.exs` (freeze,
      immutability after edit, blocked publish). Full suite green (28 tests).

## Phase 5 — AI Architect / Registry intelligence  ✅

Make the Registry first-class in the authoring workflow. Implemented
**deterministically** rather than via an LLM scan — "eliminate copy-pasted logic"
is a reliability problem, not a generation problem; exact/normalized matching is
cheaper, testable, and never hallucinates.

- [x] Extract Skill — promoting a node's content into a Skill + linked node
      already ships as the inspector "→ Save as Skill" (Phase 1). The new bulk
      `extract_shared_skill` generalizes it to many nodes at once.
- [x] Find Skill usage — answered by the Phase 3 impact modal
      (`skill_usage/2`): graphs + deployments a Skill is used by.
- [x] Refactor duplicates — `Nspark.Registry.duplicate_skill_candidates/1`
      finds local (non-linked) Skill nodes across the org that share normalized
      content (≥2 occurrences, ≥24 chars), grouped with their graphs + node ids.
- [x] Proactive suggestion — a "✦ N reusable pattern(s) found" banner in the
      Registry rail opens a Suggestions modal; one click on **Extract as shared
      Skill** creates the Skill and links every duplicate node across graphs
      (`extract_shared_skill`, with a blast-radius confirm).
- [x] Tests: `test/nspark/registry/duplicate_detection_test.exs` (cross-graph
      dupes, single-occurrence/short/linked exclusions). Full suite green
      (36 tests).

**Scoped out (intentional):** routing the natural-language Architect chat to
these registry operations. The deterministic engine + UI is the reliable core;
an NL front-end over it is a thin, optional future layer and adds nondeterminism
to a governance feature. Detection is restricted to `skill`-type, non-linked
nodes to match the existing "Save as Skill" convention.

---

## Notes

- Ash rules: never hand-write migrations — `mix ash.codegen` to generate,
  `mix ash.migrate` to run.
- [x] `Skill` lifecycle hardening — done. `publish` (version bump + status
  `:published`) and `archive` (status `:deprecated`) are **admin-only** update
  actions; editors can create drafts and edit content but not change
  status/version. `created_by`/`updated_by` actor relationships added (migration
  `20260616172111`). Studio exposes admin-gated Publish/Archive in the skill
  impact modal. Tests: `test/nspark/registry/skill_lifecycle_test.exs`.
  Enum vocabulary: `:published` = the spec's "active", `:deprecated` = "archived".
- Test backfill for the resolution engine and the missing-reference error path
  (the Registry currently has no resolution tests).
