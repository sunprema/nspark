<script>
  import { Handle, Position } from "@xyflow/svelte";

  let { data, selected } = $props();

  const agentName = $derived(data.agent_name ?? data.label ?? "Agent");
  const outputVar = $derived(data.output_var ? `{${data.output_var}}` : null);
  const inputCount = $derived(
    data.input_mapping ? Object.keys(data.input_mapping).length : 0
  );
  const deploymentVersion = $derived(data.deployment_version ?? null);
  const onError = $derived(data.on_error ?? "fail");
  const hasDiag = $derived(!!data.diagnostic);
  const isParallel = $derived(!!data.parallel);
</script>

<div
  class="agent-node"
  class:selected
  class:muted={data.muted}
  class:diag-warning={data.diagnostic === "warning"}
  class:diag-error={data.diagnostic === "error"}
>
  <Handle type="target" position={Position.Top} />

  <div class="agent-header">
    <span class="agent-icon">⬡</span>
    <span class="agent-type">AGENT</span>
    {#if deploymentVersion}
      <span class="agent-version">v{deploymentVersion}</span>
    {/if}
    {#if isParallel}
      <span class="agent-badge agent-badge--parallel" title="runs in parallel">‖</span>
    {/if}
    {#if onError === "continue"}
      <span class="agent-badge agent-badge--continue" title="on error: continue">~</span>
    {/if}
  </div>

  <div class="agent-name">{agentName}</div>

  <div class="agent-contract">
    {#if inputCount > 0}
      <span class="contract-row">
        <span class="contract-label">in</span>
        <span class="contract-value">{inputCount} variable{inputCount !== 1 ? "s" : ""}</span>
      </span>
    {/if}
    {#if outputVar}
      <span class="contract-row">
        <span class="contract-label">out</span>
        <span class="contract-var">{outputVar}</span>
      </span>
    {:else}
      <span class="contract-row contract-row--unset">
        <span class="contract-label">out</span>
        <span class="contract-value contract-value--dim">not mapped</span>
      </span>
    {/if}
  </div>

  <Handle type="source" position={Position.Bottom} />
</div>

<style>
  .agent-node {
    width: 240px;
    background: oklch(0.99 0.005 255);
    border: 1.5px solid oklch(0.76 0.08 255);
    border-left: 4px solid oklch(0.52 0.18 255);
    font-family: "IBM Plex Sans", system-ui, sans-serif;
    box-shadow: 0 2px 8px -4px oklch(0.3 0.1 255 / 0.2);
  }

  .agent-node.selected {
    border-color: oklch(0.48 0.2 255);
    box-shadow:
      0 0 0 3px oklch(0.52 0.18 255 / 0.2),
      0 8px 24px -12px oklch(0.3 0.1 255 / 0.4);
  }

  .agent-node.muted {
    background: oklch(0.965 0.003 255);
    border-style: dashed;
    box-shadow: none;
    opacity: 0.65;
  }

  .agent-node.diag-warning {
    border-color: oklch(0.68 0.14 78);
    background: oklch(0.99 0.008 78);
  }

  .agent-node.diag-error {
    border-color: oklch(0.62 0.16 28);
    background: oklch(0.99 0.008 28);
  }

  .agent-header {
    display: flex;
    align-items: center;
    gap: 5px;
    padding: 7px 10px 0;
  }

  .agent-icon {
    font-size: 10px;
    line-height: 1;
    color: oklch(0.52 0.18 255);
  }

  .agent-type {
    font: 700 8px/1 "IBM Plex Mono", monospace;
    letter-spacing: 0.14em;
    color: oklch(0.46 0.18 255);
    flex: 1;
  }

  .agent-version {
    font: 500 8px/1 "IBM Plex Mono", monospace;
    color: oklch(0.58 0.06 255);
    background: oklch(0.93 0.015 255);
    padding: 1px 4px;
    border-radius: 2px;
  }

  .agent-badge {
    font: 700 9px/1 "IBM Plex Mono", monospace;
    padding: 1px 3px;
    border-radius: 2px;
  }

  .agent-badge--parallel {
    color: oklch(0.46 0.18 255);
    background: oklch(0.92 0.025 255);
    letter-spacing: 0.04em;
  }

  .agent-badge--continue {
    color: oklch(0.52 0.14 78);
    background: oklch(0.94 0.018 78);
  }

  .agent-name {
    font: 600 12.5px/1.4 "IBM Plex Sans", sans-serif;
    color: oklch(0.24 0.04 255);
    padding: 4px 10px 0;
  }

  .agent-contract {
    display: flex;
    flex-direction: column;
    gap: 2px;
    padding: 5px 10px 8px;
    border-top: 1px solid oklch(0.91 0.015 255);
    margin-top: 5px;
  }

  .contract-row {
    display: flex;
    align-items: baseline;
    gap: 6px;
  }

  .contract-label {
    font: 600 7.5px/1 "IBM Plex Mono", monospace;
    letter-spacing: 0.1em;
    color: oklch(0.6 0.06 255);
    width: 18px;
    flex-shrink: 0;
  }

  .contract-value {
    font: 400 9.5px/1 "IBM Plex Mono", monospace;
    color: oklch(0.5 0.04 255);
  }

  .contract-value--dim {
    color: oklch(0.72 0.02 255);
    font-style: italic;
  }

  .contract-var {
    font: 500 9.5px/1 "IBM Plex Mono", monospace;
    color: oklch(0.46 0.18 255);
    background: oklch(0.94 0.02 255);
    border-radius: 2px;
    padding: 0 3px;
  }
</style>
