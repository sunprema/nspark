# Newtonian Spark — TypeScript Client

Fetch governed, versioned prompts from a Newtonian Spark service at runtime.
Built for the critical path: pinned versions are cached forever, moving aliases
revalidate cheaply, outages fall back to the last-known-good copy, and variables
are validated against the published contract before they're substituted.

Works in Node 18+ (uses the global `fetch`) and any runtime that provides a
`fetch` implementation. `FileCache` is Node-only; in the browser, supply your
own `Cache`.

## Install

```bash
npm install nspark
```

## Quick start

```ts
import { Client } from "nspark";

const client = new Client("https://nspark.example.com", "nsk_…");

// Pin an exact version (recommended in production — immutable, cached forever).
const prompt = await client.getPrompt("support-agent", { version: 5 });

// Validate variables against the version's contract, then substitute.
const text = prompt.render({ task: "Issue a refund" });

// One-shot fetch + render:
const text2 = await client.render("support-agent", { task: "Issue a refund" }, { version: 5 });
```

### Resolving a version

```ts
await client.getPrompt("support-agent", { version: 5 });               // exact pinned version
await client.getPrompt("support-agent", { version: "@latest" });       // highest published
await client.getPrompt("support-agent");                               // also @latest
await client.getPrompt("support-agent", { environment: "production" }); // whatever is live in prod
```

`version` and `environment` are mutually exclusive.

## Caching & last-known-good

The client caches every response and uses it two ways:

- **Pinned versions** (`{ version: N }`) come back from the server as
  `immutable`, so after the first fetch they're served from cache with **no
  network call**.
- **Moving aliases** (`@latest`, environment) are revalidated with
  `If-None-Match`; a `304 Not Modified` re-serves the cached body.
- **On an outage** (network error or `5xx`), the client returns the last
  successfully fetched copy instead of throwing. Check `prompt.fromCache` to
  tell a fresh result from a fallback.

By default the cache lives in-process. For last-known-good that survives
restarts — the usual production choice for a critical-path dependency — back it
with a directory (Node only):

```ts
import { Client, FileCache } from "nspark";

const client = new Client("https://nspark.example.com", "nsk_…", {
  cache: new FileCache("/var/cache/nspark"),
});
```

## Variable validation

Each published version exposes an input contract (the set of `{variables}` the
prompt references). `render()` validates against it before substituting:

```ts
prompt.render({ task: "refund" });                       // ok
prompt.render({});                                       // throws MissingVariablesError(["task"])
prompt.render({ task: "x", tsak: "y" });                 // throws UnknownVariablesError(["tsak"])
prompt.render({ task: "x", tsak: "y" }, { strict: false }); // ignores the extra
```

This stops a renamed or dropped variable upstream from silently producing a
malformed prompt in your app.

## Errors

All exceptions derive from `NsparkError` (use `instanceof`):

| Error                     | When                                                 |
| ------------------------- | ---------------------------------------------------- |
| `AuthenticationError`     | Key missing/invalid/revoked/expired (401/403)        |
| `PromptNotFoundError`     | Unknown slug, or no version matches (404)             |
| `RateLimitError`          | Rate limit exceeded (429); `.retryAfter` seconds      |
| `ServiceUnavailableError` | Fetch failed **and** no cached copy to fall back to  |
| `MissingVariablesError`   | A required variable wasn't supplied                  |
| `UnknownVariablesError`   | A supplied variable isn't in the contract (strict)   |
| `APIError`                | Any other unexpected HTTP response                   |

## Configuration

```ts
new Client(baseUrl, apiKey, {
  timeoutMs: 5000,   // per-request timeout
  maxRetries: 2,     // retries on network error / 5xx / 429 before fallback
  backoffMs: 200,    // base ms for exponential backoff
  cache,             // defaults to InMemoryCache; pass FileCache for durable LKG
  fetch,             // custom fetch implementation (defaults to global fetch)
});
```

## Development

```bash
npm install
npm test        # vitest
npm run build   # emit dist/ (ESM + .d.ts)
```
