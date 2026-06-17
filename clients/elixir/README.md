# Newtonian Spark — Elixir Client

Fetch governed, versioned prompts from a Newtonian Spark service at runtime.
Built for the critical path: pinned versions are cached forever, moving aliases
revalidate cheaply, outages fall back to the last-known-good copy, and variables
are validated against the published contract before they're substituted.

## Install

```elixir
def deps do
  [{:nspark, "~> 0.1"}]
end
```

## Quick start

```elixir
cache = Nspark.Cache.Memory.new()
client = Nspark.new("https://nspark.example.com", "nsk_…", cache: cache)

# Pin an exact version (recommended in production — immutable, cached forever).
{:ok, prompt} = Nspark.get_prompt(client, "support-agent", version: 5)

# Validate variables against the version's contract, then substitute.
{:ok, text} = Nspark.Prompt.render(prompt, %{"task" => "Issue a refund"})

# One-shot fetch + render:
{:ok, text} = Nspark.render(client, "support-agent", %{"task" => "Issue a refund"}, version: 5)
```

Create the client once (e.g. in your application's supervision tree or as a
cached term) and reuse it — the `Nspark.Cache.Memory` ETS table is owned by the
process that called `new/0`, so build it somewhere long-lived.

### Resolving a version

```elixir
Nspark.get_prompt(client, "support-agent", version: 5)              # exact pinned version
Nspark.get_prompt(client, "support-agent", version: "@latest")      # highest published
Nspark.get_prompt(client, "support-agent")                          # also @latest
Nspark.get_prompt(client, "support-agent", environment: "production") # whatever is live in prod
```

`:version` and `:environment` are mutually exclusive.

## Caching & last-known-good

The client caches every response and uses it two ways:

- **Pinned versions** (`version: n`) come back from the server as `immutable`,
  so after the first fetch they're served from cache with **no network call**.
- **Moving aliases** (`@latest`, environment) are revalidated with
  `If-None-Match`; a `304 Not Modified` re-serves the cached body.
- **On an outage** (network error or `5xx`), the client returns the last
  successfully fetched copy instead of erroring. Check `prompt.from_cache` to
  tell a fresh result from a fallback.

The default cache is per-process (`Nspark.Cache.Memory`, ETS). For
last-known-good that survives restarts — the usual production choice for a
critical-path dependency — use the file-backed cache:

```elixir
cache = Nspark.Cache.File.new("/var/cache/nspark")
client = Nspark.new("https://nspark.example.com", "nsk_…", cache: cache)
```

`Nspark.Cache` is a protocol, so you can back it with anything (e.g. Redis) by
implementing `get/2` and `put/3`.

## Variable validation

Each published version exposes an input contract (the set of `{variables}` the
prompt references). `render/3` validates against it before substituting
(variable keys may be strings or atoms):

```elixir
Nspark.Prompt.render(prompt, %{"task" => "refund"})        # {:ok, "…"}
Nspark.Prompt.render(prompt, %{})                          # {:error, %Nspark.Error.MissingVariables{missing: ["task"]}}
Nspark.Prompt.render(prompt, %{"task" => "x", "tsak" => 1}) # {:error, %Nspark.Error.UnknownVariables{unknown: ["tsak"]}}
Nspark.Prompt.render(prompt, %{"task" => "x", "tsak" => 1}, strict: false) # ignores the extra
```

`Nspark.Prompt.render!/3` raises instead of returning `{:error, _}`.

This stops a renamed or dropped variable upstream from silently producing a
malformed prompt in your app.

## Errors

Tuple-returning functions answer `{:error, error}`; `!` variants raise the same
struct. All live under `Nspark.Error`:

| Error                            | When                                                 |
| -------------------------------- | ---------------------------------------------------- |
| `Nspark.Error.Auth`              | Key missing/invalid/revoked/expired (401/403)        |
| `Nspark.Error.NotFound`          | Unknown slug, or no version matches (404)            |
| `Nspark.Error.RateLimit`         | Rate limit exceeded (429); `:retry_after` seconds    |
| `Nspark.Error.ServiceUnavailable`| Fetch failed **and** no cached copy to fall back to  |
| `Nspark.Error.MissingVariables`  | A required variable wasn't supplied                  |
| `Nspark.Error.UnknownVariables`  | A supplied variable isn't in the contract (strict)   |
| `Nspark.Error.API`               | Any other unexpected HTTP response                   |

## Configuration

```elixir
Nspark.new(base_url, api_key,
  cache: Nspark.Cache.Memory.new(),  # default; pass Nspark.Cache.File for durable LKG
  timeout_ms: 5_000,                 # per-request timeout
  max_retries: 2,                    # retries on network error / 5xx / 429 before fallback
  backoff_ms: 200                    # base for exponential backoff
)
```

The HTTP backend is [Req](https://hex.pm/packages/req). To swap it (or stub it
in tests) pass `request_fun:` — a 4-arity function
`(method, url, headers, opts) -> {:ok, %{status:, headers:, body:}} | {:error, term}`.

## Development

```bash
mix deps.get
mix test
```
