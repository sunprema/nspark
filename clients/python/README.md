# Newtonian Spark — Python Client

Fetch governed, versioned prompts from a Newtonian Spark service at runtime.
The client is built for the critical path: pinned versions are cached forever,
moving aliases revalidate cheaply, outages fall back to the last-known-good
copy, and variables are validated against the published contract before they're
substituted.

## Install

```bash
pip install nspark
```

## Quick start

```python
from nspark import Client

client = Client("https://nspark.example.com", api_key="nsk_…")

# Pin an exact version (recommended in production — immutable, cached forever).
prompt = client.get_prompt("support-agent", version=5)

# Validate variables against the version's contract, then substitute.
text = prompt.render({"task": "Issue a refund"})

# One-shot fetch + render:
text = client.render("support-agent", {"task": "Issue a refund"}, version=5)
```

### Resolving a version

```python
client.get_prompt("support-agent", version=5)                  # exact pinned version
client.get_prompt("support-agent", version="@latest")          # highest published
client.get_prompt("support-agent")                             # also @latest
client.get_prompt("support-agent", environment="production")   # whatever is live in prod
```

`version` and `environment` are mutually exclusive.

## Caching & last-known-good

The client caches every response and uses it two ways:

- **Pinned versions** (`?version=N`) are returned by the server as `immutable`,
  so after the first fetch the client serves them from cache with **no network
  call**.
- **Moving aliases** (`@latest`, environment) are revalidated with
  `If-None-Match`; a `304 Not Modified` re-serves the cached body.
- **On an outage** (connection error or `5xx`), the client returns the last
  successfully fetched copy instead of raising. Check `prompt.from_cache` to
  tell a fresh result from a fallback.

By default the cache lives in-process. For last-known-good that survives
restarts — the usual production choice for a critical-path dependency — back it
with a directory:

```python
from nspark import Client, FileCache

client = Client(
    "https://nspark.example.com",
    api_key="nsk_…",
    cache=FileCache("/var/cache/nspark"),
)
```

## Variable validation

Each published version exposes an input contract (the set of `{variables}` the
prompt references). `render()` validates against it before substituting:

```python
prompt.render({"task": "refund"})            # ok
prompt.render({})                            # raises MissingVariablesError(['task'])
prompt.render({"task": "x", "tsak": "y"})    # raises UnknownVariablesError(['tsak'])
prompt.render({"task": "x", "tsak": "y"}, strict=False)  # ignores the extra
```

This is what stops a renamed or dropped variable upstream from silently
producing a malformed prompt in your app.

## Errors

All exceptions derive from `nspark.NsparkError`:

| Exception                 | When                                              |
| ------------------------- | ------------------------------------------------- |
| `AuthenticationError`     | Key missing/invalid/revoked/expired (401/403)     |
| `PromptNotFoundError`     | Unknown slug, or no version matches (404)          |
| `RateLimitError`          | Rate limit exceeded (429); `.retry_after` seconds  |
| `ServiceUnavailableError` | Fetch failed **and** no cached copy to fall back to |
| `MissingVariablesError`   | A required variable wasn't supplied               |
| `UnknownVariablesError`   | A supplied variable isn't in the contract (strict) |
| `APIError`                | Any other unexpected HTTP response                |

## Configuration

```python
Client(
    base_url,
    api_key,
    timeout=5.0,        # per-request seconds
    max_retries=2,      # retries on network error / 5xx / 429 before fallback
    backoff=0.2,        # base seconds for exponential backoff
    cache=None,         # defaults to InMemoryCache; pass FileCache for durable LKG
    session=None,       # bring your own requests.Session
)
```

## Development

```bash
pip install -e ".[test]"
pytest
```
