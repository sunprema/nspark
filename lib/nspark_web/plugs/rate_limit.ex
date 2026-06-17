defmodule NsparkWeb.RateLimit do
  @moduledoc """
  Throttle the runtime API (`/api/v1/*`) per principal.

  The bucket is, in order of preference, the **API key**, then the
  authenticated **user**, then the client **IP** (a pre-auth safety net). Limits
  are coarse and shared across a principal's requests — enough to blunt runaway
  clients and abuse without policing legitimate bursts.

  Must run **after** authentication so `:api_key`/`:current_user` are populated.

  Config (`config :nspark, #{inspect(__MODULE__)}, limit: _, window_ms: _`):

    * `:limit`     — max requests per window per principal (default 120)
    * `:window_ms` — window length in ms (default 60_000)

  On every response: `x-ratelimit-limit`, `x-ratelimit-remaining`,
  `x-ratelimit-reset` (seconds until the window rolls over). On a throttle:
  `429` with a `retry-after` header.
  """
  import Plug.Conn

  @default_limit 120
  @default_window_ms 60_000

  def init(opts), do: opts

  def call(conn, opts) do
    limit = opts[:limit] || limit()
    window = opts[:window_ms] || window_ms()

    case Nspark.RateLimiter.check(bucket(conn), limit, window) do
      {:allow, remaining, reset_ms} ->
        put_rate_headers(conn, limit, remaining, reset_ms)

      {:deny, retry_ms} ->
        retry_s = ms_to_s(retry_ms)

        conn
        |> put_rate_headers(limit, 0, retry_ms)
        |> put_resp_header("retry-after", Integer.to_string(retry_s))
        |> put_resp_content_type("application/json")
        |> send_resp(429, Jason.encode!(%{error: "rate limit exceeded", retry_after: retry_s}))
        |> halt()
    end
  end

  @doc "Configured per-window request limit."
  def limit, do: get_config(:limit, @default_limit)

  @doc "Configured window length in milliseconds."
  def window_ms, do: get_config(:window_ms, @default_window_ms)

  # ── helpers ───────────────────────────────────────────────────────────────

  defp bucket(conn) do
    cond do
      key = conn.assigns[:api_key] -> "key:#{key.id}"
      user = conn.assigns[:current_user] -> "user:#{user.id}"
      true -> "ip:#{client_ip(conn)}"
    end
  end

  defp client_ip(conn) do
    case :inet.ntoa(conn.remote_ip) do
      {:error, _} -> "unknown"
      addr -> to_string(addr)
    end
  end

  defp put_rate_headers(conn, limit, remaining, reset_ms) do
    conn
    |> put_resp_header("x-ratelimit-limit", Integer.to_string(limit))
    |> put_resp_header("x-ratelimit-remaining", Integer.to_string(max(remaining, 0)))
    |> put_resp_header("x-ratelimit-reset", Integer.to_string(ms_to_s(reset_ms)))
  end

  defp ms_to_s(ms), do: max(div(ms, 1000), 1)

  defp get_config(key, default) do
    :nspark |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
