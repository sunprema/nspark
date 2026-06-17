defmodule Nspark.Cache.File do
  @moduledoc """
  Durable last-known-good cache backed by a directory of JSON files.

  Each key is hashed to a filename and written atomically (write-temp-then-
  rename, on the same filesystem) so a crashed write can't leave a half-written
  entry. Use this when last-known-good must survive process restarts — the
  common production case for a critical-path dependency.
  """

  alias Nspark.Cache.Entry

  @type t :: %__MODULE__{dir: Path.t()}
  @enforce_keys [:dir]
  defstruct [:dir]

  @doc "Create a file-backed cache rooted at `dir` (created if absent)."
  @spec new(Path.t()) :: t()
  def new(dir) do
    File.mkdir_p!(dir)
    %__MODULE__{dir: dir}
  end

  @doc false
  def path(%__MODULE__{dir: dir}, key) do
    digest = :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)
    Path.join(dir, digest <> ".json")
  end

  @doc false
  def read(%__MODULE__{} = cache, key) do
    with {:ok, raw} <- File.read(path(cache, key)),
         {:ok, data} <- Jason.decode(raw) do
      {:ok, decode_entry(data)}
    else
      # Missing or corrupt entry is treated as a cache miss, never an error.
      _ -> :miss
    end
  end

  @doc false
  def write(%__MODULE__{} = cache, key, %Entry{} = entry) do
    target = path(cache, key)
    tmp = target <> "." <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)) <> ".tmp"
    File.write!(tmp, Jason.encode!(encode_entry(entry)))
    File.rename!(tmp, target)
    :ok
  end

  defp encode_entry(%Entry{} = entry) do
    %{
      "payload" => entry.payload,
      "etag" => entry.etag,
      "immutable" => entry.immutable,
      "stored_at" => entry.stored_at
    }
  end

  defp decode_entry(data) do
    %Entry{
      payload: data["payload"],
      etag: data["etag"],
      immutable: data["immutable"] || false,
      stored_at: data["stored_at"] || System.system_time(:millisecond)
    }
  end
end

defimpl Nspark.Cache, for: Nspark.Cache.File do
  def get(cache, key), do: Nspark.Cache.File.read(cache, key)
  def put(cache, key, entry), do: Nspark.Cache.File.write(cache, key, entry)
end
