# Newtonian Spark — Architecture Review

Reviewer: Architect pass over the codebase as of 2026-06-16, re-ranked against
the product positioning: **enterprise prompt externalization + governance**
(apps fetch versioned, validated, governed prompts from the service at runtime —
"LaunchDarkly for prompts"). Items are action items — check them off as
addressed. See NEXT_STEPS.md for the sequenced backlog.

**Legend:** 🔴 high (blocks the positioning / correctness / security) ·
🟡 medium · 🟢 low/polish

---

## What's working well (keep doing this)

- [x] Clean domain separation with consistent attribute multitenancy on
  `organization_id`.
- [x] RBAC factored into a single reusable `Nspark.Checks.HasRole` check with a
  sensible role hierarchy and per-process memoization.
- [x] Audit trail (`ash_paper_trail`) on graph/skill/deployment — the spine of
  the governance story.
- [x] AI Architect offloaded to Oban — the LiveView never blocks on the model.
- [x] Three-tier persistence (draft rows → immutable `GraphVersion` snapshot →
  pinned `Deployment`) is the right substrate for runtime delivery.
- [x] Variable diagnostics (undefined/unused) already exist — the seed of the
  variable contract that the product needs (see 🔴 below).

---

## 🔴 High priority — blocks the core positioning

### Runtime delivery is the product, and it's underbuilt
If apps fetch prompts from us at runtime, our service sits in the customer's
critical path. Today `/compile` returns a string with no delivery contract.

- [ ] Add a **pinned-version retrieval endpoint** (`GET /prompts/:slug?version=`,
  `@latest`, env aliases) returning prompt + input schema + ETag. This, not
  `/run`, is the primary product surface.
- [ ] **Scoped API keys** per project/environment with issuance/revocation —
  a single user bearer token (`router.ex:19-23`) is not an enterprise auth model.
- [ ] **Client SDK** that caches locally and **falls back to last-known-good on
  our outage**. Without this, our downtime = customer downtime.
- [ ] Caching headers (immutable pinned versions are infinitely cacheable);
  rate limiting on `/api/v1/*`; health/readiness endpoint.

### The variable contract is the single biggest correctness risk
Apps inject `{variables}`. A prompt edit that renames/drops a variable silently
breaks the calling app in production. The graph already knows its variables —
publish them as an enforced contract.

- [ ] On publish, derive the required-variable set for the `GraphVersion` and
  store it on the snapshot; expose via the retrieval endpoint.
- [ ] SDK validates injected variables against that schema **before** use.
- [ ] **Breaking-change detection on publish** — diff required variables vs the
  live-deployed version; warn/block when a consumed variable disappears.
- [ ] Surface "this change breaks deployment X (prod)" in studio before publish.

### Evaluation ("is this prompt good?") barely exists
"Good" today means static lint. Enterprise prompt management means behavioral
testing — and this is the most differentiating gap to close.

- [ ] Attach **test cases** (input variables → asserted output) to a graph.
- [ ] Run-on-edit / pre-publish eval with scoring; block/warn on regression.
- [ ] Carry eval score in version history so reviewers see quality before
  promoting.

### Test coverage does not match a "production-grade" claim
The most complex/critical modules have **zero tests**.

- [ ] `Orchestrator` (358 lines of concurrency) — parsing, wave grouping,
  parallel dispatch, timeout, `on_error`, conditional skip.
- [ ] `Diagnostics` (364 lines) — every check.
- [ ] RBAC policies — assert viewer/editor/admin/owner boundaries actually deny.
- [ ] Runtime API — 401 (no token), 404 (cross-tenant), 422 (inactive), happy
  path; `Architect.apply_to_graph/4` with a mocked HTTP layer.

---

## 🟡 Medium priority

### Governance has no human approval gate
RBAC + audit exist, but "an external way of checking prompts" implies sign-off,
and there's no promotion workflow.

- [ ] Environment promotion (dev → staging → prod); publishing ≠ prod.
- [ ] Publish-to-prod approval gated on role; change diff at the approval step.
- [ ] Distinguish **execute** from **read** on the runtime API — today a
  `viewer` token can run any deployment in its org (`deployment_controller.ex`
  only enforces read via `Ash.get(..., actor: user)`).

### The compile → text → regex orchestration protocol is fragile
`Compiler.agent_directive/3` (`compiler.ex:233`) serializes to a `[AGENT: …]`
text block that `Orchestrator` re-parses with one whitespace-sensitive regex
(`orchestrator.ex:44`). No shared schema, no round-trip test.

- [ ] Carry the orchestration/compile plan as **structured data** alongside the
  display markdown, instead of recovering it by regex. (Matters for any
  downstream consumer, even with orchestration parked.)

### Orchestration is parked — close the silent-failure first
Per the positioning, multi-agent orchestration is frozen (see NEXT_STEPS). But
it can currently ship a wrong result silently:

- [ ] `Orchestrator.dispatch_one/3` (`orchestrator.ex:268`) compiles a sub-agent
  snapshot without re-orchestrating it, so a nested agent leaks raw `[AGENT: …]`
  text into the parent output. Detect agent nodes in a sub-agent snapshot and
  return an explicit error. (Full Phase 3 stays parked.)

### `find_with_tenant/3` does N queries per request
Both API controllers (`graph_controller.ex:42`, `deployment_controller.ex:67`)
loop over every membership with one `Ash.get` per org until a match.

- [ ] Resolve tenant from the resource or an explicit `org_id`/scoped key;
  validate membership once. (Folds into scoped API keys above.)

### Condition evaluation is a hand-rolled string mini-language
`Orchestrator.evaluate_condition/2` (`orchestrator.ex:304`) — no AND/OR, no
parens, no numeric comparison; negation logic duplicated in
`Compiler.build_when_expr/2` (`compiler.ex:277`).

- [ ] Extract one shared condition module (parse + evaluate); test the operator
  matrix; reject unsupported expressions loudly. (Lower urgency while parked.)

### `StudioLive` is a 1709-line module
- [ ] Decompose into LiveComponents / per-concern handler modules; resolves the
  acknowledged `handle_event` grouping warning.

---

## 🟢 Low priority / polish

- [ ] "Real tokenizer per provider" is **not** implemented — still
  `String.length / chars_per_token` (`compiler.ex:75`). Implement it or correct
  the NEXT_STEPS/PRD claim.
- [ ] Provider model names + pricing are hardcoded and stale (`compiler.ex:26-30`:
  "Claude 3.5 Sonnet", "GPT-4o", "Gemini 1.5 Pro"). Move to config.
- [ ] Verify `thinking: %{type: "adaptive"}` (`architect.ex:96`) is valid for the
  model; documented shape is `%{type: "enabled", budget_tokens: N}`. With
  thinking on, `max_tokens: 4096` may be tight for larger graphs.
- [ ] `GraphVersion.author_id` is a bare uuid — promote to a managed
  `belongs_to :user` now that membership is formalized.
- [ ] `secret_key_base` / `token_signing_secret` are committed literals in
  `config/dev.exs`. Dev-only, but document that prod must use the env path.
- [ ] On `:brutal_kill` timeout, confirm a late task result can't leak back into
  the awaiting process.

---

## Suggested sequencing

1. **Variable contract + breaking-change detection** (P1) — biggest correctness
   risk to live apps; the graph substrate makes it uniquely doable here.
2. **Runtime delivery contract** (P0) — pinned retrieval, scoped keys, SDK with
   last-known-good fallback.
3. **Evaluation** (P2) — test cases + pre-publish scoring; the differentiator.
4. **Governance promotion + execute-vs-read auth** (P3).
5. **Hardening** — test backfill, structured compile artifact, the orchestration
   silent-failure fix, then refactors. Multi-agent Phase 3 stays parked.
