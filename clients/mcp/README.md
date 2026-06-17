# nspark-mcp

A [Model Context Protocol](https://modelcontextprotocol.io) server that exposes a
Newtonian Spark tenant's published prompts to any MCP-capable agent — Claude
Desktop, an Agent SDK loop, or an IDE.

Where the language SDKs (`clients/typescript`, `clients/python`, `clients/elixir`)
are for a **host app** wiring a prompt into an agent at config time, this server
is the **in-loop** surface: an agent discovers prompts and pulls one mid-task. It
is a thin wrapper over the same runtime API the SDKs use — no new auth or runtime
path. Everything is scoped by the API key.

## Tools

| Tool | Endpoint | Purpose |
| --- | --- | --- |
| `list_prompts` | `GET /api/v1/prompts` | Discover resolvable prompts (slug, name, description, version). Optional `environment`. |
| `get_prompt` | `GET /api/v1/prompts/:slug` | Fetch one prompt. Returns template + input contract; pass `variables` to get rendered text. |

`get_prompt` keeps the SDK's **client-side substitution**: with no `variables` it
returns the template and the declared inputs so the agent fills them; with
`variables` it validates against the contract and renders.

## Configuration

| Env var | Required | Description |
| --- | --- | --- |
| `NSPARK_BASE_URL` | yes | e.g. `https://nspark.example.com` |
| `NSPARK_API_KEY` | yes | A scoped key (`nsk_…`). Tenant/project/environment scope is carried by the key. |

An **environment-scoped** key (e.g. one bound to `production`) lists and resolves
only that environment — `list_prompts` reports each prompt's live version, and
`get_prompt` may only resolve that environment's alias.

## Install & run

```bash
npm install        # resolves the sibling `nspark` SDK via file:../typescript
npm run build
NSPARK_BASE_URL=https://nspark.example.com NSPARK_API_KEY=nsk_… node dist/index.js
```

### Claude Desktop

```json
{
  "mcpServers": {
    "nspark": {
      "command": "node",
      "args": ["/abs/path/to/clients/mcp/dist/index.js"],
      "env": {
        "NSPARK_BASE_URL": "https://nspark.example.com",
        "NSPARK_API_KEY": "nsk_…"
      }
    }
  }
}
```

## Status: stub

This ships `list_prompts` + `get_prompt` as MCP **tools** — the fastest path that
preserves client-side substitution and needs no server changes beyond the new
list endpoint.

Planned follow-ups:

- **Native `prompts` primitive.** Map the registry to MCP `prompts/list` +
  `prompts/get` so a non-developer gets a prompt picker in the client with no
  code. This needs a **server-side render endpoint** (the input contract becomes
  MCP prompt-arguments and the server returns finished messages) — the runtime
  today returns the template and lets the client inject.
- **`resources`.** Expose pinned versions as addressable `nspark://prompts/:slug@:version`
  resources for retrieval/citation.
- **Fold `listPrompts` into the `nspark` SDK** once the list endpoint stabilises,
  so this server depends only on the SDK.
