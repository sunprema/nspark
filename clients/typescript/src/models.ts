/**
 * Typed views over the prompt-retrieval response.
 *
 * The runtime endpoint returns JSON shaped like:
 *
 * ```json
 * {
 *   "slug": "support-agent",
 *   "version": 5,
 *   "resolved_via": "version:5",
 *   "prompt": "You are a support agent.\nTask: {task}\n",
 *   "input_schema": {
 *     "variables": { "task": { "required": true, "refs": ["node-1"] } },
 *     "outputs": ["resolution"],
 *     "provider": "anthropic"
 *   },
 *   "metadata": { ... },
 *   "stats": { ... }
 * }
 * ```
 *
 * {@link Prompt} wraps that payload and adds the one operation a calling app
 * actually performs: validate its variables against the contract, then
 * substitute them into the template ({@link Prompt.render}).
 */

import { MissingVariablesError, UnknownVariablesError } from "./errors.js";

/**
 * Mirrors the server-side var regex (`Nspark.VersionDiff`): a single-brace
 * placeholder whose name starts with a letter/underscore. Keeping these in sync
 * is what guarantees the SDK substitutes exactly what the compiler emitted.
 */
const VAR_RE = /\{([a-zA-Z_]\w*)\}/g;

export interface VariableSpec {
  required?: boolean;
  refs?: string[];
}

/** Raw response payload as returned by the API. */
export interface PromptPayload {
  slug: string;
  version: number;
  resolved_via?: string;
  prompt?: string;
  input_schema?: {
    variables?: Record<string, VariableSpec>;
    outputs?: string[];
    provider?: string | null;
  };
  metadata?: Record<string, unknown>;
  stats?: Record<string, unknown>;
}

export type Variables = Record<string, unknown>;

export interface RenderOptions {
  /** Throw on supplied variables not declared by the prompt. Default `true`. */
  strict?: boolean;
}

/**
 * The published input contract for a version.
 *
 * Every variable the compiled prompt references is listed in `variables` and
 * marked `required` by the server, so {@link InputSchema.required} is the full
 * key set. `outputs` and `provider` are carried for introspection.
 */
export class InputSchema {
  constructor(
    readonly variables: Record<string, VariableSpec> = {},
    readonly outputs: string[] = [],
    readonly provider: string | null = null,
  ) {}

  static fromJSON(data: PromptPayload["input_schema"]): InputSchema {
    return new InputSchema(
      data?.variables ?? {},
      data?.outputs ?? [],
      data?.provider ?? null,
    );
  }

  /** Names of variables that must be supplied before substitution. */
  get required(): Set<string> {
    const out = new Set<string>();
    for (const [name, spec] of Object.entries(this.variables)) {
      if (spec?.required !== false) out.add(name);
    }
    return out;
  }

  /** All variable names the prompt declares. */
  get names(): Set<string> {
    return new Set(Object.keys(this.variables));
  }
}

/** A resolved, immutable prompt artifact for one slug + qualifier. */
export class Prompt {
  constructor(
    readonly slug: string,
    readonly version: number,
    readonly resolvedVia: string,
    readonly text: string,
    readonly inputSchema: InputSchema,
    readonly metadata: Record<string, unknown>,
    readonly stats: Record<string, unknown>,
    /**
     * `true` when this copy was served from cache rather than a fresh fetch.
     * A stale last-known-good copy returned during an outage also sets this.
     */
    readonly fromCache: boolean,
  ) {}

  static fromPayload(payload: PromptPayload, fromCache = false): Prompt {
    return new Prompt(
      payload.slug,
      payload.version,
      payload.resolved_via ?? "",
      payload.prompt ?? "",
      InputSchema.fromJSON(payload.input_schema),
      payload.metadata ?? {},
      payload.stats ?? {},
      fromCache,
    );
  }

  get requiredVariables(): Set<string> {
    return this.inputSchema.required;
  }

  /**
   * Check `variables` against the contract without rendering.
   *
   * Throws {@link MissingVariablesError} if a required variable is absent, and
   * (when `strict`) {@link UnknownVariablesError} if a supplied variable is not
   * declared by the prompt.
   */
  validate(variables: Variables, { strict = true }: RenderOptions = {}): void {
    const supplied = new Set(Object.keys(variables));

    const missing = [...this.requiredVariables].filter((v) => !supplied.has(v));
    if (missing.length > 0) throw new MissingVariablesError(missing);

    if (strict) {
      const declared = this.inputSchema.names;
      const unknown = [...supplied].filter((v) => !declared.has(v));
      if (unknown.length > 0) throw new UnknownVariablesError(unknown);
    }
  }

  /**
   * Validate then substitute `variables` into the prompt template.
   *
   * Returns the final prompt string with every `{name}` placeholder replaced by
   * `String(value)`. Validation runs first, so a missing variable throws rather
   * than leaking an unsubstituted `{placeholder}` into a model call.
   */
  render(variables: Variables = {}, options: RenderOptions = {}): string {
    this.validate(variables, options);
    return this.text.replace(VAR_RE, (match, name: string) =>
      // A declared-but-unsupplied name only reaches here when it wasn't
      // required (validate() guarded the required set); leave it intact.
      Object.prototype.hasOwnProperty.call(variables, name) ? String(variables[name]) : match,
    );
  }
}
