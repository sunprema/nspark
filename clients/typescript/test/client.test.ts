import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import {
  AuthenticationError,
  Client,
  type FetchLike,
  FileCache,
  PromptNotFoundError,
  RateLimitError,
  ServiceUnavailableError,
} from "../src/index.js";

const BASE = "https://nspark.test";

function payload(version = 5, prompt = "Task: {task}") {
  return {
    slug: "support-agent",
    version,
    resolved_via: `version:${version}`,
    prompt,
    input_schema: {
      variables: { task: { required: true, refs: ["n1"] } },
      outputs: ["resolution"],
      provider: "anthropic",
    },
    metadata: { graph_name: "Support Agent" },
    stats: { token_estimate: 12 },
  };
}

interface FakeResponse {
  status: number;
  body?: unknown;
  headers?: Record<string, string>;
}

/** A fetch stub that dispenses queued responses and records request inits. */
function fakeFetch(responses: FakeResponse[]): FetchLike & { calls: RequestInit[]; urls: string[] } {
  const calls: RequestInit[] = [];
  const urls: string[] = [];
  const fn = (async (url: string, init?: RequestInit) => {
    urls.push(url);
    calls.push(init ?? {});
    const next = responses.shift();
    if (!next) throw new Error("no more queued responses");
    const bodyText = next.body === undefined ? null : JSON.stringify(next.body);
    return new Response(next.status === 304 ? null : bodyText, {
      status: next.status,
      headers: next.headers,
    });
  }) as FetchLike & { calls: RequestInit[]; urls: string[] };
  fn.calls = calls;
  fn.urls = urls;
  return fn;
}

function client(fetchImpl: FetchLike, opts = {}) {
  return new Client(BASE, "nsk_test", { fetch: fetchImpl, maxRetries: 1, backoffMs: 0, ...opts });
}

function headerOf(init: RequestInit, name: string): string | undefined {
  return (init.headers as Record<string, string>)?.[name];
}

describe("Client.getPrompt", () => {
  it("returns a parsed prompt", async () => {
    const f = fakeFetch([{ status: 200, body: payload() }]);
    const p = await client(f).getPrompt("support-agent", { version: 5 });
    expect(p.version).toBe(5);
    expect(p.fromCache).toBe(false);
    expect(p.render({ task: "refund" })).toBe("Task: refund");
  });

  it("sends bearer auth and the version param", async () => {
    const f = fakeFetch([{ status: 200, body: payload() }]);
    await client(f).getPrompt("support-agent", { version: 5 });
    expect(headerOf(f.calls[0], "Authorization")).toBe("Bearer nsk_test");
    expect(f.urls[0]).toContain("version=5");
  });

  it("serves immutable pinned versions from cache without a second request", async () => {
    const f = fakeFetch([
      {
        status: 200,
        body: payload(),
        headers: { ETag: '"v5"', "Cache-Control": "public, max-age=31536000, immutable" },
      },
    ]);
    const c = client(f);
    const first = await c.getPrompt("support-agent", { version: 5 });
    const second = await c.getPrompt("support-agent", { version: 5 });
    expect(first.fromCache).toBe(false);
    expect(second.fromCache).toBe(true);
    expect(f.calls.length).toBe(1);
  });

  it("revalidates moving aliases with If-None-Match and handles 304", async () => {
    const f = fakeFetch([
      { status: 200, body: payload(), headers: { ETag: '"v5"', "Cache-Control": "no-cache" } },
      { status: 304, headers: { ETag: '"v5"' } },
    ]);
    const c = client(f);
    const first = await c.getPrompt("support-agent");
    const second = await c.getPrompt("support-agent");
    expect(first.fromCache).toBe(false);
    expect(second.fromCache).toBe(true);
    expect(f.calls.length).toBe(2);
    expect(headerOf(f.calls[1], "If-None-Match")).toBe('"v5"');
  });

  it("falls back to last-known-good on a server error", async () => {
    const f = fakeFetch([
      { status: 200, body: payload(), headers: { ETag: '"v5"', "Cache-Control": "no-cache" } },
      { status: 503 },
      { status: 503 },
    ]);
    const c = client(f);
    await c.getPrompt("support-agent");
    const duringOutage = await c.getPrompt("support-agent");
    expect(duringOutage.fromCache).toBe(true);
    expect(duringOutage.version).toBe(5);
  });

  it("throws ServiceUnavailableError when the cache is cold", async () => {
    const f = fakeFetch([{ status: 503 }, { status: 503 }]);
    await expect(client(f).getPrompt("support-agent", { version: 5 })).rejects.toBeInstanceOf(
      ServiceUnavailableError,
    );
  });

  it("falls back to last-known-good on a network error", async () => {
    let calls = 0;
    const good = new Response(JSON.stringify(payload()), {
      status: 200,
      headers: { ETag: '"v5"', "Cache-Control": "no-cache" },
    });
    const f: FetchLike = async () => {
      calls += 1;
      if (calls === 1) return good;
      throw new Error("ECONNREFUSED");
    };
    const c = client(f);
    await c.getPrompt("support-agent");
    const duringOutage = await c.getPrompt("support-agent");
    expect(duringOutage.fromCache).toBe(true);
  });

  it("throws PromptNotFoundError on 404", async () => {
    const f = fakeFetch([{ status: 404, body: { error: "prompt not found" } }]);
    await expect(client(f).getPrompt("support-agent", { version: 5 })).rejects.toBeInstanceOf(
      PromptNotFoundError,
    );
  });

  it("throws AuthenticationError on 401", async () => {
    const f = fakeFetch([{ status: 401, body: { error: "invalid api key" } }]);
    await expect(client(f).getPrompt("support-agent", { version: 5 })).rejects.toBeInstanceOf(
      AuthenticationError,
    );
  });

  it("throws RateLimitError with retryAfter on 429", async () => {
    const f = fakeFetch([
      { status: 429, body: { error: "rate limit exceeded" }, headers: { "Retry-After": "30" } },
    ]);
    try {
      await client(f, { maxRetries: 0 }).getPrompt("support-agent", { version: 5 });
      throw new Error("expected throw");
    } catch (err) {
      expect(err).toBeInstanceOf(RateLimitError);
      expect((err as RateLimitError).retryAfter).toBe(30);
    }
  });

  it("rejects version and environment together", async () => {
    const f = fakeFetch([]);
    await expect(
      client(f).getPrompt("support-agent", { version: 5, environment: "production" }),
    ).rejects.toThrow();
  });
});

describe("FileCache durability", () => {
  it("serves a pinned version across client instances", async () => {
    const dir = mkdtempSync(join(tmpdir(), "nspark-test-"));
    const f = fakeFetch([
      {
        status: 200,
        body: payload(),
        headers: { ETag: '"v5"', "Cache-Control": "public, max-age=31536000, immutable" },
      },
    ]);

    const c1 = client(f, { cache: new FileCache(dir) });
    await c1.getPrompt("support-agent", { version: 5 });

    const c2 = client(f, { cache: new FileCache(dir) });
    const p = await c2.getPrompt("support-agent", { version: 5 });
    expect(p.fromCache).toBe(true);
    expect(f.calls.length).toBe(1);
  });
});

describe("Client.render", () => {
  it("fetches and renders in one call", async () => {
    const f = fakeFetch([{ status: 200, body: payload() }]);
    const text = await client(f).render("support-agent", { task: "refund" }, { version: 5 });
    expect(text).toBe("Task: refund");
  });
});
