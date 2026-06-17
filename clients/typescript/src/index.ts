/**
 * Newtonian Spark — TypeScript/JavaScript client for runtime prompt delivery.
 *
 * Fetch governed, versioned prompts from a Newtonian Spark service, with
 * caching, last-known-good fallback, and variable validation against the
 * published input contract.
 *
 * ```ts
 * import { Client } from "nspark";
 *
 * const client = new Client("https://nspark.example.com", "nsk_…");
 * const prompt = await client.getPrompt("support-agent", { version: 5 });
 * const text = prompt.render({ task: "Issue a refund" });
 * ```
 */

export { Client } from "./client.js";
export type { ClientOptions, FetchLike, GetPromptOptions } from "./client.js";
export { InputSchema, Prompt } from "./models.js";
export type { PromptPayload, RenderOptions, Variables, VariableSpec } from "./models.js";
export { type Cache, type CacheEntry, FileCache, InMemoryCache } from "./cache.js";
export {
  APIError,
  AuthenticationError,
  MissingVariablesError,
  NsparkError,
  PromptNotFoundError,
  RateLimitError,
  ServiceUnavailableError,
  UnknownVariablesError,
  ValidationError,
} from "./errors.js";

export const VERSION = "0.1.0";
