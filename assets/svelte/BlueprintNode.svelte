<script>
  import { Handle, Position } from "@xyflow/svelte";

  let { data, selected } = $props();

  // One chroma, a hue per node type (see UX_DESIGN §2 color system).
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

  let hue = $derived(HUES[data.node_type] ?? 250);
  let spine = $derived(`oklch(0.55 0.13 ${hue})`);
  let label = $derived(`oklch(0.5 0.13 ${hue})`);
</script>

<div
  class="bp-node"
  class:muted={data.muted}
  class:selected
  style="--spine:{spine}; --label:{label};"
>
  <Handle type="target" position={Position.Top} />

  <div class="bp-type">
    {data.node_type.toUpperCase()}{#if data.muted} · MUTED{/if}
  </div>
  <div class="bp-label">{data.label}</div>
  {#if data.content}
    <div class="bp-content">{data.content}</div>
  {/if}

  <Handle type="source" position={Position.Bottom} />
</div>

<style>
  .bp-node {
    width: 280px;
    background: oklch(0.99 0.004 245);
    border: 1px solid oklch(0.84 0.02 250);
    border-left: 4px solid var(--spine);
    padding: 9px 12px;
    font-family: "IBM Plex Sans", system-ui, sans-serif;
  }

  .bp-type {
    font: 600 9.5px/1 "IBM Plex Mono", monospace;
    letter-spacing: 0.14em;
    color: var(--label);
    margin-bottom: 7px;
  }

  .bp-label {
    font-size: 12.5px;
    line-height: 1.45;
    color: oklch(0.32 0.02 255);
  }

  .bp-content {
    margin-top: 6px;
    font: 400 11px/1.5 "IBM Plex Mono", monospace;
    color: oklch(0.45 0.02 255);
    white-space: pre-wrap;
    overflow: hidden;
    display: -webkit-box;
    -webkit-line-clamp: 3;
    line-clamp: 3;
    -webkit-box-orient: vertical;
  }

  .bp-node.selected {
    border-color: var(--spine);
    box-shadow:
      0 0 0 4px color-mix(in oklch, var(--spine) 18%, transparent),
      0 14px 28px -18px oklch(0.4 0.05 255 / 0.5);
  }

  .bp-node.muted {
    background: oklch(0.965 0.003 245);
    border-style: dashed;
  }

  .bp-node.muted .bp-label {
    text-decoration: line-through;
    text-decoration-color: oklch(0.78 0.012 250);
    color: oklch(0.66 0.012 250);
  }
</style>
