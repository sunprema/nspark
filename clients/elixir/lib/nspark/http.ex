defmodule Nspark.HTTP do
  @moduledoc """
  Default HTTP backend (Req). A request function has the shape:

      (method :: atom, url :: String.t(), headers :: map, opts :: keyword) ::
        {:ok, %{status: integer, headers: map, body: term}} | {:error, term}

  `headers` (request and response) are plain maps of downcased string name →
  string value. The client injects this function, so tests can swap in a stub
  without any network or Req setup (see `Nspark.Client`'s `:request_fun` option).
  """

  @doc false
  @spec request(atom(), String.t(), map(), keyword()) ::
          {:ok, %{status: integer(), headers: map(), body: term()}} | {:error, term()}
  def request(method, url, headers, opts) do
    req =
      Req.new(
        method: method,
        url: url,
        headers: Map.to_list(headers),
        retry: false,
        receive_timeout: Keyword.get(opts, :timeout_ms, 5_000)
      )

    case Req.request(req) do
      {:ok, resp} ->
        {:ok, %{status: resp.status, headers: normalize_headers(resp.headers), body: resp.body}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  # Req returns headers as %{"name" => ["value", ...]}; flatten to first value.
  defp normalize_headers(headers) do
    Map.new(headers, fn
      {name, [value | _]} -> {String.downcase(name), value}
      {name, value} when is_binary(value) -> {String.downcase(name), value}
    end)
  end
end
