defmodule Nspark.RateLimiter do
  @moduledoc """
  A small, dependency-free fixed-window rate limiter backed by ETS.

  This process owns a single named, public ETS table and periodically sweeps
  expired windows; the hot path (`check/3`) talks to ETS directly via an atomic
  `:ets.update_counter/4`, so it never serializes through this GenServer.

  Each `(bucket, window)` pair is one counter. A window is `div(now_ms, window_ms)`,
  so all requests in the same wall-clock window share a counter that resets when
  the window rolls over. This trades the precision of a sliding window for O(1)
  lock-free counting — appropriate for coarse per-key/per-org API throttling.
  """
  use GenServer

  @table :nspark_rate_limiter

  @doc "Start the limiter (owns the ETS table)."
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @typedoc "Result of a limit check."
  @type result :: {:allow, remaining :: non_neg_integer(), reset_ms :: non_neg_integer()}
                  | {:deny, retry_after_ms :: non_neg_integer()}

  @doc """
  Record a hit against `bucket` and report whether it is within `limit` for the
  current `window_ms` window.

  Returns `{:allow, remaining, reset_ms}` while at or under the limit, or
  `{:deny, retry_after_ms}` once exceeded. `reset_ms`/`retry_after_ms` is the
  time until the current window rolls over.
  """
  @spec check(String.t(), pos_integer(), pos_integer()) :: result()
  def check(bucket, limit, window_ms) do
    now = System.system_time(:millisecond)
    window = div(now, window_ms)
    reset_ms = (window + 1) * window_ms - now
    count = :ets.update_counter(@table, {bucket, window}, {2, 1}, {{bucket, window}, 0})

    if count <= limit do
      {:allow, limit - count, reset_ms}
    else
      {:deny, reset_ms}
    end
  rescue
    # If the backing table isn't available (e.g. the limiter process isn't
    # running), fail open — a throttle must never take down the API it guards.
    ArgumentError -> {:allow, limit, window_ms}
  end

  # ── server ────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    # The window all callers share, so the sweeper can map a stored window index
    # back to wall-clock time. `check/3` is expected to be called with this same
    # `window_ms` (the plug reads it from the same config).
    window_ms = Keyword.get(opts, :window_ms, 60_000)
    sweep_ms = Keyword.get(opts, :sweep_ms, window_ms)
    schedule_sweep(sweep_ms)
    {:ok, %{window_ms: window_ms, sweep_ms: sweep_ms}}
  end

  @impl true
  def handle_info(:sweep, %{window_ms: window_ms, sweep_ms: sweep_ms} = state) do
    # Counters in any window strictly before the current one can never be hit
    # again (their wall-clock time has passed), so they're safe to drop.
    current_window = div(System.system_time(:millisecond), window_ms)
    :ets.select_delete(@table, [{{{:_, :"$1"}, :_}, [{:<, :"$1", current_window}], [true]}])
    schedule_sweep(sweep_ms)
    {:noreply, state}
  end

  defp schedule_sweep(sweep_ms), do: Process.send_after(self(), :sweep, sweep_ms)
end
