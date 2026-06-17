defmodule NsparkWeb.ApiKeyAuth do
  @moduledoc """
  Authenticate a scoped API key presented on the runtime API.

  The key may arrive as `Authorization: Bearer nsk_…` or in an `x-api-key`
  header. Only values carrying the `nsk_` secret prefix are treated as API keys,
  so this plug coexists with `load_from_bearer` (user JWTs have no such prefix) —
  a request can authenticate with either.

  On a valid, active key the plug assigns `:api_key` (the loaded record) and
  records `last_used_at`. Expired or revoked keys, and `nsk_`-prefixed values
  that don't resolve, are rejected with `401`. A missing key is **not** an error
  here — the controller decides whether to fall back to user-token auth.
  """
  import Plug.Conn

  alias Nspark.Accounts.ApiKey

  def init(opts), do: opts

  def call(conn, _opts) do
    case presented_secret(conn) do
      nil -> conn
      secret -> authenticate(conn, secret)
    end
  end

  defp authenticate(conn, secret) do
    case ApiKey.hash_secret(secret) |> Nspark.Accounts.get_api_key_by_hash(authorize?: false) do
      {:ok, key} ->
        if ApiKey.active?(key) do
          touch(key)
          assign(conn, :api_key, key)
        else
          deny(conn, "api key revoked or expired")
        end

      _ ->
        deny(conn, "invalid api key")
    end
  end

  # Only inspect bearer tokens that look like our keys, so user JWTs pass through
  # untouched to `load_from_bearer`.
  defp presented_secret(conn) do
    prefix = ApiKey.secret_prefix()

    cond do
      (key = header_value(conn, "x-api-key")) && String.starts_with?(key, prefix) -> key
      (bearer = bearer_token(conn)) && String.starts_with?(bearer, prefix) -> bearer
      true -> nil
    end
  end

  defp bearer_token(conn) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization") do
      String.trim(token)
    else
      _ -> nil
    end
  end

  defp header_value(conn, name) do
    case get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  # Best-effort usage stamp; never block or fail the request on it.
  defp touch(key) do
    Nspark.Accounts.touch_api_key(key, authorize?: false)
  rescue
    _ -> :ok
  end

  defp deny(conn, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: message}))
    |> halt()
  end
end
