<script>
  import { Handle, Position } from "@xyflow/svelte";

  let { data, selected } = $props();

  const name = $derived(data.label ?? "state");
  const isInitial = $derived(!!data.initial);
</script>

<div
  class="state-node"
  class:selected
  class:muted={data.muted}
  class:initial={isInitial}
  class:diag-warning={data.diagnostic === "warning"}
  class:diag-error={data.diagnostic === "error"}
>
  <!-- Single source/target handles: derived transition/containment edges carry no
       handle id, so a node must have exactly one handle per type for them to attach. -->
  <Handle type="target" position={Position.Top} />

  <span class="state-dot"></span>
  <span class="state-name">{name}</span>
  {#if isInitial}
    <span class="state-badge" title="initial state">START</span>
  {/if}

  <Handle type="source" position={Position.Bottom} />
</div>

<style>
  .state-node {
    display: flex;
    align-items: center;
    gap: 8px;
    min-width: 130px;
    padding: 9px 14px;
    background: oklch(0.97 0.03 200);
    border: 1.5px solid oklch(0.6 0.1 200);
    border-radius: 999px;
    font-family: "IBM Plex Sans", system-ui, sans-serif;
    box-shadow: 0 2px 8px -4px oklch(0.3 0.1 200 / 0.25);
  }

  .state-node.selected {
    border-color: oklch(0.45 0.15 200);
    box-shadow:
      0 0 0 3px oklch(0.55 0.12 200 / 0.22),
      0 8px 24px -12px oklch(0.3 0.1 200 / 0.4);
  }

  .state-node.initial {
    border-width: 2.5px;
    border-color: oklch(0.5 0.14 200);
    background: oklch(0.95 0.05 200);
  }

  .state-node.muted {
    opacity: 0.6;
    border-style: dashed;
    box-shadow: none;
  }

  .state-node.diag-warning {
    border-color: oklch(0.68 0.14 78);
    background: oklch(0.97 0.03 78);
  }

  .state-node.diag-error {
    border-color: oklch(0.62 0.16 28);
    background: oklch(0.97 0.03 28);
  }

  .state-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: oklch(0.5 0.14 200);
    flex-shrink: 0;
  }

  .state-name {
    font: 600 13px/1 "IBM Plex Mono", monospace;
    color: oklch(0.28 0.06 200);
    letter-spacing: 0.01em;
  }

  .state-badge {
    font: 700 7.5px/1 "IBM Plex Mono", monospace;
    letter-spacing: 0.12em;
    color: oklch(0.99 0.01 200);
    background: oklch(0.5 0.14 200);
    padding: 2px 5px;
    border-radius: 2px;
    margin-left: auto;
  }
</style>
