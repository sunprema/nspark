<script>
  import { Handle, Position } from "@xyflow/svelte";

  let { data, selected } = $props();

  // The card's structure (priority / section / otherwise) comes from the graph;
  // the [WHEN]/actions body lives in `content`. We parse it here only for display —
  // the canonical parse happens server-side in Nspark.PromptBasic.Compiler.
  const lines = $derived((data.content ?? "").split("\n").map((l) => l.trim()));

  const whenExpr = $derived.by(() => {
    const l = lines.find((l) => l.startsWith("[WHEN]"));
    return l ? l.replace("[WHEN]", "").trim() : null;
  });

  const tools = $derived(
    lines
      .filter((l) => l.startsWith("[TOOL]"))
      .map((l) => {
        const m = l.replace("[TOOL]", "").trim().match(/^(\w+)/);
        return m ? m[1] : null;
      })
      .filter(Boolean)
  );

  const transition = $derived.by(() => {
    const l = lines.find((l) => l.startsWith("[STATE]"));
    return l ? l.replace("[STATE]", "").trim() : null;
  });

  const memWrites = $derived(lines.filter((l) => l.startsWith("[MEMORY]")).length);
  const asks = $derived(lines.some((l) => l.startsWith("[ASK]")));
  const responds = $derived(lines.some((l) => l.startsWith("[RESPOND]")));

  const isOtherwise = $derived(!!data.otherwise);
</script>

<div
  class="rule-node"
  class:selected
  class:muted={data.muted}
  class:otherwise={isOtherwise}
  class:diag-warning={data.diagnostic === "warning"}
  class:diag-error={data.diagnostic === "error"}
>
  <Handle type="target" position={Position.Top} />

  <div class="rule-head">
    {#if isOtherwise}
      <span class="rule-prio rule-prio--otherwise">OTHERWISE</span>
    {:else}
      <span class="rule-prio">P{data.priority ?? 0}</span>
    {/if}
    <span class="rule-type">RULE</span>
    {#if data.section}
      <span class="rule-section">{data.section}</span>
    {/if}
    <!-- Test layer: pass/fail dot per rule; a drains counter on the fallback. -->
    {#if isOtherwise && data.test_drains > 0}
      <span class="test-badge test-badge--gap" title="scenarios that drained here">⌽ {data.test_drains}</span>
    {:else if data.test_status === "pass"}
      <span class="test-mark test-mark--pass" title="covered by a passing scenario">●</span>
    {:else if data.test_status === "fail"}
      <span class="test-mark test-mark--fail" title="a scenario expectation failed">●</span>
    {/if}
  </div>

  <div class="rule-when">
    {#if whenExpr}
      <span class="when-kw">when</span> <span class="when-expr">{whenExpr}</span>
    {:else if isOtherwise}
      <span class="when-fallback">no rule matched →</span>
    {:else}
      <span class="when-fallback">{data.label ?? "untitled rule"}</span>
    {/if}
  </div>

  <div class="rule-actions">
    {#each tools as t}
      <span class="chip chip--tool" title="calls tool">⚙ {t}</span>
    {/each}
    {#if memWrites > 0}
      <span class="chip chip--mem" title="memory write">≔ {memWrites}</span>
    {/if}
    {#if responds}
      <span class="chip chip--say" title="responds">✦ respond</span>
    {/if}
    {#if asks}
      <span class="chip chip--say" title="asks">? ask</span>
    {/if}
    {#if transition}
      <span class="chip chip--state" title="transitions to state">→ {transition}</span>
    {/if}
  </div>

  <Handle type="source" position={Position.Bottom} />
</div>

<style>
  .rule-node {
    width: 230px;
    background: oklch(0.99 0.006 292);
    border: 1.5px solid oklch(0.74 0.09 292);
    border-left: 4px solid oklch(0.52 0.18 292);
    font-family: "IBM Plex Sans", system-ui, sans-serif;
    box-shadow: 0 2px 8px -4px oklch(0.3 0.1 292 / 0.2);
  }

  .rule-node.selected {
    border-color: oklch(0.48 0.2 292);
    box-shadow:
      0 0 0 3px oklch(0.52 0.18 292 / 0.2),
      0 8px 24px -12px oklch(0.3 0.1 292 / 0.4);
  }

  .rule-node.otherwise {
    border-left-color: oklch(0.6 0.04 292);
    background: oklch(0.985 0.003 292);
  }

  .rule-node.muted {
    background: oklch(0.965 0.003 292);
    border-style: dashed;
    box-shadow: none;
    opacity: 0.65;
  }

  .rule-node.diag-warning {
    border-color: oklch(0.68 0.14 78);
    background: oklch(0.99 0.008 78);
  }

  .rule-node.diag-error {
    border-color: oklch(0.62 0.16 28);
    background: oklch(0.99 0.008 28);
  }

  .rule-head {
    display: flex;
    align-items: center;
    gap: 5px;
    padding: 7px 10px 0;
  }

  .rule-prio {
    font: 700 8px/1 "IBM Plex Mono", monospace;
    letter-spacing: 0.04em;
    color: oklch(0.99 0.01 292);
    background: oklch(0.52 0.18 292);
    padding: 2px 5px;
    border-radius: 2px;
  }

  .rule-prio--otherwise {
    background: oklch(0.62 0.03 292);
    letter-spacing: 0.1em;
  }

  .rule-type {
    font: 700 8px/1 "IBM Plex Mono", monospace;
    letter-spacing: 0.14em;
    color: oklch(0.46 0.18 292);
    flex: 1;
  }

  .rule-section {
    font: 500 7.5px/1 "IBM Plex Mono", monospace;
    letter-spacing: 0.04em;
    color: oklch(0.58 0.05 292);
    text-transform: uppercase;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    max-width: 90px;
  }

  .test-mark {
    font-size: 9px;
    line-height: 1;
  }

  .test-mark--pass {
    color: oklch(0.6 0.15 150);
  }

  .test-mark--fail {
    color: oklch(0.6 0.19 28);
  }

  .test-badge {
    font: 700 8px/1 "IBM Plex Mono", monospace;
    padding: 1px 4px;
    border-radius: 2px;
  }

  .test-badge--gap {
    color: oklch(0.45 0.13 80);
    background: oklch(0.95 0.05 80);
  }

  .rule-when {
    padding: 6px 10px 0;
    font: 400 11px/1.4 "IBM Plex Sans", sans-serif;
    color: oklch(0.26 0.04 292);
  }

  .when-kw {
    font: 600 9px/1 "IBM Plex Mono", monospace;
    color: oklch(0.58 0.1 292);
  }

  .when-expr {
    font: 500 10.5px/1.4 "IBM Plex Mono", monospace;
    color: oklch(0.32 0.06 292);
    word-break: break-word;
  }

  .when-fallback {
    color: oklch(0.55 0.03 292);
    font-style: italic;
  }

  .rule-actions {
    display: flex;
    flex-wrap: wrap;
    gap: 4px;
    padding: 6px 10px 8px;
    margin-top: 5px;
    border-top: 1px solid oklch(0.91 0.015 292);
  }

  .rule-actions:empty {
    display: none;
  }

  .chip {
    font: 500 8.5px/1.3 "IBM Plex Mono", monospace;
    padding: 1px 5px;
    border-radius: 2px;
    white-space: nowrap;
  }

  .chip--tool {
    color: oklch(0.45 0.12 50);
    background: oklch(0.95 0.03 50);
  }

  .chip--mem {
    color: oklch(0.42 0.12 330);
    background: oklch(0.95 0.025 330);
  }

  .chip--say {
    color: oklch(0.46 0.1 292);
    background: oklch(0.95 0.02 292);
  }

  .chip--state {
    color: oklch(0.4 0.1 200);
    background: oklch(0.93 0.04 200);
  }

  .muted .when-expr,
  .muted .rule-when {
    text-decoration: line-through;
    text-decoration-color: oklch(0.72 0.06 292);
  }
</style>
