/**
 * Error hierarchy for the Newtonian Spark client.
 *
 * Every error thrown by the SDK derives from {@link NsparkError}, so callers
 * can catch the whole family with one `instanceof`. The split mirrors the
 * runtime delivery API's failure modes:
 *
 * - auth / not-found / rate-limit / generic API errors map to HTTP responses;
 * - {@link ServiceUnavailableError} is thrown only when the service is
 *   unreachable *and* there is no last-known-good copy to fall back to;
 * - the {@link ValidationError} family is thrown locally, before substitution,
 *   when supplied variables don't satisfy a version's published input contract.
 */

export class NsparkError extends Error {
  constructor(message: string) {
    super(message);
    this.name = new.target.name;
    // Restore the prototype chain so `instanceof` works after transpilation.
    Object.setPrototypeOf(this, new.target.prototype);
  }
}

/** An unexpected, non-success HTTP response from the API. */
export class APIError extends NsparkError {
  constructor(
    public readonly statusCode: number,
    message: string,
  ) {
    super(`[${statusCode}] ${message}`);
  }
}

/** The API key was missing, invalid, revoked, or expired (HTTP 401/403). */
export class AuthenticationError extends APIError {}

/** No prompt matched the slug, or no version matched the qualifier (HTTP 404). */
export class PromptNotFoundError extends APIError {}

/** The per-principal rate limit was exceeded (HTTP 429). */
export class RateLimitError extends APIError {
  constructor(
    message: string,
    /** The server's `retry-after` hint in seconds, when present. */
    public readonly retryAfter?: number,
  ) {
    super(429, message);
  }
}

/**
 * The service could not be reached and no cached fallback was available.
 *
 * This is the error a critical-path caller must guard against. When a
 * last-known-good copy exists in the cache the SDK returns it instead of
 * throwing, so seeing this means *both* the live fetch failed and the cache
 * was cold.
 */
export class ServiceUnavailableError extends NsparkError {}

/** Supplied variables do not satisfy the version's published input contract. */
export class ValidationError extends NsparkError {}

/** One or more required variables were not supplied for substitution. */
export class MissingVariablesError extends ValidationError {
  constructor(public readonly missing: string[]) {
    super(`missing required variable(s): ${[...missing].sort().join(", ")}`);
  }
}

/**
 * Variables were supplied that the prompt does not declare (likely a typo).
 * Thrown only in `strict` rendering; lenient rendering ignores extras.
 */
export class UnknownVariablesError extends ValidationError {
  constructor(public readonly unknown: string[]) {
    super(`unknown variable(s) not in prompt contract: ${[...unknown].sort().join(", ")}`);
  }
}
