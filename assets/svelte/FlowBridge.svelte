<script>
  import { onMount } from "svelte";
  import { useSvelteFlow } from "@xyflow/svelte";

  let { onReady } = $props();
  const { screenToFlowPosition, fitView } = useSvelteFlow();
  onReady({ screenToFlowPosition, fitView });

  onMount(() => fitView({ padding: 0.15 }));
</script>
