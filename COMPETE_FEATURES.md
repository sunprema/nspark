# Newtonian Spark — Competitive Differentiators

What we must build to **win, not match**. Reference positioning in
NEXT_STEPS.md; this doc is narrower: the features that make us a differentiator,
not the table-stakes parity list.

Competitors store prompts as **text/templates** (Humanloop, Langfuse,
PromptLayer, Vellum, Braintrust). LaunchDarkly is our delivery-layer analogy,
not a competitor.

## The one rule

> **Every must-have here exploits our single structural advantage: a prompt is a
> typed graph, not a text blob.**

If a feature would be equally easy for a text-template product to ship, it is
parity, not a differentiator — it goes in the short table-stakes list at the
bottom, not the focus list. We win on what you *can't* do to a string.

**Legend:** ✅ seeded in codebase · 🟡 partial · ⬜ to build

---

## Differentiator 1 — Enforced input contract (derived, not declared)

**The moat.** Because the graph knows its `{variables}` by structure, we can
*derive* a typed input schema per published version and **enforce** it. A
text-template product can't — the contract is buried in prose, so a careless
edit silently breaks a live app. This is our single strongest wedge.

- 🟡 Variable diagnostics (undefined/unused) already exist in studio.
- ⬜ Derive a required-variable input schema on publish; store on the snapshot.
- ⬜ Expose the schema via the retrieval endpoint; SDK validates before use.
- ⬜ **Breaking-change detection**: diff a new version's required variables vs the
  live-deployed version; warn/block when a consumed variable is removed/renamed.
- ⬜ Surface "this change breaks deployment X (prod)" in studio *before* publish.

> Competitor gap: they can lint text for `{{handlebars}}`, but they cannot tell
> you a change will break a *specific running consumer* — they don't model the
> consumer or the contract.

---

## Differentiator 2 — Reusable prompt components (DRY for prompts)

**The moat.** The registry makes Skills / Policies / Schemas / Memory templates
first-class assets that *link* into graphs (`Node.source_asset_id`). Update a
compliance policy once → every agent that links it updates. Competitors
copy-paste prompt text, so the same guardrail is duplicated across 50 prompts
and drifts.

- ✅ Registry resources + linked nodes (`source_asset_id`) + package install.
- ⬜ **Propagation**: editing a linked asset flags/updates every consuming graph
  (and shows which versions are affected).
- ⬜ Asset versioning + pinning (a graph pins asset v2; opt-in upgrade to v3).
- ⬜ "Detach / convert to local" already exists — add "re-link to registry" too.

> Competitor gap: text tools have snippets at best; they can't guarantee a single
> source of truth for a reused guardrail across an org's whole prompt fleet.

---

## Differentiator 3 — Impact analysis / dependency graph

**The moat.** Everything is linked (nodes ↔ variables ↔ registry assets ↔
deployments), so we can answer the question every enterprise governance team
asks and no text tool can: **"If I change this, what breaks?"**

- 🟡 Variable explorer (producers/consumers, dependency path) is the seed.
- ⬜ Cross-asset impact: "this Policy is used by 12 graphs, 4 in production."
- ⬜ Reverse lookup from a deployment: "what assets/variables does prod depend on?"
- ⬜ Blast-radius view at the approval step (see Differentiator 5).

> Competitor gap: with prompts as opaque strings, "find everything affected by
> this change" is a full-text grep with no guarantees.

---

## Differentiator 4 — Prompt linting (structural correctness)

**The moat.** We parse structure, so we can catch classes of bug a spellchecker
on a string never will: cycles, floating nodes, missing persona/output,
conflicting/duplicate instructions, undefined variables.

- ✅ Diagnostics panel: cycle, floating, persona/output cardinality, var checks.
- ⬜ Conflict detection: contradictory or duplicated instructions across nodes.
- ⬜ Severity gating: block publish on errors, warn on advisories.
- ⬜ Expose lint results via API/CI so a prompt change fails a pipeline, like code.

> Competitor gap: they validate that a template *renders*; we validate that the
> agent's *design* is internally coherent.

---

## Differentiator 5 — Structural review & promotion

**The moat.** A version diff that shows *"added a constraint, removed a required
variable, changed the output schema"* — semantic, not a text wall. This makes the
human approval gate meaningful, which is the heart of the enterprise governance
pitch.

- ✅ Audit trail (`ash_paper_trail`) + RBAC underpin this.
- ⬜ **Structural diff** between two `GraphVersion`s (nodes/edges/vars/contract),
  not just text.
- ⬜ Promotion workflow dev → staging → prod with approval gated on role.
- ⬜ Diff + impact (Differentiator 3) shown together at the approval step.

> Competitor gap: text diff tells a reviewer *what characters changed*; we tell
> them *what behavior and which consumers changed*.

---

## Differentiator 6 — Write once, target many models

**The moat.** The same graph compiles to provider-specific formats
(Anthropic/OpenAI/Gemini) behind one abstraction. A text prompt is hand-tuned to
one model; ours is portable by construction.

- 🟡 Provider transforms exist in the compiler (Anthropic wrap; others passthrough).
- ⬜ Real per-provider tokenization + accurate cost estimate (today it's a
  char-count heuristic — fix the claim or the code).
- ⬜ Per-provider format depth (system/developer roles, tool blocks, caching hints).
- ⬜ "Compare across providers" view: same graph, three rendered outputs + costs.

> Competitor gap: most store the final string; portability across models is the
> author's manual problem, not the platform's.

---

## Differentiator 7 — Evaluation tied to structure

**The moat.** Attach test cases to a graph and **gate publish on eval**, where
"good" is behavioral. Combined with the contract (Differentiator 1), publishing
can require *both* a valid contract and a passing eval suite — a guarantee a
loose text store can't make.

- ⬜ Test cases (input variables → asserted output) attached to a graph.
- ⬜ Pre-publish eval run + score; block/warn on regression.
- ⬜ Deterministic asserts first (contains/regex/JSON-schema), then LLM-as-judge.
- ⬜ Eval score carried in version history so reviewers see quality before promote.

> Note: this is the most *contested* area (Braintrust/Humanloop are strong here),
> so our edge is the **integration** — eval gated by the same structured publish
> that enforces the contract — not eval as a standalone feature.

---

## Table-stakes (must reach, but NOT our differentiator)

Necessary to be credible; don't over-invest, don't lead with them.

- ✅ Versioning, RBAC, multi-tenancy, audit trail.
- ⬜ Runtime delivery: pinned fetch, caching, SDK, last-known-good fallback,
  scoped API keys, rate limiting (this is *reliability* table-stakes — see P0).
- ⬜ Basic observability of runtime requests.

---

## Deliberately NOT competing on (focus discipline)

- **Being an agent runtime / orchestration engine.** The moment we *execute*
  chained model calls we leave our defensible lane and fight LangChain et al.
  Multi-agent orchestration stays **parked** (see NEXT_STEPS.md).
- **Being a model gateway / proxy.** We deliver and validate prompts; we are not
  an inference router.
- **Generic prompt logging/analytics as a primary product.** Useful, commoditized,
  not where we win.

---

## If we only ship three

1. **Enforced input contract + breaking-change detection** (Diff. 1) — uniquely
   ours, directly prevents the customer's worst outage.
2. **Impact analysis** (Diff. 3) — the governance buyer's signature question.
3. **Reusable components with propagation** (Diff. 2) — DRY across a prompt fleet,
   the clearest "text files can't do this" story.

These three share one substrate (the linked graph) and one pitch: *we manage the
prompt fleet as a connected system, not a folder of strings.*
