# Plan — Semantic Graph Diff & Breaking-Change Detection

Source: `LIVE_PROMPT.md` brainstorm (the "prompt tree + diffing" idea, salvaged
into the pull-based product) + product-positioning **P1 — variable/version
contract**.
Status: **Phases 1–4 complete** — contract, diff engine, publish-time gate, and studio diff UI shipped. Phase 5 (NL summary) intentionally scoped out.
Owner: —
Last updated: 2026-06-16

## Objective

A published prompt edit must **never silently break a live app**, and a
governance reviewer must be able to see *what changed* between two
`GraphVersion`s — semantically, not as a raw text blob.

This phase delivers a deterministic **diff engine** over two graph versions that:

1. Extracts each version's **input contract** (the variables a calling app must
   supply, plus the outputs it produces).
2. Classifies the change between two versions as **breaking · compatible ·
   cosmetic**.
3. Gates publish on breaking changes (block/confirm, mirroring the existing
   Skill blast-radius confirm).
4. Renders a human-readable per-node change summary in the studio version
   history.

This is the P1 contract work given teeth: the structured graph can publish a
variable contract and detect breaking changes in a way a raw text prompt file
cannot. That is the moat.

## Why this and not LivePrompt's push model

LivePrompt proposed pushing live prompt diffs into running agents over a socket.
That is the **parked** orchestration runtime and it undermines the P0 selling
point (pinned, deterministic versions). We keep the *diffing insight* and drop
the runtime: diffs are computed **at publish time between immutable versions**,
in the pull model the buyer actually pays for. See `LIVE_PROMPT.md` verdict.

## Decisions of record

- **The contract is derived, not authored (v1).** A version's input contract is
  computed from the snapshot: every `{var}` referenced in node `content` is a
  **required string input**; every agent `output_var` is a **produced output**.
  No new authoring UI. A later typed-schema phase (optional/required/types) can
  refine `required` and add `type` — this plan must not block on it.
- **Diff engine is a pure module.** `Nspark.VersionDiff` takes two snapshots
  (string-keyed JSON, the canonical `serialize_snapshot/2` shape) and returns a
  plain map. No Ash, no IO — mirrors `Nspark.Compiler` / `Nspark.Diagnostics`.
  Testable in isolation, never hallucinates.
- **Two layers, kept separate:**
  - **Contract diff** (machine, drives the gate): variable set delta, output
    delta, provider change, resolved-skill version delta.
  - **Content diff** (human, drives the review UI): per-node added / removed /
    retyped / content-changed, with a readable label. Deterministic text diff;
    **no LLM** (a governance feature must be reproducible — same stance as the
    Skill registry's deterministic duplicate detection).
- **Breaking classification is conservative (v1 rules):**
  | Change | Class | Rationale |
  |---|---|---|
  | New required variable added | **breaking** | live app isn't sending it |
  | Variable renamed (add+remove of same arity) | **breaking** | app sends the old name |
  | `output_var` removed or renamed | **breaking** | downstream parsing breaks |
  | Variable removed | compatible | extra inputs are ignored; flag as semantic |
  | Provider changed | compatible | contract unchanged; flag for review |
  | Node content changed only | cosmetic | no contract change |
  | Node added/removed with no contract delta | cosmetic | structure only |
  Unknown/edge cases default to the **stricter** class.
- **Diff is computed against the immediately preceding version** (`version_number
  - 1`) at publish. Arbitrary version-pair diffs are supported on read for the
  studio "compare A↔B" view, computed on demand (cheap — pure function over two
  JSON maps).
- **Store the computed diff and contract on the new version** so history renders
  in O(1) without recompiling. `diff_summary` is denormalized cache, not source
  of truth (it can always be recomputed from two snapshots).

## Non-goals (this phase)

LLM/NL change summaries · typed variable schema (optional/required/types) ·
semantic *equivalence* detection (e.g. reordered-but-identical) beyond exact
node-content diff · cross-graph diffs · pushing diffs to runtimes (parked) ·
auto-bumping a semver-style version (we keep the integer `version_number`).

---

## Success criteria

The phase is complete when:

- [ ] Publishing a graph computes and stores its input contract + a classified
      diff vs the previous version.
- [ ] A breaking change (new required var / renamed var / dropped output) blocks
      or hard-confirms publish, with the offending fields named.
- [ ] A reviewer can open any two versions and see a per-node change list and the
      contract delta.
- [ ] The published contract is exposed on the version read API so an SDK/client
      can validate its inputs against it (ties into P1 runtime delivery).
- [ ] `Nspark.VersionDiff` is covered by unit tests for every classification row
      above. Full suite green.

---

## Phase 1 — Contract extraction

Make a version's input/output surface a first-class, comparable value.

- [x] `Nspark.VersionDiff.contract(snapshot)` → returns
      `%{"variables" => %{name => %{"required" => true, "refs" => [node_id]}},
      "outputs" => [...], "provider" => "anthropic"|nil}`. Pure module
      (`lib/nspark/version_diff.ex`), accepts the canonical snapshot map **or** a
      bare node list; tolerates atom- and string-keyed nodes.
- [x] Variable extraction is now defined **once** as
      `Nspark.VersionDiff.variables_in/1` (the `~r/\{([a-zA-Z_]\w*)\}/` regex);
      `Diagnostics.vars_in_node/1` delegates to it, so the contract and the
      `:undefined_variable` check can never disagree.
- [x] Outputs come from agent-node `metadata["output_var"]` (blank/non-agent
      filtered, deduped). Implemented inline in `VersionDiff` rather than reusing
      `Diagnostics.agent_output_vars/1` (private; equivalent logic) to keep
      `VersionDiff` free of a `Diagnostics` dependency.
- [x] `input_contract :map` (non-null, default `%{}`, `public?`) added to
      `GraphVersion`; `publish_graph/5` computes `VersionDiff.contract(snapshot)`
      and freezes it on the version. Migration
      `20260616192952_add_graph_version_input_contract` via `mix ash.codegen`.
- [x] `input_contract` is `public?`, so the default version read action / API
      returns it for client-side input validation. (Provider is `nil` until the
      publish path pins one — Phase 3.)
- [x] Tests: `test/nspark/version_diff_test.exs` — extraction (order, dupes,
      non-binary), variables across nodes with refs, dedup, no-content nodes,
      agent outputs, provider echo, bare-list + empty snapshot. Full suite green
      (46 tests).

## Phase 2 — Diff engine + classification (deterministic core)

- [x] `Nspark.VersionDiff.diff(old_snapshot, new_snapshot)` returns
      `%{"level", "variables" => %{"added","removed","renamed"}, "outputs" =>
      %{"added","removed"}, "provider", "nodes", "reasons"}`. `level` is driven
      by the contract deltas; per-node changes never exceed `:cosmetic` alone.
- [x] Node matching is by stable `id`. Rename heuristic: a removed var and an
      added var referenced by the **identical set of node ids** are paired as a
      `renamed` and classed **breaking** (refs-based, deterministic — both sides
      are breaking anyway, so this only sharpens the human-facing reason).
- [x] `level` is the max severity across the variable/output/provider deltas
      (`breaking > compatible > cosmetic`); ambiguous cases resolve to the
      stricter side.
- [x] Per-node content change emits a JSON-safe line-level diff
      (`%{"added_lines","removed_lines"}`). **Deviation from spec:** used
      `List.myers_difference/2` over split lines rather than
      `String.myers_difference/2` — the latter is grapheme-level; line-level is
      what the review UI needs and tuples-free output stays JSON-serializable for
      Phase 3 storage. The engine returns the change *kind* + payload; UI renders.
- [x] Tests: `test/nspark/version_diff_test.exs` `diff/2` block — one per
      classification row (new var, rename, dropped output, removed var, provider
      change, content-only, node add, retype), max-severity precedence, identical
      → cosmetic/empty, and node-remove-with-contract-delta. Full suite green
      (57 tests).

## Phase 3 — Publish-time gate

Wire the engine into `Architecture.publish_graph/5`.

- [x] `publish_graph/6` (new optional `opts` arg) computes
      `diff_against_previous/3` — `versions_for_graph!` → latest →
      `VersionDiff.diff(latest.graph_snapshot, new)`.
- [x] `input_contract` (Phase 1) and `diff_summary` (`:map`, non-null, `public?`)
      persisted on the new version. Migration
      `20260616194630_add_graph_version_diff_summary` via `mix ash.codegen`.
- [x] Breaking diff gated in the domain: `gate_breaking/2` returns
      `{:error, {:breaking_change, diff}}` without `acknowledge_breaking: true`,
      and `{:error, {:changelog_required, diff}}` if acknowledged with a blank
      `:changelog`. On block, no version is created and `graph_version` is not
      bumped (gate runs before the transaction). The studio publish handler shows
      a clear flash listing the first reasons; the **`data-confirm` ack +
      changelog input UI is Phase 4**.
- [x] First publish (no prior version) → `diff_summary = %{"level" => "initial"}`
      (a string, so it never matches the atom `:breaking` gate); ungated.
- [x] Tests: `test/nspark/architecture/version_diff_publish_test.exs` — first
      publish initial/ungated, compatible clean, breaking blocked w/o ack (no
      version created), ack-without-changelog rejected, ack+changelog publishes
      (changelog trimmed, `diff_summary` frozen). Full suite green (62 tests).

## Phase 4 — Studio diff / version-history view

Surface the diff where governance reviews happen.

- [x] Version-history panel: each row shows a class badge
      (`⚠ breaking` / `~ compatible` / `· cosmetic` / `★ initial`) read straight
      from the stored `diff_summary` via `version_badge_class/label` — no recompute.
- [x] Per-row "Diff" button opens a viewer modal showing that version's stored
      `diff_summary` (vs predecessor), with a **"Compare against" version select**
      that recomputes `VersionDiff.diff/2` on demand for arbitrary A↔B. Renders
      reasons, the variable/output contract delta (add/remove/rename chips), the
      provider delta, and the per-node change list with the line-level content
      diff. `normalize_diff/1` unifies stored (string) and recomputed (atom)
      shapes so the template renders both.
- [x] Node-change rows are click-to-select when the node still exists in the
      current draft (`node_in_draft?/2` → `select_node`), disabled otherwise.
- [x] **Completes the Phase 3 gate UX:** a breaking publish opens an
      acknowledge + changelog modal (`@breaking_publish`); submitting re-publishes
      with `acknowledge_breaking: true` + the changelog. A blank changelog is
      rejected inline (`{:changelog_required, …}`). Replaces the interim flash.
- [x] Verified live in the studio against a seeded two-version graph (v1 initial,
      v2 breaking: +`{company}` +`{account_id}`). Badges, the diff modal (reasons
      / variable chips / line diff), and the compare dropdown all render. Full
      suite green (62 tests); `mix compile` clean.

## Phase 5 — NL change summary (scoped out, documented)

Routing the structured `diff_summary` through an LLM to produce a one-paragraph
"what changed and who's affected" note is a **thin optional layer** over the
deterministic core — same posture as the Skill registry's scoped-out NL
front-end. Do **not** build it this phase; the machine-checkable contract gate is
the reliable product. Note it here so the idea isn't re-derived from scratch.

---

## Notes

- Ash rules: never hand-write migrations — `mix ash.codegen` to generate,
  `mix ash.migrate` to run. New attributes land on `GraphVersion`
  (`input_contract`, `diff_summary`).
- Shared variable-extraction regex must be factored out of `Diagnostics` so the
  contract, the diff, and the `:undefined_variable` check use one definition.
- `provider` on the contract assumes the publish path knows the target provider;
  if a version is provider-agnostic at publish, omit the provider delta rather
  than guessing.
- Keep `Nspark.VersionDiff` pure and free of Ash so it stays unit-testable and
  reusable for the on-demand "compare A↔B" read path.
- Relationship to other plans: this is the **P1** counterpart to the Knowledge
  Layer's `resolved_skills` work (`plans/knowledge-layer-skill-registry.md`),
  which already pins *which skills* a version froze; this pins *what contract* a
  version exposes and *how it changed*.
