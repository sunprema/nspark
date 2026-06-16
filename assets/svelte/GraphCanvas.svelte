<script>
  import { onMount } from "svelte";
  import { SvelteFlow, Background, Controls, MiniMap } from "@xyflow/svelte";
  import "@xyflow/svelte/dist/style.css";
  import BlueprintNode from "./BlueprintNode.svelte";
  import FlowBridge from "./FlowBridge.svelte";

  let { nodes: initialNodes = [], edges: initialEdges = [], live } = $props();

  const nodeTypes = { blueprint: BlueprintNode };

  // Spread-copy so Svelte Flow can mutate without touching the prop reference.
  // Re-seeded whenever LiveView pushes updated props.
  let nodes = $state.raw($state.snapshot(initialNodes));
  let edges = $state.raw($state.snapshot(initialEdges));

  $effect.pre(() => {
    nodes = $state.snapshot(initialNodes);
  });
  $effect.pre(() => {
    edges = $state.snapshot(initialEdges);
  });

  let screenToFlowPosition = $state(null);

  let canvasEl;

  // Attach drag listeners in capture phase so they fire before SvelteFlow's
  // internal pane handlers, ensuring preventDefault() reaches the browser
  // before it decides whether to allow the drop.
  onMount(() => {
    function onDragOver(e) {
      e.preventDefault();
      e.dataTransfer.dropEffect = "copy";
    }

    function onDrop(e) {
      e.preventDefault();
      const type = e.dataTransfer.getData("application/nspark-node-type");
      if (!type) return;
      if (!screenToFlowPosition) return;
      const position = screenToFlowPosition({ x: e.clientX, y: e.clientY });
      live?.pushEvent("add_node_at", {
        type,
        x: Math.round(position.x),
        y: Math.round(position.y),
      });
    }

    canvasEl.addEventListener("dragover", onDragOver, { capture: true });
    canvasEl.addEventListener("drop", onDrop, { capture: true });

    return () => {
      canvasEl.removeEventListener("dragover", onDragOver, { capture: true });
      canvasEl.removeEventListener("drop", onDrop, { capture: true });
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
    <FlowBridge onReady={(fn) => (screenToFlowPosition = fn)} />
    <Background gap={22} bgColor="oklch(0.975 0.005 245)" patternColor="oklch(0.9 0.012 250)" />
    <Controls />
    <MiniMap pannable zoomable />
  </SvelteFlow>
</div>

<style>
  .bp-canvas {
    width: 100%;
    height: 100%;
  }
</style>
