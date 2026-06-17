import { describe, expect, it } from "vitest";

import { MissingVariablesError, Prompt, UnknownVariablesError } from "../src/index.js";

function makePrompt(text: string, variables: Record<string, { required?: boolean }>): Prompt {
  return Prompt.fromPayload({
    slug: "demo",
    version: 1,
    resolved_via: "version:1",
    prompt: text,
    input_schema: { variables, outputs: [], provider: "anthropic" },
    metadata: {},
    stats: {},
  });
}

describe("Prompt.render", () => {
  it("substitutes declared variables", () => {
    const p = makePrompt("Hello {name}, task is {task}.", {
      name: { required: true },
      task: { required: true },
    });
    expect(p.render({ name: "Ada", task: "refund" })).toBe("Hello Ada, task is refund.");
  });

  it("coerces non-string values", () => {
    const p = makePrompt("Count: {n}", { n: { required: true } });
    expect(p.render({ n: 42 })).toBe("Count: 42");
  });

  it("throws on missing required variable", () => {
    const p = makePrompt("Hi {name} re {task}", {
      name: { required: true },
      task: { required: true },
    });
    expect(() => p.render({ name: "Ada" })).toThrow(MissingVariablesError);
  });

  it("strict render rejects unknown variables", () => {
    const p = makePrompt("Hi {name}", { name: { required: true } });
    try {
      p.render({ name: "Ada", typo: "x" });
      throw new Error("expected throw");
    } catch (err) {
      expect(err).toBeInstanceOf(UnknownVariablesError);
      expect((err as UnknownVariablesError).unknown).toEqual(["typo"]);
    }
  });

  it("lenient render ignores unknown variables", () => {
    const p = makePrompt("Hi {name}", { name: { required: true } });
    expect(p.render({ name: "Ada", extra: "x" }, { strict: false })).toBe("Hi Ada");
  });

  it("exposes required variables", () => {
    const p = makePrompt("{a}{b}", { a: { required: true }, b: { required: true } });
    expect(p.requiredVariables).toEqual(new Set(["a", "b"]));
  });
});
