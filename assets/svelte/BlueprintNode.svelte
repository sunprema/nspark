<script>
  import { Handle, Position } from "@xyflow/svelte";

  let { data, selected } = $props();

  const HUES = {
    persona: 255,
    constraint: 28,
    context: 155,
    conditional: 78,
    output: 300,
    skill: 220,
    memory: 330,
    tool: 50,
    evaluation: 130,
  };

  const SUBTITLES = {
    persona: "SYSTEM / ROLE",
    constraint: "OPERATIONAL RULES",
    context: "CONTEXT / STATE",
    conditional: "BRANCHING LOGIC",
    skill: "CAPABILITY",
    memory: "WORKING MEMORY",
    tool: "EXTERNAL TOOL",
    evaluation: "QUALITY CHECK",
    output: "OUTPUT FORMAT",
  };

  let hue = $derived(HUES[data.node_type] ?? 250);
  let spine = $derived(`oklch(0.55 0.13 ${hue})`);
  let typeColor = $derived(`oklch(0.5 0.13 ${hue})`);
  let subtitle = $derived(SUBTITLES[data.node_type] ?? "");
  let isConditional = $derived(data.node_type === "conditional");

  // Parse content into plain-text + {variable} segments for highlighting.
  function parseContent(text) {
    if (!text) return [];
    const out = [];
    const re = /\{([a-zA-Z_]\w*)\}/g;
    let last = 0;
    let m;
    while ((m = re.exec(text)) !== null) {
      if (m.index > last) out.push({ text: text.slice(last, m.index), isVar: false });
      out.push({ text: m[0], isVar: true });
      last = re.lastIndex;
    }
    if (last < text.length) out.push({ text: text.slice(last), isVar: false });
    return out;
  }

  let contentParts = $derived(parseContent(data.content));
</script>

<div
  class="bp-node"
  class:muted={data.muted}
  class:selected
  class:linked={data.linked}
  class:conditional={isConditional}
  class:diag-warning={data.diagnostic === "warning"}
  class:diag-error={data.diagnostic === "error"}
  class:var-producer={data.var_role === "producer"}
  class:var-consumer={data.var_role === "consumer"}
  style="--spine:{spine}; --type-color:{typeColor};"
>
  <Handle type="target" position={Position.Top} />

  <div class="bp-header">
    <div class="bp-type-row">
      <span class="bp-type">{data.node_type.toUpperCase()}</span>
      {#if subtitle}
        <span class="bp-subtitle">· {subtitle}</span>
      {/if}
    </div>
    <div class="bp-badges">
      {#if data.linked}
        <span class="bp-badge bp-badge--linked" title="Linked to registry">⟳</span>
      {/if}
      {#if data.muted}
        <span class="bp-badge bp-badge--muted">MUTED</span>
      {:else if data.compile_order}
        <span class="bp-badge bp-badge--order">{data.compile_order}</span>
      {/if}
    </div>
  </div>

  <div class="bp-label">{data.label}</div>

  {#if contentParts.length > 0}
    <div class="bp-content">
      {#each contentParts as part}
        {#if part.isVar}
          <span class="bp-var">{part.text}</span>
        {:else}
          {part.text}
        {/if}
      {/each}
    </div>
  {/if}

  <Handle type="source" position={Position.Bottom} />
</div>

<style>
  .bp-node {
    width: 280px;
    background: oklch(0.99 0.004 245);
    border: 1px solid oklch(0.84 0.02 250);
    border-left: 4px solid var(--spine);
    font-family: "IBM Plex Sans", system-ui, sans-serif;
    box-shadow: 0 2px 8px -4px oklch(0.3 0.04 255 / 0.18);
  }

  .bp-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 6px;
    padding: 8px 10px 0;
  }

  .bp-type-row {
    display: flex;
    align-items: baseline;
    gap: 5px;
    min-width: 0;
  }

  .bp-type {
    font: 700 9px/1 "IBM Plex Mono", monospace;
    letter-spacing: 0.14em;
    color: var(--type-color);
    flex-shrink: 0;
  }

  .bp-subtitle {
    font: 400 8.5px/1 "IBM Plex Mono", monospace;
    letter-spacing: 0.06em;
    color: oklch(0.62 0.02 255);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .bp-badges {
    display: flex;
    align-items: center;
    gap: 4px;
    flex-shrink: 0;
  }

  .bp-badge {
    font: 600 8px/1 "IBM Plex Mono", monospace;
    padding: 2px 4px;
    letter-spacing: 0.06em;
  }

  .bp-badge--order {
    color: oklch(0.58 0.02 255);
    background: oklch(0.94 0.007 250);
    border-radius: 2px;
    min-width: 16px;
    text-align: center;
  }

  .bp-badge--muted {
    color: oklch(0.65 0.01 250);
    background: oklch(0.93 0.004 250);
    border-radius: 2px;
  }

  .bp-badge--linked {
    color: oklch(0.48 0.12 255);
    font-size: 11px;
    line-height: 1;
  }

  .bp-label {
    font: 500 12.5px/1.45 "IBM Plex Sans", sans-serif;
    color: oklch(0.28 0.02 255);
    padding: 5px 10px 8px;
  }

  .bp-content {
    padding: 0 10px 9px;
    font: 400 10.5px/1.55 "IBM Plex Mono", monospace;
    color: oklch(0.48 0.02 255);
    white-space: pre-wrap;
    overflow: hidden;
    display: -webkit-box;
    -webkit-line-clamp: 3;
    line-clamp: 3;
    -webkit-box-orient: vertical;
    border-top: 1px solid oklch(0.93 0.006 250);
    margin-top: 0;
  }

  .bp-var {
    color: oklch(0.46 0.12 78);
    background: oklch(0.96 0.018 78);
    border-radius: 2px;
    padding: 0 2px;
    font-weight: 500;
  }

  /* Selected state */
  .bp-node.selected {
    border-color: var(--spine);
    box-shadow:
      0 0 0 3px color-mix(in oklch, var(--spine) 20%, transparent),
      0 8px 24px -12px oklch(0.4 0.06 255 / 0.4);
  }

  /* Muted state */
  .bp-node.muted {
    background: oklch(0.965 0.003 245);
    border-style: dashed;
    box-shadow: none;
  }
  .bp-node.muted .bp-label {
    text-decoration: line-through;
    text-decoration-color: oklch(0.78 0.012 250);
    color: oklch(0.66 0.012 250);
  }
  .bp-node.muted .bp-content {
    opacity: 0.45;
  }

  /* Linked-to-registry state: content is managed in the Skill registry */
  .bp-node.linked {
    background: oklch(0.985 0.012 255);
    border-color: oklch(0.8 0.05 255);
    border-left-style: dashed;
  }
  .bp-node.linked .bp-label {
    color: oklch(0.34 0.05 255);
  }

  /* Conditional node: amber dashed top + tinted bg */
  .bp-node.conditional {
    border-top: 2px dashed oklch(0.68 0.12 78);
    background: oklch(0.992 0.008 78);
  }
  .bp-node.conditional .bp-content {
    border-top-color: oklch(0.9 0.018 78);
  }

  /* Diagnostic states */
  .bp-node.diag-warning {
    border-color: oklch(0.72 0.1 78);
    background: oklch(0.99 0.008 78);
  }
  .bp-node.diag-error {
    border-color: oklch(0.65 0.14 28);
    background: oklch(0.99 0.008 28);
  }

  /* Variable highlight states */
  .bp-node.var-producer {
    box-shadow: 0 0 0 2px oklch(0.46 0.12 155);
    background: oklch(0.985 0.014 155);
  }
  .bp-node.var-consumer {
    box-shadow: 0 0 0 2px oklch(0.58 0.11 78);
    background: oklch(0.985 0.014 78);
  }
</style>
