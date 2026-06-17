defmodule Nspark.InputSchema do
  @moduledoc """
  The published input contract for a version.

  Every variable the compiled prompt references is listed in `variables` and
  marked `required` by the server, so `required/1` is simply the full key set
  (minus any explicitly `required: false`). `outputs` and `provider` are carried
  for introspection.

  Shape as returned by the API:

      %{
        "variables" => %{"task" => %{"required" => true, "refs" => ["node-1"]}},
        "outputs" => ["resolution"],
        "provider" => "anthropic"
      }
  """

  @type t :: %__MODULE__{
          variables: %{optional(String.t()) => map()},
          outputs: [String.t()],
          provider: String.t() | nil
        }

  defstruct variables: %{}, outputs: [], provider: nil

  @doc "Build a schema from the decoded `input_schema` map (string keys)."
  @spec from_map(map() | nil) :: t()
  def from_map(nil), do: %__MODULE__{}

  def from_map(data) when is_map(data) do
    %__MODULE__{
      variables: Map.get(data, "variables") || %{},
      outputs: Map.get(data, "outputs") || [],
      provider: Map.get(data, "provider")
    }
  end

  @doc "Names of variables that must be supplied before substitution."
  @spec required(t()) :: MapSet.t(String.t())
  def required(%__MODULE__{variables: variables}) do
    for {name, spec} <- variables, required?(spec), into: MapSet.new(), do: name
  end

  @doc "All variable names the prompt declares."
  @spec names(t()) :: MapSet.t(String.t())
  def names(%__MODULE__{variables: variables}), do: MapSet.new(Map.keys(variables))

  defp required?(spec) when is_map(spec), do: Map.get(spec, "required", true) != false
  defp required?(_), do: true
end
