<script>
  let { count } = $props();
</script>

<div class="card">
  <div class="badge">LiveSvelte</div>
  <h1>End-to-end reactivity</h1>
  <p class="subtitle">This counter is powered by a Phoenix LiveView server — no page reload needed.</p>

  <div class="counter">
    <button class="btn btn-ghost" phx-click="decrement" aria-label="Decrement">−</button>
    <span class="count">{count}</span>
    <button class="btn btn-primary" phx-click="increment" aria-label="Increment">+</button>
  </div>

  <p class="hint">Click the buttons to update server state via the LiveView websocket.</p>
</div>

<style>
  .card {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 1rem;
    max-width: 420px;
    margin: 4rem auto;
    padding: 2.5rem 2rem;
    background: #ffffff;
    border: 1px solid #e5e7eb;
    border-radius: 1rem;
    box-shadow: 0 4px 24px rgba(0, 0, 0, 0.07);
    font-family: system-ui, -apple-system, sans-serif;
    text-align: center;
  }

  .badge {
    display: inline-flex;
    align-items: center;
    gap: 0.375rem;
    padding: 0.25rem 0.75rem;
    background: #fff7ed;
    color: #f97316;
    border: 1px solid #fed7aa;
    border-radius: 9999px;
    font-size: 0.75rem;
    font-weight: 600;
    letter-spacing: 0.05em;
    text-transform: uppercase;
  }

  .badge::before {
    content: '';
    display: inline-block;
    width: 6px;
    height: 6px;
    background: #f97316;
    border-radius: 50%;
    animation: pulse 2s ease-in-out infinite;
  }

  h1 {
    margin: 0;
    font-size: 1.5rem;
    font-weight: 700;
    color: #111827;
    letter-spacing: -0.02em;
  }

  .subtitle {
    margin: 0;
    font-size: 0.875rem;
    color: #6b7280;
    line-height: 1.5;
  }

  .counter {
    display: flex;
    align-items: center;
    gap: 1.25rem;
    margin: 0.5rem 0;
  }

  .count {
    min-width: 3.5rem;
    font-size: 3rem;
    font-weight: 800;
    color: #111827;
    letter-spacing: -0.04em;
    font-variant-numeric: tabular-nums;
    transition: transform 0.1s ease;
  }

  .btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 2.75rem;
    height: 2.75rem;
    border: none;
    border-radius: 50%;
    font-size: 1.5rem;
    font-weight: 400;
    line-height: 1;
    cursor: pointer;
    transition: background 0.15s ease, transform 0.1s ease, box-shadow 0.15s ease;
  }

  .btn:active {
    transform: scale(0.93);
  }

  .btn-primary {
    background: #f97316;
    color: #ffffff;
    box-shadow: 0 2px 8px rgba(249, 115, 22, 0.35);
  }

  .btn-primary:hover {
    background: #ea6c0b;
    box-shadow: 0 4px 14px rgba(249, 115, 22, 0.45);
  }

  .btn-ghost {
    background: #f3f4f6;
    color: #374151;
  }

  .btn-ghost:hover {
    background: #e5e7eb;
  }

  .hint {
    margin: 0;
    font-size: 0.75rem;
    color: #9ca3af;
  }

  @keyframes pulse {
    0%, 100% { opacity: 1; }
    50% { opacity: 0.4; }
  }

  @media (prefers-color-scheme: dark) {
    .card {
      background: #1f2937;
      border-color: #374151;
      box-shadow: 0 4px 24px rgba(0, 0, 0, 0.3);
    }
    h1 { color: #f9fafb; }
    .count { color: #f9fafb; }
    .subtitle { color: #9ca3af; }
    .badge {
      background: #431407;
      border-color: #ea6c0b;
      color: #fdba74;
    }
    .badge::before { background: #fb923c; }
    .btn-ghost {
      background: #374151;
      color: #d1d5db;
    }
    .btn-ghost:hover { background: #4b5563; }
  }
</style>
