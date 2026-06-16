<script>
  import { onMount } from "svelte";
  import { SvelteFlow, Background, Controls, MiniMap } from "@xyflow/svelte";
  import "@xyflow/svelte/dist/style.css";
  import BlueprintNode from "./BlueprintNode.svelte";
  import FlowBridge from "./FlowBridge.svelte";

  let { nodes: initialNodes = [], edges: initialEdges = [], live } = $props();

  const nodeTypes = { blueprint: BlueprintNode };

  let nodes = $state.raw($state.snapshot(initialNodes));
  let edges = $state.raw($state.snapshot(initialEdges));

  $effect.pre(() => {
    nodes = $state.snapshot(initialNodes);
  });
  $effect.pre(() => {
    edges = $state.snapshot(initialEdges);
  });

  let screenToFlowPosition = $state(null);
  let fitViewFn = $state(null);

  let canvasEl;

  onMount(() => {
    function onDragOver(e) {
      e.preventDefault();
      e.dataTransfer.dropEffect = "copy";
    }

    function onDrop(e) {
      e.preventDefault();
      if (!screenToFlowPosition) return;
      const position = screenToFlowPosition({ x: e.clientX, y: e.clientY });

      const nodeType = e.dataTransfer.getData("application/nspark-node-type");
      if (nodeType) {
        live?.pushEvent("add_node_at", {
          type: nodeType,
          x: Math.round(position.x),
          y: Math.round(position.y),
        });
        return;
      }

      const registryRaw = e.dataTransfer.getData("application/nspark-registry-asset");
      if (registryRaw) {
        const { asset_id, asset_type } = JSON.parse(registryRaw);
        live?.pushEvent("add_registry_node_at", {
          asset_id,
          asset_type,
          x: Math.round(position.x),
          y: Math.round(position.y),
        });
      }
    }

    // Keyboard shortcuts (skip when focus is inside an input/editor).
    function onKeyDown(e) {
      const tag = e.target.tagName;
      if (tag === "INPUT" || tag === "TEXTAREA" || e.target.isContentEditable) return;

      if (e.key === "f" || e.key === "F") {
        fitViewFn?.({ padding: 0.15, duration: 300 });
      }
      if (e.key === "Escape") {
        live?.pushEvent("select_node", { id: null });
      }
      if ((e.key === "m" || e.key === "M") && !e.metaKey && !e.ctrlKey) {
        live?.pushEvent("toggle_mute", {});
      }
    }

    canvasEl.addEventListener("dragover", onDragOver, { capture: true });
    canvasEl.addEventListener("drop", onDrop, { capture: true });
    window.addEventListener("keydown", onKeyDown);

    return () => {
      canvasEl.removeEventListener("dragover", onDragOver, { capture: true });
      canvasEl.removeEventListener("drop", onDrop, { capture: true });
      window.removeEventListener("keydown", onKeyDown);
    };
  });

  function handleNodeClick({ node }) {
    live?.pushEvent("select_node", { id: node.id });
  }

  function handlePaneClick() {
    live?.pushEvent("select_node", { id: null });
  }

  function handleNodeDragStop({ targetNode }) {
    if (!targetNode) return;
    live?.pushEvent("node_moved", {
      id: targetNode.id,
      x: Math.round(targetNode.position.x),
      y: Math.round(targetNode.position.y),
    });
  }

  function handleConnect(connection) {
    live?.pushEvent("connect_nodes", {
      source: connection.source,
      target: connection.target,
    });
  }

  function handleDelete({ nodes: deletedNodes, edges: deletedEdges }) {
    live?.pushEvent("delete_elements", {
      nodes: deletedNodes.map((n) => n.id),
      edges: deletedEdges.map((e) => e.id),
    });
  }
</script>

<div class="bp-canvas" bind:this={canvasEl}>
  <SvelteFlow
    bind:nodes
    bind:edges
    {nodeTypes}
    minZoom={0.2}
    deleteKey={["Backspace", "Delete"]}
    onnodeclick={handleNodeClick}
    onpaneclick={handlePaneClick}
    onnodedragstop={handleNodeDragStop}
    onconnect={handleConnect}
    ondelete={handleDelete}
  >
    <FlowBridge
      onReady={({ screenToFlowPosition: s, fitView: f }) => {
        screenToFlowPosition = s;
        fitViewFn = f;
      }}
    />
    <Background gap={22} bgColor="oklch(0.975 0.005 245)" patternColor="oklch(0.9 0.012 250)" />
    <Controls showFitView showZoom />
    <MiniMap pannable zoomable />
  </SvelteFlow>
</div>

<style>
  .bp-canvas {
    width: 100%;
    height: 100%;
  }

  /* ── SvelteFlow controls theming ────────────────────────────────────────── */
  :global(.svelte-flow__controls) {
    box-shadow: none;
    border: 1px solid oklch(0.86 0.02 250);
    background: oklch(0.99 0.003 245);
    border-radius: 0;
  }

  :global(.svelte-flow__controls-button) {
    background: oklch(0.99 0.003 245);
    border-bottom: 1px solid oklch(0.9 0.012 250);
    color: oklch(0.45 0.02 255);
    border-radius: 0;
  }

  :global(.svelte-flow__controls-button:hover) {
    background: oklch(0.96 0.01 255);
  }

  :global(.svelte-flow__controls-button svg) {
    fill: oklch(0.5 0.03 255);
  }

  /* ── Minimap theming ────────────────────────────────────────────────────── */
  :global(.svelte-flow__minimap) {
    background: oklch(0.975 0.005 245);
    border: 1px solid oklch(0.86 0.02 250);
    border-radius: 0;
    box-shadow: none;
  }

  :global(.svelte-flow__minimap-mask) {
    fill: oklch(0.92 0.01 250 / 0.55);
    stroke: oklch(0.72 0.04 255);
    stroke-width: 2;
  }

  :global(.svelte-flow__minimap-node) {
    fill: oklch(0.84 0.015 250);
    stroke: none;
  }

  /* ── Edge styling ───────────────────────────────────────────────────────── */
  :global(.svelte-flow__edge-path) {
    stroke: oklch(0.72 0.04 255);
    stroke-width: 1.5;
  }

  :global(.svelte-flow__edge.selected .svelte-flow__edge-path) {
    stroke: oklch(0.5 0.1 255);
    stroke-width: 2;
  }

  :global(.svelte-flow__handle) {
    background: oklch(0.75 0.05 255);
    border: 1.5px solid oklch(0.6 0.08 255);
    width: 9px;
    height: 9px;
  }

  :global(.svelte-flow__handle:hover) {
    background: oklch(0.55 0.13 255);
  }
</style>
