/**
 * Caches backing the client's two delivery guarantees.
 *
 * The client uses one cache for two jobs at once:
 *
 * 1. **Conditional revalidation.** A cached entry remembers its `ETag` and
 *    whether the server marked it `immutable`. Immutable (pinned `?version=N`)
 *    entries are served without a network call; moving aliases (`@latest` /
 *    environment) are revalidated with `If-None-Match` and a `304` re-serves
 *    the cached body.
 * 2. **Last-known-good fallback.** If a fetch fails (network error / 5xx) the
 *    client serves the most recent cached entry instead of throwing — so the
 *    caller's critical path survives our outage.
 *
 * {@link InMemoryCache} is the default (fast, per-process). Wrap a
 * {@link FileCache} around a directory for last-known-good that survives
 * process restarts. `FileCache` is Node-only; in the browser, supply your own
 * {@link Cache} (e.g. backed by `localStorage`).
 */

import { createHash, randomBytes } from "node:crypto";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { join } from "node:path";

import type { PromptPayload } from "./models.js";

/** A stored response plus the metadata needed to revalidate it. */
export interface CacheEntry {
  payload: PromptPayload;
  etag?: string;
  /** `true` when the server marked this response immutable (pinned version). */
  immutable: boolean;
  storedAt: number;
}

/** Cache interface. Implementations must tolerate concurrent use. */
export interface Cache {
  get(key: string): Promise<CacheEntry | undefined>;
  set(key: string, entry: CacheEntry): Promise<void>;
}

/** Thread-safe in-process cache. Lost on restart. */
export class InMemoryCache implements Cache {
  private store = new Map<string, CacheEntry>();

  async get(key: string): Promise<CacheEntry | undefined> {
    return this.store.get(key);
  }

  async set(key: string, entry: CacheEntry): Promise<void> {
    this.store.set(key, entry);
  }
}

/**
 * Durable last-known-good cache backed by a directory of JSON files (Node only).
 *
 * Each key is hashed to a filename and written atomically (write-temp-then-
 * rename) so a crashed write can't leave a half-written entry. Use this when
 * last-known-good must survive process restarts (the common production case
 * for a critical-path dependency).
 */
export class FileCache implements Cache {
  private ready: Promise<unknown>;

  constructor(private readonly dir: string) {
    this.ready = mkdir(dir, { recursive: true });
  }

  private path(key: string): string {
    const digest = createHash("sha256").update(key).digest("hex");
    return join(this.dir, `${digest}.json`);
  }

  async get(key: string): Promise<CacheEntry | undefined> {
    await this.ready;
    try {
      const raw = await readFile(this.path(key), "utf-8");
      return JSON.parse(raw) as CacheEntry;
    } catch {
      // Missing or corrupt entry is treated as a cache miss, never an error.
      return undefined;
    }
  }

  async set(key: string, entry: CacheEntry): Promise<void> {
    await this.ready;
    const target = this.path(key);
    // Temp file lives in the target dir so the rename stays on one filesystem.
    const tmp = `${target}.${randomBytes(6).toString("hex")}.tmp`;
    await writeFile(tmp, JSON.stringify(entry), "utf-8");
    await rename(tmp, target);
  }
}
