# Plan — Semantic Graph Diff & Breaking-Change Detection

Source: `LIVE_PROMPT.md` brainstorm (the "prompt tree + diffing" idea, salvaged
into the pull-based product) + product-positioning **P1 — variable/version
contract**.
Status: **Phase 1 complete** — contract extraction shipped; Phases 2–5 pending.
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

- [ ] `Nspark.VersionDiff.diff(old_snapshot, new_snapshot)` → 
      ```elixir
      %{
        "level" => :breaking | :compatible | :cosmetic,
        "variables" => %{"added" => [...], "removed" => [...], "renamed" => [%{from,to}]},
        "outputs"   => %{"added" => [...], "removed" => [...]},
        "provider"  => %{"from" => "...", "to" => "..."} | nil,
        "nodes"     => [%{"id"=>, "label"=>, "change"=> :added|:removed|:retyped|:content}],
        "reasons"   => ["new required variable :foo", ...]   # why it's breaking
      }
      ```
- [ ] Node matching is by stable node `id` (snapshots preserve ids). A var
      `removed` + `added` of equal count where the *only* difference is the name
      is reported as a `renamed` heuristic and classed **breaking** (conservative).
- [ ] `level` is the max severity across all deltas; unknown → breaking.
- [ ] Per-node content change uses a line-level diff (use Elixir's
      `String.myers_difference/2` — stdlib, no dep) to produce a compact
      added/removed line summary for the UI; the engine returns the change *kind*
      and the diff payload, the UI renders it.
- [ ] Tests: one test per classification row in Decisions; plus identical
      snapshots → `:cosmetic`/empty, and full-version add/remove of nodes.

## Phase 3 — Publish-time gate

Wire the engine into `Architecture.publish_graph/5`.

- [ ] After `serialize_snapshot`, load the latest existing `GraphVersion` for the
      graph; compute `contract(new)` and `diff(old.graph_snapshot, new)`.
- [ ] Persist `input_contract` and `diff_summary` (`:map`) on the new version.
      Migration via `mix ash.codegen`.
- [ ] If `level == :breaking`: block publish unless the caller passes an explicit
      acknowledgement, **and require a `changelog`** naming the break — reuse the
      `data-confirm` blast-radius pattern from the Skill modal. The confirm text
      lists the offending fields from `diff.reasons`.
- [ ] First publish (no prior version) → `diff_summary` is `nil`/`:initial`; no
      gate.
- [ ] Tests: breaking publish blocked without ack; allowed with ack + changelog;
      compatible publish passes clean; first publish ungated.
      (`test/nspark/architecture/version_diff_publish_test.exs`.)

## Phase 4 — Studio diff / version-history view

Surface the diff where governance reviews happen.

- [ ] Version-history panel: each version row shows a class badge
      (`⚠ breaking` / `~ compatible` / `· cosmetic`) read straight from the
      stored `diff_summary` — no recompute.
- [ ] "Compare" affordance between any two selected versions → a side panel
      showing the contract delta (added/removed variables & outputs) and the
      per-node change list with the line-level content diff.
- [ ] Breaking rows link to the named fields/nodes (jump-to-node where the
      version is the current draft's ancestor).
- [ ] Verify live in the studio against a real two-version graph.

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
