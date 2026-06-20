# Design Memo — Two-Layer, Mode-Aware Canvas + Static Lens

Status: brainstorm → proposed direction
Date: 2026-06-19
Artifacts produced alongside this memo:
- `PROMPT_LANGUAGE_SPEC.md`, `JSON_IR.md`, `USAGE_RULES.md` — the PromptBasic language, IR, and runtime contract
- `PROMPT_BASIC_EXAMPLE1.md` (logistics, flat) and `PROMPT_BASIC_RMA.md` (returns, stateful) — worked examples
- `promptbasic_engine.exs` — shared Parser + Selector (one parser used by both tools below)
- `lens_analyzer.exs` — runnable static-analysis pass (`elixir docs/pivot/lens_analyzer.exs <file>`)
- `rma_tests.exs` — runnable Test-layer scenario suite (`elixir docs/pivot/rma_tests.exs`)
- `llm_compliance.exs` — real-LLM compliance harness (`mix run`; needs `ANTHROPIC_API_KEY`)

---

## 1. The thesis (revised through brainstorming)

The original framing was "PromptBasic gives **deterministic** agent execution." That claim is
false and we should not ship it. Condition evaluation (`[WHEN] shipment_lost`) is still an LLM
judgment; we cannot make the model behave deterministically.

The honest, defensible thesis is narrower and stronger:

> **Structure makes a prompt inspectable. Inspectable prompts get tooling. Prose gets none.**

We are not promising the LLM behaves perfectly. We are making the **author's intent** a queryable
object instead of an opaque paragraph. Everything of value flows from one property: `[WHEN]`,
`[TOOL]`, `[STATE]`, `[PRIORITY]` are **extractable tokens**.

Reach vs. moat:
- **Format = reach.** Plain markdown with bracket tokens is grep-able and works inside any model
  (Claude Code, Cursor, raw API) with zero runtime via the `USAGE_RULES.md` injection. Land here.
- **Lens + builder + IR = moat.** The static analyzer, the visual builder, and the JSON IR are the
  paid layer. Expand here.

This is not a pivot away from Newtonian Spark — it is the **missing control layer** under the
existing visual-architecture vision. It (a) gives the canvas a reason to exist, (b) makes prompts
inspectable, (c) feeds the LLM cleaner structure. Three threads collapse into one model + one IR.

---

## 2. Why the current node flows feel weak

Today's nodes are **composition**: content blocks joined in sequence. A linear/DAG composition of
prompt fragments is something a **text editor with headings does better** — faster to type, easier
to diff and read. A canvas that lays out "block A then B then C" is strictly worse than markdown.

Visual builders only earn their existence when the thing they draw is **branching**. Conditional
rules + priority + state transitions are exactly what is painful in text and natural on a canvas.
Adopting the rule model gives the canvas its first real reason to exist.

---

## 3. The two-layer model

Do **not** force everything into rules. Two node kinds:

```
┌─ CONTEXT LAYER (always in prompt) ───────────────────────────┐
│  identity · tone · domain knowledge   ← today's content blocks │  kept as-is
└───────────────────────────────────────────────────────────────┘
┌─ CONTROL LAYER (conditional) ────────────────────────────────┐
│  states = the graph ; rules = flat cards inside a state ;      │  the new thing
│  priority = vertical stack order (top wins)                    │
└───────────────────────────────────────────────────────────────┘
```

- **Context nodes** — existing model, retained. Always-on content. Not everything is a decision.
- **Rule nodes** — `[WHEN] → actions`. **Flat**, no nested control flow.
- **States** — the directed graph. Edges are `[STATE]` transitions. The genuinely graph-native part.
- **Priority** — vertical position within a state.

### Why this avoids the visual-programming spaghetti trap
General node-based programming dies of spaghetti once you draw nested loops/conditionals as wires.
PromptBasic survives because **rules are flat** — a prioritized decision table, not a flowchart.
Flat rules + a small set of states stay readable as they grow. Do not ever add nested branches
inside a rule; that property is the whole reason the canvas works.

---

## 4. Mode-aware rendering (the key UX decision)

The two examples proved the canvas should adapt to the *kind* of agent:

| Agent kind | Example | What carries the value | What to render |
|---|---|---|---|
| **Flat / decision-table** | logistics (1 state, 9 rules) | the **priority stack** | priority ladder; skip state ceremony |
| **Stateful / wizard** | RMA (7 states, 14 rules) | the **state machine** | full state graph + per-state stacks |

Same IR underneath, same lens, **two renderings**. The builder should detect which kind is being
authored (essentially: is there more than one state?) and not impose state ceremony on flat agents.

---

## 5. The static lens — what is sound, heuristic, or not static

Empirically established by running `lens_analyzer.exs` on both examples. This boundary is the most
important engineering output of the brainstorm.

### Sound (deterministic, zero-LLM, CI-gate, ship with confidence)
- Condition inventory + semantic-vs-memory split (and literal-phrase smell)
- **Dead state** — state entered via `[STATE]` but no rule reads `[WHEN] state = X`
- **Dead / write-only memory** — declared-but-unused, or written-but-never-read
- Tool inventory — declared vs invoked (unused / undeclared)
- **Output-reference resolution** — `{{tool:X}}` must be produced in the same rule
- Priority ties — flagged; benign when conditions are provably mutually exclusive
- Unreachable rules — lower-priority rule whose atom set ⊇ a higher-priority rule's
- Complementary-modeling smell — `X` / `not_X` modeled as independent atoms

These found **real defects we missed by hand**, e.g. the dead `last_carrier` memory in logistics
and the dead `escalated` state in RMA.

### Heuristic (ship as 🟡 "review", never a 🔴 hard error)
- **Priority preemption / collision.** The naive "two rules can both match" check is useless: with
  independent boolean atoms almost any two rules co-occur (it flagged **25** on logistics). Narrowing
  to *adjacent priority + both multi-condition AND rules + different sections* cut it to **4** and
  kept the one real bug. It can still miss and over-flag — hence advisory only.

### NOT a sound static property (belongs to the Test/eval layer, not the linter)
- **Full input-space coverage** over semantic atoms ("delayed without a tracking number is
  unhandled", "wants_repair offered but no rule"). This needs an *intended-behavior* spec or an
  LLM-assisted scenario generator. Do not pretend the parser can decide it.

### Headline empirical finding
The **flat** logistics agent needed a noisy collision heuristic; the **stateful** RMA agent had
**zero** collisions because `state =` guards make rules provably mutually exclusive.
**The architecture that is better for the visual builder is also the architecture that is better
for static analysis.** Those are the same win.

---

## 6. The Test layer — BUILT, and what it proved

Implemented in `rma_tests.exs` on top of `PromptBasic.Selector` (a deterministic rule-selection
engine in `promptbasic_engine.exs`). A scenario declares the slice of intended behavior the parser
cannot infer — `given {state, memory, true conditions} → expect {fires, state_to, tool, handled}` —
and the Selector runs **real** priority resolution, state-guard matching, and memory comparison.
No LLM: it tests the agent's *logic structure*, including where inputs silently drain to `[OTHERWISE]`.

Result on the RMA agent: **10 pass · 3 coverage gaps · 0 regressions.** The 3 gaps are precisely the
semantic holes the static lens structurally **cannot** see (no malformed token to flag):
- `wants_repair` — offered in a `[RESPOND]` ("refund, replacement, or repair") but no rule exists → drains.
- escalated user asks for an update — proves the statically-flagged dead `escalated` state strands a
  **real runtime message**, not just an abstract smell.
- inspection passes when resolution was repair — downstream consequence of the first gap.

Bonus precision demonstrated: the Selector surfaces **tie resolution** (`wants_refund` +
`wants_replacement` → `tie [R6,R7] → R6 wins`, the concrete outcome behind the lens's 🟡 tie flag),
and it caught a **bug in a hand-written test expectation** before it could ship green.

### The division of labour, now demonstrated end-to-end (not asserted)

| | Static Lens | Test layer |
|---|---|---|
| Finds | dead state, dead memory, unreachable, tie *existence*, ref/tool resolution | intended inputs that drain, tie *resolution*, transition/tool correctness |
| Needs | nothing (parse tree) | an intended-behavior spec (scenarios) |
| `escalated` | flags it is dead (static) | proves a real message strands the user (runtime) |
| `wants_repair` | **invisible** (no bad token) | **caught** |

This confirms the boundary Section 5 predicted: the lens is the X-ray; the Test layer is the
behavioural assertion. They are complementary, not redundant.

---

## 6b. LLM-compliance finding (decides format-first vs engine)

The open question "who evaluates `[WHEN]`?" was tested empirically with `llm_compliance.exs`:
feed `claude-opus-4-8` the `USAGE_RULES` contract + the rendered RMA program (with rule ids) +
each scenario as a natural-language message, and diff its chosen rule against the Selector oracle.

Result (2026-06-19), 11 RMA scenarios: **11/11 = 100% agreement** with the oracle. (First run
showed 9/9 with 2 cold-start `Req` transport timeouts; after adding a 300s timeout + transient
retry, the clean re-run was 11/11.) Most important: **both coverage-gap scenarios returned
`OTHERWISE`** — the model did NOT invent un-authored rules for `wants_repair` or the escalated
follow-up. It respected the rule set's boundaries.

Implication: **format-first is viable.** A model reliably follows the injected contract on this
program, including refusing to hallucinate behavior. So the strategy holds — ship the language +
lens + tests as the works-anywhere layer with a light runtime; reserve the code-driven Selector
engine for deployments that need hard determinism (it already exists as the Test-layer oracle).
Caveat: one program, one model, happy-ish paths — widen to adversarial inputs and more programs
before treating 100% as the durable number.

---

## 7. Pipeline

```
visual builder ──▶ JSON IR ──▶ [ static lens ]  ──▶ rendered prompt + USAGE_RULES contract ──▶ LLM
                     ▲              │                                                          │
                     └─ normalized ─┘  (lint in CI)        [ Test layer: Selector + scenarios ]
                                                            (deterministic; runs in CI too)
```

The thing you draw, the thing you lint, the thing you test, and the thing the LLM runs are **one
object** (the IR). The lens and the Test layer share **one parser** (`promptbasic_engine.exs`).
This matches the existing graph-persistence model (JSON while editing → normalized rows on save):
the IR *is* the normalized form.

---

## 8. Honest risks / open questions

- **DSL adoption tax.** People resist bracket syntax (our own examples have inconsistent
  indentation). Mitigated only if authoring happens mostly in the graph, not the text.
- **Bracket language vs Spark DSL.** We have deep Spark expertise; Spark already compiles a DSL to
  validated structured data. Open question: is the bracket language the product, or sugar over a
  Spark DSL? (Bracket = friendlier to non-engineers + grep-able; Spark = validation for free.)
- **Who evaluates `[WHEN]`?** Tested (§6b): on the RMA program `claude-opus-4-8` agreed with the
  Selector 11/11 and refused to invent rules for the gaps — so format-only is viable here. Still
  decide per deployment: format-only (cheap, model self-interprets) vs engine (code selection, hard
  determinism). Widen the eval to adversarial inputs / more programs before treating format-only as
  safe everywhere.
- **Density.** A single state with 30 rules becomes a scroll. Collapse/group by `#` section heading
  must be first-class.
- **Scope honesty.** This is a real re-architecture of the node model (two node kinds, states as
  edges, priority as layout). It pays off only when authors have branching agents. Simple always-on
  assistants live entirely in the context layer.

---

## 9. Recommended build order

Prototyped (runnable in `docs/pivot/`):
- [x] PromptBasic language + IR + runtime contract (specs)
- [x] Shared parser + deterministic Selector (`promptbasic_engine.exs`)
- [x] Sound static lens (`lens_analyzer.exs`)
- [x] Test layer: Selector + scenario suite (`rma_tests.exs`) — proved the lens/Test boundary
- [x] LLM-compliance harness (`llm_compliance.exs`) — 11/11 = 100% agreement on RMA (§6b)

Still to build (product):
1. Keep context nodes. Add **rule + state nodes** as a second canvas layer.
2. Wire the **lens** findings to node badges; run it as a CI pass.
3. Make rendering **mode-aware** (flat → priority ladder, stateful → state graph).
4. Wire the **Test layer** to the canvas: green/red dots per rule, a "drains" counter on
   `[OTHERWISE]`, and a one-click "add rule for this scenario" affordance per gap.
5. **LLM-backed scenario generator** — propose intended-behavior scenarios automatically instead of
   hand-writing them. This is the bridge from "linter for engineers" to "coverage tool for authors."
6. Treat preemption/collision as advisory 🟡, never a hard gate.
7. Defer the deterministic runtime engine; ship format + lens + Test first (reach), upsell the visual
   builder + IR (moat). Note the Selector built for the Test layer is already the core of that engine.
