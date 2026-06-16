<script>
  import { onMount } from "svelte";
  import { useSvelteFlow } from "@xyflow/svelte";

  let { onReady } = $props();
  const { screenToFlowPosition, fitView } = useSvelteFlow();
  onReady(screenToFlowPosition);

  onMount(() => fitView());
</script>
