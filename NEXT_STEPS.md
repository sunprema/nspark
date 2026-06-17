# Newtonian Spark — Next Steps

Status snapshot and prioritized backlog. Reflects the codebase as of 2026-06-16.

## Positioning (read this first)

Newtonian Spark is a **prompt externalization + governance platform for the
enterprise**. The job: get prompts out of hardcoded strings buried in
application code and into a managed service where they can be **versioned,
validated, governed, and fetched at runtime**. The calling application asks our
service for "the prompt for version X" and injects its own runtime variables.

This is the "LaunchDarkly for prompts" category (peers: Humanloop, Langfuse,
PromptLayer, Vellum, Braintrust). The buyer is a platform/governance team that
curates prompts many apps depend on.

**Three things sell this product. Everything else is supporting cast:**

1. **Reliable runtime delivery** — apps fetch prompts from us in their critical
   path. Pinned versions, caching, graceful degradation, an SDK.
2. **A strict variable/version contract** — a prompt edit must never silently
   break a calling app. Each published version exposes an input schema the client
   validates against.
3. **Real evaluation** — "is this prompt good?" must mean behavioral testing
   (test cases, regression runs, scoring), not just static lint.

The visual graph + compiler + diagnostics are the right *substrate* for (2) and
(3) — a structured graph can publish a contract and attach tests in a way a text
file never could. That's the moat. Lean into it.

---

## Where we are

**Domains (Ash, attribute multitenancy on `organization_id`):**

- `Nspark.Accounts` — `Organization`, `User`/`Token`, `Membership` (per-org
  `Role`), `Invitation` (invite-only). Auth resources are global.
- `Nspark.Projects` — `Project`.
- `Nspark.Architecture` — `Graph`, `Node`, `Edge`, `GraphVersion` + type enums.
- `Nspark.Registry` — `Skill`, `Policy`, `Schema`, `MemoryTemplate`, `Package`,
  `PackageItem` + `AssetStatus`.
- `Nspark.Deployments` — `Deployment` (pinned `GraphVersion` → environment).

**Studio (`/studio`):** editable Svelte Flow canvas, CodeMirror content editor,
live compiler panel (MDEx render), diagnostics panel, registry browser, AI
Architect (Oban + Claude), org switching, members/invitations management.

**Runtime API:** `POST /api/v1/graphs/:id/compile`,
`POST /api/v1/deployments/:id/run` (bearer token, tenant from membership).

**Tests:** `compiler_test.exs`, `studio_live_test.exs` only. The
orchestrator, diagnostics, RBAC, and API have no tests (see REVIEW_COMMENTS.md).

**Decisions of record:** CodeMirror (edit) + MDEx (render); graph persistence =
JSON-while-editing → normalized rows on save → JSON snapshot on publish;
multi-org via `Membership`, invite-only. See `docs/HLD.md`.

---

## ⏸ Parked — Multi-agent orchestration (was Priority 5)

**Decision: freeze.** Phases 1–2 shipped (agent nodes, conditional routing,
wave dispatch, `Orchestrator`). It is the largest, least-tested part of the
codebase and it is **not what the enterprise buyer is paying for**. We are not
investing further until the core registry story (P0–P2 below) is airtight.

Before parking, close the one correctness landmine so it can't ship a wrong
result silently:

- [x] Nested agents no longer fail silently — `Orchestrator.dispatch_one/3`
  compiles a sub-agent snapshot and now parses it for `[AGENT: …]` directives; if
  the sub-graph itself contains agent nodes it returns an explicit error
  (`on_error` still decides halt-vs-degrade) instead of leaking raw directive text
  into the parent output. Also fixed a latent crash in `parse/1`: a directive with
  no optional `when:` clause yields 7 regex captures, not 8, and used to raise.
  Covered by `test/nspark/orchestrator_test.exs`. (Full Phase 3 stays parked.)

Phase 3 items (hierarchical orchestration, depth limits, execution trace,
cross-graph inspector) remain in the backlog but **below** everything in P0–P3.

---

## P0 — Runtime delivery (the product is in the customer's critical path)

If our service is slow or down, the customer's app breaks. Enterprise will not
accept that. `/compile` returning a string is the seed; it needs a real delivery
contract around it.

- [x] **Pinned-version retrieval endpoint** — `GET /api/v1/prompts/:slug?version=N`
  (and `@latest` / environment alias e.g. `@production`, or `?environment=production`).
  Returns the resolved prompt + its input schema + version metadata + a strong
  ETag (with `If-None-Match`/304 + immutable `Cache-Control` on pinned versions).
  This, not `/run`, is the primary product surface. Slug is a stable per-org
  identifier on `Graph`, auto-derived from name. Resolver:
  `Nspark.PromptDelivery`; controller: `NsparkWeb.Api.PromptController`.
  Still on bearer-token auth — scoped keys (next item) will replace it.
- [x] **Scoped API keys** per project/environment (not just a user bearer token);
  key issuance + revocation UI; audit of API access. Global `Nspark.Accounts.ApiKey`
  (hashed secret; org + optional project + optional environment scope), `NsparkWeb.ApiKeyAuth`
  plug on the `:api_runtime` pipeline (key is the principal; env-scoped keys are
  limited to their env alias), admin-only `/org/api-keys` management screen
  (issue → show plaintext once, revoke). Audit via `created_by`/`revoked_by`/
  `last_used_at` columns. (A per-request access log is still future work.)
- [ ] **Caching + delivery** — strong ETag / `Cache-Control`, immutable pinned
  versions are infinitely cacheable; document a CDN-frontable contract.
- [x] **Client SDK** (Python `clients/python/`, TypeScript `clients/typescript/`,
  Elixir `clients/elixir/`) — `Client` fetches by pinned version, caches locally
  (immutable pinned versions cached forever; moving aliases revalidated via
  `If-None-Match`/304), **falls back to last-known-good on our outage**
  (in-memory by default, durable via a file-backed cache), and validates
  injected variables against the published input contract before substituting
  (`Prompt.render`). Honors `429`/`retry-after` with retries+backoff. ~19 tests
  each (Python `responses`; TS vitest + fetch stub; Elixir ExUnit + injected
  request fn). TS runs on Node 18+/any `fetch` runtime; Elixir uses Req with a
  `Nspark.Cache` protocol for pluggable backing stores.
- [x] **Rate limiting** on `/api/v1/*` (per key / per org). Dependency-free ETS
  fixed-window limiter (`Nspark.RateLimiter`, supervised, atomic `update_counter`
  + periodic sweep) behind the `NsparkWeb.RateLimit` plug on both API pipelines.
  Buckets by API key → user → IP; emits `x-ratelimit-*` headers and `429` +
  `retry-after`. Limits configurable (`config :nspark, NsparkWeb.RateLimit`).
- [ ] Define and publish a retrieval **SLA / latency budget**; add a health/
  readiness endpoint.

---

## P1 — The variable / version contract (largely shipped)

A prompt edit that renames or drops a variable must not silently break a
deployed app. The graph already knows its variables — publish that as a contract.
**Most of this shipped** in the semantic-graph-diff work (Phases 1–4) plus the
client SDKs; the contract is the single source of truth `Nspark.VersionDiff`,
which `Nspark.Diagnostics` also delegates to so the studio lint and the published
contract can never disagree.

- [x] **Published input schema per `GraphVersion`** — `VersionDiff.contract/1`
  derives the required `{variables}` (and their referencing node ids) on publish
  and freezes them on `GraphVersion.input_contract`; the retrieval endpoint
  returns it as `input_schema` (`PromptController`).
- [x] **Optional variables** — a `{var}` referenced only by conditional-branch
  targets is marked `required: false` (conservative: any unconditional reference
  ⇒ required). `diff/2` treats a new optional var as compatible and an
  optional→required flip ("tightened") as breaking. (Gap B.)
- [x] **Client-side validation** — Python/TS/Elixir SDKs validate supplied
  variables against `input_schema` and raise (`MissingVariablesError` &c.) before
  substituting; they honor `required: false`.
- [x] **Breaking-change detection on publish** — `Architecture.publish_graph/6`
  diffs against the previous published version and gates a `:breaking` change
  behind `acknowledge_breaking: true` + a changelog. This protects `@latest`
  consumers (publishing advances `@latest`).
- [x] **Breaking-change detection on deploy** — `Architecture.deploy_impact/3`
  diffs the version being deployed against what the target **environment** is
  currently serving (`Deployments.active_deployment_for/3`); the studio deploy
  flow gates a breaking promotion behind an explicit ack, attributing the break
  to that environment ("breaks `@production`, currently v1"). This is the real
  "breaks deployment X (prod)" guard — env aliases only change at deploy time,
  not at publish. (Gap A.)
- [x] **Compatibility surfacing in studio** — breaking-publish and breaking-deploy
  gate modals list the contract reasons before the author proceeds.
- [x] Diagnostics agree with the contract by construction — `Diagnostics` derives
  its input-contract summary straight from `VersionDiff.contract/1`. The old
  producer/consumer `undefined`/`unused` variable *warnings* were removed: they
  encoded a closed-system model (Context/Memory nodes "define" values) that
  contradicts the externalized-prompt model (every `{var}` is a runtime input the
  caller supplies), so a well-formed graph lit up with false positives for its own
  public API. They are replaced by a single informational `:input_contract` line
  ("N runtime variables — R required, O optional") that mirrors the published
  contract exactly.

**Remaining (Gap C — deferred):** typed variable shapes. v1 treats every
variable as a string; "where typed, the expected shape" needs a way for a node to
*declare* a variable's type (a node-schema + studio UX change), so it is a
feature, not a gap — nobody is blocked on it. Also outstanding: a per-request API
access log (noted under P0) and test backfill for the runtime API controllers.

---

## P2 — Evaluation: "is this prompt good?"

Today "good" means static lint (parses, vars defined). Enterprise prompt
management means *behavioral* good. This is currently the weakest area and the
most differentiating to fix.

- [ ] **Test cases attached to a graph** — `(input variables → expected /
  asserted output)` examples stored per graph.
- [ ] **Run-on-edit / pre-publish eval** — execute the prompt against test cases
  (via a model call) and score; block or warn on regression.
- [ ] **Scoring** — start with deterministic asserts (contains / regex / JSON
  schema match), then add LLM-as-judge scoring.
- [ ] **A/B + version comparison** — run two versions against the same suite and
  diff results.
- [ ] **Eval results in version history** — a version carries its eval score so
  reviewers see quality before promoting.

---

## P3 — Governance & promotion workflow

RBAC + audit trail (`ash_paper_trail`) already exist. The missing piece is a
human approval gate — the "external way of checking prompts" implies sign-off.

- [ ] **Environment promotion** — explicit dev → staging → production flow;
  publishing ≠ going to prod.
- [ ] **Publish-to-prod approval** — who can promote to production (gate on role,
  e.g. admin+); require review/approval before a prod deployment activates.
- [ ] **Change review / diff** — show a structural + text diff of what changed
  between versions at the approval step.
- [ ] Distinguish *execute* from *read* on the runtime API — a `viewer` token can
  currently run any deployment in its org (see REVIEW_COMMENTS.md).

---

## P4 — Hardening (cross-cutting, do alongside P0–P3)

- [ ] **Test backfill** — Orchestrator, Diagnostics, RBAC policies, runtime API
  controllers (see REVIEW_COMMENTS.md for the specific cases).
- [ ] **Structured orchestration/compile artifact** — stop re-parsing the
  `[AGENT: …]` text with a regex; carry directives as structured data. (Relevant
  even with orchestration parked, because the compile→text→regex round trip is
  fragile for *any* downstream consumer.)
- [ ] Replace the char-count token heuristic with real per-provider tokenization,
  or correct the NEXT_STEPS/PRD claim that says it's done.
- [ ] Move hardcoded provider model names + pricing (`compiler.ex`) to config.
- [ ] Promote `GraphVersion.author_id` (loose uuid) to a managed `belongs_to`.
- [ ] Decompose the 1709-line `StudioLive` into components/handler modules.

---

## Completed foundations (record)

These shipped and underpin the work above. Kept for history.

- Active-org session + tenant resolution; `:live_user_and_tenant_required`.
- RBAC: `Ash.Policy.Authorizer` + `HasRole` check across product resources.
- Invitation delivery + accept flow; members management screen.
- Deployments domain; publish → `GraphVersion` snapshot; compile/run API.
- Three-tier graph persistence (draft rows → version snapshot → pinned deploy).
- Compiler: topo ordering within sections, provider transforms, cost estimate.
- Diagnostics panel: DAG validation, variable + output diagnostics.
- Variable explorer interactions; registry-in-studio (linked nodes, packages).
- AI Architect (NL → graph) via Oban + Claude `claude-opus-4-8`.
- Audit trail (`ash_paper_trail`) on graph/skill/deployment changes.
- Multi-agent Phases 1–2 (now parked — see above).

---

## Known cleanups / notes

- `mdex` is a NIF dep — a brand-new dep requires a **dev-server restart**.
- Demo data: `mix run priv/repo/demo_seed.exs` (idempotent).
- `mix ash.reset` to clear dev sanity-check rows.
- `handle_event/3` grouping warning in `studio_live.ex` — pre-existing; resolves
  naturally when StudioLive is decomposed (P4).
