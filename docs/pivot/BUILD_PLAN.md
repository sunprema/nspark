# PromptBasic — Build Plan (start next session)

Companion to `DESIGN_MEMO_two_layer_lens.md`. The memo is the *why*; this is the *what/where*,
sequenced and grounded in the actual app. Brainstorm is done; prototypes in `docs/pivot/` prove
every claim. This plan promotes them into the product.

## Guiding principles (settled)

- **Ship format-first.** Language + lens + tests as the works-anywhere layer; the code-driven
  Selector engine is held in reserve for hard-determinism deployments. (LLM compliance: 11/11 on RMA.)
- **Lens-first value.** The static X-ray is the most convincing, lowest-risk win — build it before
  the fancy canvas. It found real defects on day one.
- **One IR.** The thing you draw, lint, test, and (optionally) run is one object. The IR is the
  normalized form of the existing graph (see [[graph-persistence-model]]).
- **Mode-aware canvas.** Flat agents → priority ladder; stateful agents → state graph. Don't impose
  state ceremony on flat agents. (See [[studio-canvas-architecture]].)
- **Honest scope.** Don't market determinism. The lens makes *intent* legible; the LLM stays fuzzy.

## Existing assets

Prototypes (runnable, `docs/pivot/`):
- `promptbasic_engine.exs` — `PromptBasic.Parser` + `PromptBasic.Selector`
- `lens_analyzer.exs` — `PromptBasic.Analyzer` (static lens)
- `rma_tests.exs` — Test-layer scenario suite
- `llm_compliance.exs` — real-LLM compliance harness (11/11 on RMA)
- specs: `PROMPT_LANGUAGE_SPEC.md`, `JSON_IR.md`, `USAGE_RULES.md`
- examples: `PROMPT_BASIC_EXAMPLE1.md` (flat), `PROMPT_BASIC_RMA.md` (stateful)

App structure (real targets):
- Domain `Nspark.Architecture`: `graph.ex`, `graph_version.ex`, `node.ex`, `node_type.ex`
- Web: `lib/nspark_web/live/studio_live.ex`, `lib/nspark_web/controllers/api/graph_controller.ex`
- Svelte: `assets/svelte/` — `GraphCanvas.svelte`, `ConditionalNode.svelte` (already started!),
  `AgentNode.svelte`, `BlueprintNode.svelte`, `CodeEditor.svelte`, `FlowBridge.svelte`

## Decisions — SETTLED (2026-06-19)

1. **Authoring surface for v1.** ✅ **Graph is source of truth** (per studio-canvas-arch);
   IR is compiled *from* the graph; bracket PromptBasic text is import/export only. (Defers the
   bracket-vs-Spark-DSL question — see memo §8.)
2. **Where the IR lives.** ✅ IR is a **derived compiled artifact** — `compile/1` computes it from
   the `GraphVersion` snapshot on demand; **no new attribute/table, no migration**. Persist later
   only if recompute cost ever matters. `Nspark.PromptBasic.IR.to_json/from_json` is the JSON form.
3. **Module namespace.** ✅ `Nspark.PromptBasic.*` — plain modules, not Ash resources.

---

## Phase 0 — Promote the engine into the app  ✅ DONE

Goal: the proven prototypes become first-class, tested `lib/` code.
- [x] Created `lib/nspark/prompt_basic/{parser,selector,analyzer}.ex` from the `.exs` prototypes
  (`Nspark.PromptBasic.*` namespace per decision 3). `ir.ex` deferred to Phase 1.
- [x] Ported `rma_tests.exs` scenarios + the lens findings into `test/nspark/prompt_basic/*_test.exs`
  as ExUnit assertions (dead-state, dead/write-only-memory, ties, preemption, 13 selector scenarios
  incl. the 3 coverage gaps and the R6/R7 tie). Fixtures copied to `test/support/fixtures/prompt_basic/`.
- [x] Kept the `.exs` scripts as-is for quick experiments; the `lib/` versions are canonical.
- **DoD met:** `mix test test/nspark/prompt_basic/` → 20 tests, 0 failures. Lens + selector behavior
  reproduced as assertions.

## Phase 1 — IR + compile paths  ◐ PARTIAL (Producer A done; Producer B → Phase 3)

Goal: one IR, two producers.
- [x] Define the IR as a struct in `Nspark.PromptBasic.IR` (fields mirror the parse tree so an
  `%IR{}` is a drop-in for the lens/selector). `to_json/1` + `from_json/1` give a lossless,
  `Jason`-safe persistence form (atom enums → strings, `:otherwise` → `"otherwise"`,
  `mem_writes` tuples → `%{key,value}` maps).
- [x] Producer A: bracket text → IR (`IR.from_text/1`, via the Parser). Tested.
- [ ] **Producer B: `Graph` (nodes/edges) → IR — DEFERRED to Phase 3.** It needs the `rule`/`state`
  node model that Phase 3 introduces; today's node types have no rule/priority/state semantics to
  compile, so a faithful `compile/1` has nothing to read. Building it now would be throwaway.
- [x] Persistence settled as **derive-on-demand** (decision #2) — no snapshot field added.
- **DoD (Producer A side met):** parse `PROMPT_BASIC_RMA.md` → IR; round-trip through JSON; run the
  lens on the IR (identical findings to the raw parse map). Graph→IR side moves to Phase 3.

## Phase 1b — graph → IR compiler  ✅ DONE (with Phase 3 backend)
- [x] `Nspark.PromptBasic.Compiler.from_graph/3`: graph nodes → `%IR{}`. It **assembles canonical
  bracket source from the graph and parses it through the proven Parser**, so graph→IR provably
  yields the same IR shape as text→IR. `to_source/3` doubles as the Phase 5 exporter.
- [x] Canvas-structure mapping: priority = `metadata["priority"]` (vertical order), `[OTHERWISE]` =
  `metadata["otherwise"]`, section = `metadata["section"]`, doc order = `metadata["order"]`; the
  `[WHEN]`/actions body lives in the node `content` (one source of truth for state guards/transitions).
- **DoD met:** `compiler_test.exs` asserts `from_graph(nodes) == IR.from_text(equivalent_source)`,
  plus structure extraction, mode detection, string-key tolerance, and muted exclusion.

## Phase 2 — Lens in the Studio  ✅ DONE

Goal: the X-ray, live in `/studio`.
- [x] `Nspark.PromptBasic.Lens.diagnostics/1` runs the lens over the graph's IR and resolves each
  finding to the **graph node id** it affects (dead state → state node, dead/write-only memory →
  memory node, unresolved ref / unreachable / undeclared tool → rule node, unused tool → tool node,
  ambiguous tie + preemption → rule nodes). Returns the existing `Nspark.Diagnostics` shape.
- [x] Wired into `refresh/1` — appended to the diagnostics list, so it drives both the **findings
  panel** (severity-grouped, click-to-select) and **per-node badges** (rule/state/memory/tool cards
  already render `diag-error`/`diag-warning` borders) with **zero extra plumbing**.
- [x] Severity model honored: 🔴 dead state / unresolved ref / unreachable / undeclared tool;
  🟡 dead+write-only memory / unused tool; preemption + ambiguous ties advisory 🟡 only.
- [x] `check_floating` now ignores rule/state nodes (transitions live in the rule body, not edges),
  removing false "excluded from compile order" noise.
- [x] **DoD met (verified by screenshot):** opening the seeded RMA graph shows `1 error · 4 warnings`
  live — the dead `escalated` state badges red on the node + panel; write-only `order_id` warns.

## Phase 3 — Two-layer, mode-aware canvas  ◐ BACKEND DONE; canvas remaining

Goal: the control layer the canvas was missing.
- [x] `NodeType` entries for `rule` and `state` (additive enum values; **no migration** — `type` is a
  plain `:text` column, confirmed via `mix ash.codegen --check`). Existing nodes stay the context layer.
- [x] `IR.states/1` + `IR.mode/1` — `:flat` (≤1 state → priority ladder) vs `:stateful` (>1 → state
  machine). Backs the mode-aware render decision.
- [x] `RuleNode.svelte` (rule cards: priority badge, section, `when` expr, action chips for
  tools/memory/respond/ask/transition) + `StateNode.svelte` (state pill with START badge for init).
  Registered in `GraphCanvas.svelte`; `:rule`/`:state` added to the palette + `to_flow_nodes` data.
- [x] Mode-aware indicator driven by `IR.mode/1` (computed in `studio_live` via the Compiler, passed
  as a canvas prop): flat → "PRIORITY LADDER", stateful → "STATE MACHINE · N states".
- [x] **DoD met (verified by screenshot):** the seeded RMA graph renders as a state machine (3 states,
  START badge, transition chips); the logistics graph renders as a flat priority ladder (P10/P8/P6).
- [x] **Polish done:** priority derived from vertical drag (`node_moved` re-ranks rule priorities by
  canvas y, top wins; `[OTHERWISE]` excluded — verified: y-order → P30/P20/P10). Inspector editing for
  rule priority/section/`[OTHERWISE]` + the rule body editor, and state `initial` toggle
  (`update_control_metadata`). Derived (non-persisted) edges from the IR: solid transition edges
  (rule `[STATE]` → state) + dashed containment edges (`when state = X` → rule), so the state machine
  is visually connected. `Compiler.rule_id_to_node_id/1` shared by the lens + edge derivation.
- [ ] **Deferred:** true nested state containers (SvelteFlow parent/extent) — containment is shown via
  dashed edges for now.

## Phase 4 — Test layer in the Studio

Goal: catch the gaps the lens can't (memo §6).
- Scenario editor (state + memory + true conditions + expected) persisted per graph.
- Run via `Selector`; per-rule green/red dots; a "drains" counter on the `[OTHERWISE]` node.
- "Add rule for this scenario" affordance on each drained gap.
- **DoD:** define scenarios in UI, run, see pass/gap, one-click scaffold a rule for a gap.

## Phase 5 — Format-first export  ✅ DONE

Goal: the works-anywhere deliverable.
- [x] `Nspark.PromptBasic.Export`: `render/2` bundles a self-contained execution contract (the
  validated `USAGE_RULES` injection, condensed) with the rendered program (`Compiler.to_source/3`);
  `program/2` / `contract/0` for the parts. Exports from node `content`, so re-export is faithful
  (no IR round-trip → the parser atom-order quirk never bites here).
- [x] Studio: a **"Copy PromptBasic"** button in the Live Compiler controls (reuses the
  `CopyToClipboard` hook), shown whenever the graph has a control layer.
- [x] Endpoint: `GET /api/v1/graphs/:graph_id/promptbasic` → downloadable `text/plain`
  (`<slug>.promptbasic.md`), mirroring the `compile` action's tenant/auth resolution.
- **DoD met (verified live):** the logistics graph exports a ready-to-paste contract + program
  block; `export_test.exs` asserts the bundle + that the exported program re-parses to the same IR.

---

## Cross-cutting research track — widen the eval (memo §6b caveat)

Before trusting format-only beyond Opus + happy paths, extend `llm_compliance.exs`:
- adversarial / multi-condition messages (does priority resolution hold?)
- larger rule sets (the density case — where accuracy usually degrades)
- a cheaper model (Haiku/Sonnet) — if it only holds on Opus, the cost story changes
Run as needed; it gates how aggressively format-only ships vs. when the engine becomes mandatory.

## Out of scope (for now)

- The deterministic runtime engine as a product surface (Selector exists; defer productizing).
- Bracket-language-as-primary authoring / Spark DSL question (revisit after the graph-first v1).
- Multi-agent orchestration (already PARKED per [[product-positioning]]).

## Start-of-next-session checklist

1. Settle the 3 decisions above (5 min).
2. Phase 0: scaffold `lib/nspark/prompt_basic/` + tests from the prototypes.
3. Then Phase 2 (lens in Studio) — fastest path to a visible, defensible win.
