defmodule Nspark.Client do
  @moduledoc """
  Runtime client for the Newtonian Spark prompt-retrieval API.

  A calling application fetches a published prompt by its stable slug, pins a
  version (or follows `@latest` / an environment alias), and injects its own
  variables. Built for the critical path:

    * **Pinned versions are cached forever** — the server marks `?version=N`
      immutable, so after the first fetch the client never hits the network.
    * **Moving aliases revalidate cheaply** — `@latest` / environment lookups
      send `If-None-Match`; a `304` re-serves the cached body for free.
    * **Outages fall back to last-known-good** — if the service is unreachable
      or returns 5xx, the client serves the last good copy instead of failing
      (`prompt.from_cache` tells them apart).
    * **Variables are validated before substitution**, against the version's
      published input contract.

  ## Example

      cache = Nspark.Cache.Memory.new()
      client = Nspark.Client.new("https://nspark.example.com", "nsk_…", cache: cache)

      {:ok, prompt} = Nspark.Client.get_prompt(client, "support-agent", version: 5)
      {:ok, text} = Nspark.Prompt.render(prompt, %{"task" => "Issue a refund"})
  """

  alias Nspark.{Cache, Prompt}
  alias Nspark.Cache.Entry

  alias Nspark.Error.{
    API,
    Auth,
    NotFound,
    RateLimit,
    ServiceUnavailable
  }

  @type t :: %__MODULE__{
          base_url: String.t(),
          api_key: String.t(),
          cache: Cache.t(),
          timeout_ms: non_neg_integer(),
          max_retries: non_neg_integer(),
          backoff_ms: non_neg_integer(),
          request_fun: function()
        }

  @enforce_keys [:base_url, :api_key, :cache, :request_fun]
  defstruct [
    :base_url,
    :api_key,
    :cache,
    :request_fun,
    timeout_ms: 5_000,
    max_retries: 2,
    backoff_ms: 200
  ]

  @doc """
  Build a client.

  Options:

    * `:cache` — a `Nspark.Cache` implementation (default: fresh
      `Nspark.Cache.Memory`). Pass `Nspark.Cache.File` for durable LKG.
    * `:timeout_ms` — per-request timeout (default 5000)
    * `:max_retries` — retries on network error / 5xx / 429 before fallback
      (default 2)
    * `:backoff_ms` — base for exponential backoff between retries (default 200)
    * `:request_fun` — override the HTTP backend (default `Nspark.HTTP.request/4`),
      mainly for testing
  """
  @spec new(String.t(), String.t(), keyword()) :: t()
  def new(base_url, api_key, opts \\ []) do
    if base_url in [nil, ""], do: raise(ArgumentError, "base_url is required")
    if api_key in [nil, ""], do: raise(ArgumentError, "api_key is required")

    %__MODULE__{
      base_url: String.trim_trailing(base_url, "/"),
      api_key: api_key,
      cache: Keyword.get_lazy(opts, :cache, &Nspark.Cache.Memory.new/0),
      timeout_ms: Keyword.get(opts, :timeout_ms, 5_000),
      max_retries: max(0, Keyword.get(opts, :max_retries, 2)),
      backoff_ms: Keyword.get(opts, :backoff_ms, 200),
      request_fun: Keyword.get(opts, :request_fun, &Nspark.HTTP.request/4)
    }
  end

  @doc """
  Fetch a prompt by slug.

  Options (at most one qualifier):

    * `:version` — exact pinned version (integer, immutable, cached forever),
      or `"@latest"` (revalidated)
    * `:environment` — resolve whatever version is live in that environment
      (`"dev"` / `"staging"` / `"production"`)

  With no qualifier the server returns `@latest`. Returns `{:ok, prompt}` or
  `{:error, error}`.
  """
  @spec get_prompt(t(), String.t(), keyword()) :: {:ok, Prompt.t()} | {:error, Exception.t()}
  def get_prompt(%__MODULE__{} = client, slug, opts \\ []) do
    version = Keyword.get(opts, :version)
    environment = Keyword.get(opts, :environment)

    cond do
      not is_nil(version) and not is_nil(environment) ->
        raise ArgumentError, "specify either :version or :environment, not both"

      true ->
        params = build_params(version, environment)
        key = cache_key(slug, params)
        cached = cache_get(client, key)

        # An immutable (pinned-version) entry can't change; serve without I/O.
        case cached do
          %Entry{immutable: true} = entry ->
            {:ok, Prompt.from_payload(entry.payload, from_cache: true)}

          _ ->
            fetch(client, slug, params, key, cached)
        end
    end
  end

  @doc "Like `get_prompt/3` but raises on error."
  @spec get_prompt!(t(), String.t(), keyword()) :: Prompt.t()
  def get_prompt!(%__MODULE__{} = client, slug, opts \\ []) do
    case get_prompt(client, slug, opts) do
      {:ok, prompt} -> prompt
      {:error, error} -> raise error
    end
  end

  @doc """
  Convenience: fetch a prompt and render it in one call.

  Render options (`:strict`) and fetch options (`:version` / `:environment`)
  share the keyword list.
  """
  @spec render(t(), String.t(), map(), keyword()) :: {:ok, String.t()} | {:error, Exception.t()}
  def render(%__MODULE__{} = client, slug, variables \\ %{}, opts \\ []) do
    with {:ok, prompt} <- get_prompt(client, slug, opts) do
      Prompt.render(prompt, variables, opts)
    end
  end

  # ── fetch + retry + fallback ──────────────────────────────────────────────

  defp fetch(client, slug, params, key, cached) do
    url = "#{client.base_url}/api/v1/prompts/#{URI.encode(slug)}#{query(params)}"
    do_fetch(client, slug, url, key, cached, 0)
  end

  defp do_fetch(client, slug, url, key, cached, attempt) do
    headers = request_headers(client, cached)

    case client.request_fun.(:get, url, headers, timeout_ms: client.timeout_ms) do
      {:ok, %{status: 200} = resp} ->
        store_and_return(client, key, resp)

      {:ok, %{status: 304}} when not is_nil(cached) ->
        {:ok, Prompt.from_payload(cached.payload, from_cache: true)}

      {:ok, %{status: 304}} ->
        # 304 with a cold cache shouldn't happen (we only send If-None-Match
        # when we have an entry); treat as a transient miss.
        retry_or_fallback(client, slug, url, key, cached, attempt)

      {:ok, %{status: status} = resp} when status in [401, 403] ->
        {:error, %Auth{status: status, message: error_message(resp)}}

      {:ok, %{status: 404} = resp} ->
        {:error, %NotFound{status: 404, message: error_message(resp)}}

      {:ok, %{status: 429} = resp} ->
        handle_rate_limit(client, slug, url, key, cached, attempt, resp)

      {:ok, %{status: status}} when status in 500..599 ->
        retry_or_fallback(client, slug, url, key, cached, attempt)

      {:ok, %{status: status} = resp} ->
        # Any other status is unexpected and not retryable.
        {:error, %API{status: status, message: error_message(resp)}}

      {:error, _exception} ->
        retry_or_fallback(client, slug, url, key, cached, attempt)
    end
  end

  defp handle_rate_limit(client, slug, url, key, cached, attempt, resp) do
    retry_after = retry_after_seconds(resp)

    if attempt < client.max_retries do
      sleep_ms = if retry_after, do: retry_after * 1000, else: backoff_for(client, attempt)
      Process.sleep(sleep_ms)
      do_fetch(client, slug, url, key, cached, attempt + 1)
    else
      {:error, %RateLimit{message: error_message(resp), retry_after: retry_after}}
    end
  end

  defp retry_or_fallback(client, slug, url, key, cached, attempt) do
    if attempt < client.max_retries do
      Process.sleep(backoff_for(client, attempt))
      do_fetch(client, slug, url, key, cached, attempt + 1)
    else
      case cached do
        %Entry{} = entry ->
          {:ok, Prompt.from_payload(entry.payload, from_cache: true)}

        _ ->
          {:error,
           %ServiceUnavailable{
             message: "failed to fetch prompt '#{slug}' and no cached copy is available"
           }}
      end
    end
  end

  defp store_and_return(client, key, resp) do
    entry = %Entry{
      payload: resp.body,
      etag: resp.headers["etag"],
      immutable: immutable?(resp),
      stored_at: System.system_time(:millisecond)
    }

    Cache.put(client.cache, key, entry)
    {:ok, Prompt.from_payload(resp.body, from_cache: false)}
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp cache_get(client, key) do
    case Cache.get(client.cache, key) do
      {:ok, entry} -> entry
      :miss -> nil
    end
  end

  defp request_headers(client, cached) do
    base = %{"authorization" => "Bearer #{client.api_key}", "accept" => "application/json"}

    case cached do
      %Entry{etag: etag} when is_binary(etag) -> Map.put(base, "if-none-match", etag)
      _ -> base
    end
  end

  defp build_params(_version, env) when is_binary(env), do: %{"environment" => env}

  defp build_params(version, _env) when not is_nil(version),
    do: %{"version" => to_string(version)}

  defp build_params(_version, _env), do: %{}

  defp query(params) when map_size(params) == 0, do: ""
  defp query(params), do: "?" <> URI.encode_query(params)

  defp cache_key(slug, %{"environment" => env}), do: "#{slug}@env:#{env}"
  defp cache_key(slug, %{"version" => v}), do: "#{slug}@version:#{v}"
  defp cache_key(slug, _), do: "#{slug}@latest"

  defp immutable?(resp) do
    resp.headers
    |> Map.get("cache-control", "")
    |> String.downcase()
    |> String.contains?("immutable")
  end

  defp retry_after_seconds(resp) do
    case resp.headers["retry-after"] do
      nil ->
        nil

      raw ->
        case Integer.parse(raw) do
          {n, _} -> n
          :error -> nil
        end
    end
  end

  defp backoff_for(client, attempt), do: client.backoff_ms * Integer.pow(2, attempt)

  defp error_message(resp) do
    case resp.body do
      %{"error" => message} when is_binary(message) -> message
      _ -> "HTTP #{resp.status}"
    end
  end
end
