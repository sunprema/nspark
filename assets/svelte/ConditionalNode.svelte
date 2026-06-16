<script>
  import { Handle, Position } from "@xyflow/svelte";

  let { data, selected } = $props();

  const HUE = 78;
  const fill = $derived(
    data.muted
      ? "oklch(0.96 0.004 78)"
      : selected
        ? "oklch(0.985 0.022 78)"
        : "oklch(0.993 0.012 78)"
  );
  const stroke = $derived(
    data.diagnostic === "error"
      ? "oklch(0.62 0.16 28)"
      : data.diagnostic === "warning"
        ? "oklch(0.6 0.18 60)"
        : selected
          ? "oklch(0.48 0.18 78)"
          : "oklch(0.66 0.15 78)"
  );
  const strokeW = $derived(selected ? 2.5 : 1.5);
</script>

<div class="cond-node" class:selected class:muted={data.muted}>
  <Handle type="target" position={Position.Top} />
  <Handle type="source" position={Position.Right} id="yes" />
  <Handle type="source" position={Position.Left} id="no" />

  <svg class="cond-bg" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 116" aria-hidden="true">
    {#if selected}
      <polygon points="100,1 199,58 100,115 1,58" fill="none" stroke={stroke} stroke-width="10" opacity="0.18" />
    {/if}
    <polygon points="100,1 199,58 100,115 1,58" {fill} {stroke} stroke-width={strokeW} />
  </svg>

  <div class="cond-content">
    <span class="cond-type">CONDITIONAL</span>
    <span class="cond-label">{data.label}</span>
    {#if data.content}
      <span class="cond-expr">{data.content}</span>
    {/if}
  </div>

  <span class="branch-label branch-yes">yes</span>
  <span class="branch-label branch-no">no</span>
</div>

<style>
  .cond-node {
    position: relative;
    width: 200px;
    height: 116px;
    font-family: "IBM Plex Sans", system-ui, sans-serif;
    overflow: visible;
  }

  .cond-bg {
    position: absolute;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    overflow: visible;
  }

  .cond-content {
    position: absolute;
    inset: 0;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 3px;
    padding: 12px 44px;
    text-align: center;
    pointer-events: none;
  }

  .cond-type {
    font: 700 7.5px/1 "IBM Plex Mono", monospace;
    letter-spacing: 0.13em;
    color: oklch(0.54 0.15 78);
  }

  .cond-label {
    font: 500 12px/1.3 "IBM Plex Sans", sans-serif;
    color: oklch(0.26 0.06 78);
    overflow: hidden;
    display: -webkit-box;
    -webkit-line-clamp: 2;
    line-clamp: 2;
    -webkit-box-orient: vertical;
    word-break: break-word;
  }

  .cond-expr {
    font: 400 9px/1.3 "IBM Plex Mono", monospace;
    color: oklch(0.52 0.1 78);
    max-width: 100%;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .muted .cond-label {
    text-decoration: line-through;
    text-decoration-color: oklch(0.72 0.08 78);
    color: oklch(0.62 0.06 78);
  }

  .muted .cond-expr {
    opacity: 0.4;
  }

  .branch-label {
    position: absolute;
    font: 700 7.5px/1 "IBM Plex Mono", monospace;
    letter-spacing: 0.1em;
    color: oklch(0.52 0.14 78);
    background: oklch(0.97 0.018 78);
    padding: 2px 5px;
    border-radius: 2px;
    pointer-events: none;
    top: 50%;
    transform: translateY(-50%);
  }

  .branch-yes {
    right: 4px;
  }

  .branch-no {
    left: 4px;
  }
</style>
