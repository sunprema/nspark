/**
 * The Newtonian Spark runtime client.
 *
 * A calling application fetches a published prompt by its stable slug, pins a
 * version (or follows `@latest` / an environment alias), and injects its own
 * variables. The client is built for the critical path:
 *
 * - **Pinned versions are cached forever.** The server marks `?version=N`
 *   immutable, so after the first fetch the client never hits the network.
 * - **Moving aliases revalidate cheaply.** `@latest` / environment lookups send
 *   `If-None-Match`; a `304` re-serves the cached body for free.
 * - **Outages fall back to last-known-good.** If the service is unreachable or
 *   returns 5xx, the client serves the last good copy instead of throwing
 *   (`prompt.fromCache` tells them apart).
 * - **Variables are validated before substitution**, against the version's
 *   published input contract.
 *
 * ```ts
 * import { Client } from "nspark";
 *
 * const client = new Client("https://nspark.example.com", "nsk_…");
 * const prompt = await client.getPrompt("support-agent", { version: 5 });
 * const text = prompt.render({ task: "Issue a refund" });
 * ```
 */

import { type Cache, type CacheEntry, InMemoryCache } from "./cache.js";
import {
  APIError,
  AuthenticationError,
  PromptNotFoundError,
  RateLimitError,
  ServiceUnavailableError,
} from "./errors.js";
import { Prompt, type PromptPayload, type RenderOptions, type Variables } from "./models.js";

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export interface ClientOptions {
  /** Per-request timeout in milliseconds. Default 5000. */
  timeoutMs?: number;
  /** Retries on transient failure (network / 5xx / 429) before fallback. Default 2. */
  maxRetries?: number;
  /** Base milliseconds for exponential backoff between retries. Default 200. */
  backoffMs?: number;
  /** Backing cache. Defaults to a per-process {@link InMemoryCache}. */
  cache?: Cache;
  /** Custom fetch implementation (defaults to global `fetch`). */
  fetch?: FetchLike;
}

export interface GetPromptOptions {
  /** Exact pinned version, or `"@latest"`. */
  version?: number | string;
  /** Resolve whatever version is live in this environment. */
  environment?: string;
}

const DEFAULTS = { timeoutMs: 5000, maxRetries: 2, backoffMs: 200 };

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Synchronous-style async client for the prompt-retrieval API. */
export class Client {
  private readonly baseUrl: string;
  private readonly apiKey: string;
  private readonly timeoutMs: number;
  private readonly maxRetries: number;
  private readonly backoffMs: number;
  private readonly cache: Cache;
  private readonly fetchImpl: FetchLike;

  constructor(baseUrl: string, apiKey: string, options: ClientOptions = {}) {
    if (!baseUrl) throw new Error("baseUrl is required");
    if (!apiKey) throw new Error("apiKey is required");

    this.baseUrl = baseUrl.replace(/\/+$/, "");
    this.apiKey = apiKey;
    this.timeoutMs = options.timeoutMs ?? DEFAULTS.timeoutMs;
    this.maxRetries = Math.max(0, options.maxRetries ?? DEFAULTS.maxRetries);
    this.backoffMs = options.backoffMs ?? DEFAULTS.backoffMs;
    this.cache = options.cache ?? new InMemoryCache();

    const f = options.fetch ?? (globalThis.fetch as FetchLike | undefined);
    if (!f) {
      throw new Error("no fetch implementation available; pass options.fetch");
    }
    this.fetchImpl = f;
  }

  /**
   * Fetch a prompt by slug.
   *
   * Specify at most one qualifier:
   * - `{ version: 5 }` — exact pinned version (immutable, cached forever)
   * - `{ version: "@latest" }` — highest published version (revalidated)
   * - `{ environment: "production" }` — version live in that environment
   *
   * With no qualifier the server returns `@latest`.
   */
  async getPrompt(slug: string, opts: GetPromptOptions = {}): Promise<Prompt> {
    if (opts.version !== undefined && opts.environment !== undefined) {
      throw new Error("specify either version or environment, not both");
    }

    const params = buildParams(opts);
    const key = cacheKey(slug, params);
    const cached = await this.cache.get(key);

    // An immutable (pinned-version) entry can never change; serve without I/O.
    if (cached?.immutable) {
      return Prompt.fromPayload(cached.payload, true);
    }

    return this.fetchPrompt(slug, params, key, cached);
  }

  /** Convenience: fetch a prompt and render it in one call. */
  async render(
    slug: string,
    variables: Variables = {},
    opts: GetPromptOptions & RenderOptions = {},
  ): Promise<string> {
    const prompt = await this.getPrompt(slug, opts);
    return prompt.render(variables, opts);
  }

  // ── fetch + retry + fallback ──────────────────────────────────────────────

  private async fetchPrompt(
    slug: string,
    params: URLSearchParams,
    key: string,
    cached: CacheEntry | undefined,
  ): Promise<Prompt> {
    const qs = params.toString();
    const url = `${this.baseUrl}/api/v1/prompts/${encodeURIComponent(slug)}${qs ? `?${qs}` : ""}`;

    let lastError: unknown;

    for (let attempt = 0; attempt <= this.maxRetries; attempt++) {
      let resp: Response;
      try {
        resp = await this.fetchImpl(url, this.requestInit(cached));
      } catch (err) {
        // Connection-level failure (incl. timeout abort): retry, then fall back.
        lastError = err;
        if (await this.maybeBackoff(attempt)) continue;
        break;
      }

      if (resp.status === 200) {
        return this.storeAndReturn(key, resp);
      }

      if (resp.status === 304) {
        if (cached) return Prompt.fromPayload(cached.payload, true);
        lastError = new APIError(304, "not modified but no cached entry");
        break;
      }

      if (resp.status === 401 || resp.status === 403) {
        throw new AuthenticationError(resp.status, await errorMessage(resp));
      }

      if (resp.status === 404) {
        throw new PromptNotFoundError(404, await errorMessage(resp));
      }

      if (resp.status === 429) {
        const retryAfter = retryAfterSeconds(resp);
        if (attempt < this.maxRetries) {
          await sleep(retryAfter != null ? retryAfter * 1000 : this.backoffFor(attempt));
          continue;
        }
        throw new RateLimitError(await errorMessage(resp), retryAfter);
      }

      if (resp.status >= 500 && resp.status < 600) {
        lastError = new APIError(resp.status, await errorMessage(resp));
        if (await this.maybeBackoff(attempt)) continue;
        break;
      }

      // Any other status is unexpected and not retryable.
      throw new APIError(resp.status, await errorMessage(resp));
    }

    // Every attempt failed. Serve last-known-good if we have it.
    if (cached) return Prompt.fromPayload(cached.payload, true);

    throw new ServiceUnavailableError(
      `failed to fetch prompt '${slug}' and no cached copy is available` +
        (lastError instanceof Error ? `: ${lastError.message}` : ""),
    );
  }

  private requestInit(cached: CacheEntry | undefined): RequestInit {
    const headers: Record<string, string> = {
      Authorization: `Bearer ${this.apiKey}`,
      Accept: "application/json",
    };
    if (cached?.etag) headers["If-None-Match"] = cached.etag;

    return { method: "GET", headers, signal: AbortSignal.timeout(this.timeoutMs) };
  }

  private async storeAndReturn(key: string, resp: Response): Promise<Prompt> {
    let payload: PromptPayload;
    try {
      payload = (await resp.json()) as PromptPayload;
    } catch {
      throw new APIError(200, "response was not valid JSON");
    }

    await this.cache.set(key, {
      payload,
      etag: resp.headers.get("ETag") ?? undefined,
      immutable: isImmutable(resp),
      storedAt: Date.now(),
    });

    return Prompt.fromPayload(payload, false);
  }

  private async maybeBackoff(attempt: number): Promise<boolean> {
    if (attempt < this.maxRetries) {
      await sleep(this.backoffFor(attempt));
      return true;
    }
    return false;
  }

  private backoffFor(attempt: number): number {
    return this.backoffMs * 2 ** attempt;
  }
}

// ── helpers ───────────────────────────────────────────────────────────────

function buildParams(opts: GetPromptOptions): URLSearchParams {
  const params = new URLSearchParams();
  if (opts.environment !== undefined) {
    params.set("environment", opts.environment);
  } else if (opts.version !== undefined) {
    params.set("version", String(opts.version));
  }
  return params;
}

function cacheKey(slug: string, params: URLSearchParams): string {
  if (params.has("environment")) return `${slug}@env:${params.get("environment")}`;
  if (params.has("version")) return `${slug}@version:${params.get("version")}`;
  return `${slug}@latest`;
}

function isImmutable(resp: Response): boolean {
  return (resp.headers.get("Cache-Control") ?? "").toLowerCase().includes("immutable");
}

function retryAfterSeconds(resp: Response): number | undefined {
  const raw = resp.headers.get("Retry-After");
  if (raw == null) return undefined;
  const n = Number.parseInt(raw, 10);
  return Number.isNaN(n) ? undefined : n;
}

async function errorMessage(resp: Response): Promise<string> {
  try {
    const body = (await resp.json()) as { error?: unknown };
    if (body && typeof body.error === "string") return body.error;
  } catch {
    // fall through
  }
  return `HTTP ${resp.status}`;
}
