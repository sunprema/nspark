defmodule Nspark.Error do
  @moduledoc """
  Error structs raised/returned by the Newtonian Spark client.

  Every tuple-returning function answers `{:error, error}` where `error` is one
  of the exceptions below; the `!` variants raise the same struct. The split
  mirrors the runtime delivery API's failure modes:

    * auth / not-found / rate-limit / generic API errors map to HTTP responses
    * `Nspark.Error.ServiceUnavailable` is returned only when the service is
      unreachable **and** there is no last-known-good copy to fall back to
    * the validation errors are returned locally, before substitution, when
      supplied variables don't satisfy a version's published input contract
  """
end

defmodule Nspark.Error.API do
  @moduledoc "An unexpected, non-success HTTP response from the API."
  defexception [:status, :message]

  @impl true
  def message(%{status: status, message: message}), do: "[#{status}] #{message}"
end

defmodule Nspark.Error.Auth do
  @moduledoc "The API key was missing, invalid, revoked, or expired (HTTP 401/403)."
  defexception [:status, :message]

  @impl true
  def message(%{status: status, message: message}), do: "[#{status}] #{message}"
end

defmodule Nspark.Error.NotFound do
  @moduledoc "No prompt matched the slug, or no version matched the qualifier (HTTP 404)."
  defexception [:status, :message]

  @impl true
  def message(%{message: message}), do: "[404] #{message}"
end

defmodule Nspark.Error.RateLimit do
  @moduledoc "The per-principal rate limit was exceeded (HTTP 429)."
  defexception [:message, :retry_after]

  @impl true
  def message(%{message: message, retry_after: nil}), do: "[429] #{message}"

  def message(%{message: message, retry_after: secs}),
    do: "[429] #{message} (retry after #{secs}s)"
end

defmodule Nspark.Error.ServiceUnavailable do
  @moduledoc """
  The service could not be reached and no cached fallback was available.

  This is the error a critical-path caller must guard against. When a
  last-known-good copy exists in the cache the client returns it instead, so
  this means *both* the live fetch failed and the cache was cold.
  """
  defexception [:message]

  @impl true
  def message(%{message: message}), do: message
end

defmodule Nspark.Error.MissingVariables do
  @moduledoc "One or more required variables were not supplied for substitution."
  defexception [:missing]

  @impl true
  def message(%{missing: missing}),
    do: "missing required variable(s): #{missing |> Enum.sort() |> Enum.join(", ")}"
end

defmodule Nspark.Error.UnknownVariables do
  @moduledoc """
  Variables were supplied that the prompt does not declare (likely a typo).
  Returned only in strict rendering; lenient rendering ignores extras.
  """
  defexception [:unknown]

  @impl true
  def message(%{unknown: unknown}),
    do: "unknown variable(s) not in prompt contract: #{unknown |> Enum.sort() |> Enum.join(", ")}"
end
