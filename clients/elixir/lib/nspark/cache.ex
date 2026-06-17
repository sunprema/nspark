defmodule Nspark.Cache.Entry do
  @moduledoc "A stored response plus the metadata needed to revalidate it."

  @type t :: %__MODULE__{
          payload: map(),
          etag: String.t() | nil,
          immutable: boolean(),
          stored_at: integer()
        }

  @enforce_keys [:payload, :immutable, :stored_at]
  defstruct [:payload, :immutable, :stored_at, etag: nil]
end

defprotocol Nspark.Cache do
  @moduledoc """
  Cache used by `Nspark.Client` for two jobs at once:

  1. **Conditional revalidation** — a cached entry remembers its `ETag` and
     whether the server marked it `immutable`. Immutable (pinned `?version=N`)
     entries are served without a network call; moving aliases (`@latest` /
     environment) are revalidated with `If-None-Match` and a `304` re-serves the
     cached body.
  2. **Last-known-good fallback** — if a fetch fails (network error / 5xx) the
     client serves the most recent cached entry instead of failing, so the
     caller's critical path survives our outage.

  `Nspark.Cache.Memory` (ETS, per-process) is the default. Use
  `Nspark.Cache.File` for last-known-good that survives restarts. Implement this
  protocol for your own backing store (e.g. Redis).
  """

  @doc "Fetch an entry. Returns `{:ok, entry}` or `:miss`."
  @spec get(t, String.t()) :: {:ok, Nspark.Cache.Entry.t()} | :miss
  def get(cache, key)

  @doc "Store an entry."
  @spec put(t, String.t(), Nspark.Cache.Entry.t()) :: :ok
  def put(cache, key, entry)
end
