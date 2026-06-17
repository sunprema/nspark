#!/usr/bin/env node
/**
 * Newtonian Spark MCP server.
 *
 * Exposes a tenant's published prompts to any MCP-capable agent (Claude
 * Desktop, an Agent SDK loop, an IDE) over stdio. Where the `nspark` SDK is for
 * a host app wiring a prompt into an agent at config time, this server is the
 * in-loop surface: an agent discovers prompts and pulls one mid-task.
 *
 * It is a thin wrapper over the same runtime API the SDKs use — no new auth or
 * runtime path. Scope (tenant / project / environment) comes entirely from the
 * scoped API key, so the two tools below can only ever see what the key can.
 *
 *   list_prompts  → GET /api/v1/prompts        (discovery)
 *   get_prompt    → GET /api/v1/prompts/:slug   (retrieval, via the SDK client)
 *
 * Config via env:
 *   NSPARK_BASE_URL   e.g. https://nspark.example.com   (required)
 *   NSPARK_API_KEY    a scoped key, nsk_…               (required)
 *
 * Run:  NSPARK_BASE_URL=… NSPARK_API_KEY=… npx nspark-mcp
 *
 * NOTE (stub): this ships `list_prompts` + `get_prompt` as MCP *tools*, which
 * preserves the SDK's client-side variable substitution. Graduating to MCP's
 * native `prompts` primitive (server-rendered messages, a prompt picker in the
 * client) needs a server-side render endpoint that does not exist yet — see the
 * README. The bare `listPrompts` fetch below should also migrate into the
 * `nspark` SDK once the list endpoint stabilises.
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { Client } from "nspark";

const baseUrl = process.env.NSPARK_BASE_URL;
const apiKey = process.env.NSPARK_API_KEY;

if (!baseUrl || !apiKey) {
  console.error("nspark-mcp: NSPARK_BASE_URL and NSPARK_API_KEY are required");
  process.exit(1);
}

const root = baseUrl.replace(/\/+$/, "");
const client = new Client(root, apiKey);

/** Call the discovery endpoint directly — the listing is dynamic (no-store), so
 * the SDK's pinned-version cache does not apply. */
async function listPrompts(environment?: string): Promise<unknown> {
  const url = new URL(`${root}/api/v1/prompts`);
  if (environment) url.searchParams.set("environment", environment);

  const resp = await fetch(url, {
    headers: { Authorization: `Bearer ${apiKey}`, Accept: "application/json" },
  });
  if (!resp.ok) {
    throw new Error(`list_prompts failed: HTTP ${resp.status}`);
  }
  return resp.json();
}

const server = new McpServer({ name: "nspark", version: "0.1.0" });

server.tool(
  "list_prompts",
  "List the Newtonian Spark prompts this API key can resolve. Each entry has a " +
    "slug, name, description, and the version that would resolve. Pass an " +
    "environment to list only what is live there (an environment-scoped key is " +
    "already pinned to its environment).",
  { environment: z.string().optional() },
  async ({ environment }) => {
    const data = await listPrompts(environment);
    return { content: [{ type: "text", text: JSON.stringify(data, null, 2) }] };
  },
);

server.tool(
  "get_prompt",
  "Fetch one Newtonian Spark prompt by slug. Returns the prompt template and its " +
    "input contract (the variables it declares). Supply `variables` to render the " +
    "final prompt text instead; rendering validates against the contract first, so " +
    "a missing required variable is reported rather than leaking a placeholder.",
  {
    slug: z.string().describe("The prompt's stable slug."),
    version: z
      .union([z.number().int().positive(), z.string()])
      .optional()
      .describe('Exact version number, or "@latest". Omit to follow @latest.'),
    environment: z
      .string()
      .optional()
      .describe("Resolve the version live in this environment instead of a version."),
    variables: z
      .record(z.any())
      .optional()
      .describe("If present, render the template with these and return the final text."),
  },
  async ({ slug, version, environment, variables }) => {
    const prompt = await client.getPrompt(slug, { version, environment });

    if (variables) {
      return { content: [{ type: "text", text: prompt.render(variables) }] };
    }

    const view = {
      slug: prompt.slug,
      version: prompt.version,
      resolved_via: prompt.resolvedVia,
      prompt: prompt.text,
      required_variables: [...prompt.requiredVariables],
      input_schema: prompt.inputSchema,
    };
    return { content: [{ type: "text", text: JSON.stringify(view, null, 2) }] };
  },
);

const transport = new StdioServerTransport();
await server.connect(transport);
console.error("nspark-mcp: ready on stdio");
