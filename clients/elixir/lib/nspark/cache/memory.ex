defmodule Nspark.Cache.Memory do
  @moduledoc """
  In-process cache backed by a public ETS table. Fast, concurrent-safe, lost on
  restart.

  Create one per client with `new/0`. The table is owned by the process that
  calls `new/0`, so create it somewhere long-lived (e.g. your application
  start) rather than inside a short-lived request process.
  """

  @type t :: %__MODULE__{table: :ets.tid()}
  @enforce_keys [:table]
  defstruct [:table]

  @doc "Create a fresh in-memory cache."
  @spec new() :: t()
  def new do
    table = :ets.new(:nspark_cache, [:set, :public, read_concurrency: true])
    %__MODULE__{table: table}
  end
end

defimpl Nspark.Cache, for: Nspark.Cache.Memory do
  def get(%{table: table}, key) do
    case :ets.lookup(table, key) do
      [{^key, entry}] -> {:ok, entry}
      [] -> :miss
    end
  end

  def put(%{table: table}, key, entry) do
    :ets.insert(table, {key, entry})
    :ok
  end
end
