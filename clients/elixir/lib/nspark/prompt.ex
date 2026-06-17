defmodule Nspark.Prompt do
  @moduledoc """
  A resolved, immutable prompt artifact for one slug + qualifier.

  The runtime endpoint returns the compiled prompt plus the version's input
  contract. `render/3` validates supplied variables against that contract and
  substitutes them into the template — so a renamed/dropped variable surfaces
  as an error instead of leaking an unsubstituted `{placeholder}` into a model
  call.
  """

  alias Nspark.InputSchema
  alias Nspark.Error.{MissingVariables, UnknownVariables}

  # Mirrors the server-side var regex (Nspark.VersionDiff): a single-brace
  # placeholder whose name starts with a letter/underscore. Keeping these in
  # sync is what guarantees the client substitutes exactly what the compiler
  # emitted.
  @var_regex ~r/\{([a-zA-Z_]\w*)\}/

  @type t :: %__MODULE__{
          slug: String.t(),
          version: integer(),
          resolved_via: String.t(),
          text: String.t(),
          input_schema: InputSchema.t(),
          metadata: map(),
          stats: map(),
          from_cache: boolean()
        }

  @enforce_keys [:slug, :version, :text, :input_schema]
  defstruct [
    :slug,
    :version,
    :text,
    :input_schema,
    resolved_via: "",
    metadata: %{},
    stats: %{},
    from_cache: false
  ]

  @doc "Build a `Prompt` from a decoded response payload (string keys)."
  @spec from_payload(map(), keyword()) :: t()
  def from_payload(payload, opts \\ []) when is_map(payload) do
    %__MODULE__{
      slug: payload["slug"],
      version: payload["version"],
      resolved_via: payload["resolved_via"] || "",
      text: payload["prompt"] || "",
      input_schema: InputSchema.from_map(payload["input_schema"]),
      metadata: payload["metadata"] || %{},
      stats: payload["stats"] || %{},
      from_cache: Keyword.get(opts, :from_cache, false)
    }
  end

  @doc "Names of variables that must be supplied to `render/3`."
  @spec required_variables(t()) :: MapSet.t(String.t())
  def required_variables(%__MODULE__{input_schema: schema}), do: InputSchema.required(schema)

  @doc """
  Check `variables` against the contract without rendering.

  Returns `:ok`, or `{:error, %Nspark.Error.MissingVariables{}}` /
  `{:error, %Nspark.Error.UnknownVariables{}}`. Variable keys may be strings or
  atoms. Pass `strict: false` to allow undeclared extras.
  """
  @spec validate(t(), map(), keyword()) ::
          :ok | {:error, MissingVariables.t() | UnknownVariables.t()}
  def validate(%__MODULE__{} = prompt, variables, opts \\ []) do
    supplied = supplied_names(variables)

    missing = MapSet.difference(required_variables(prompt), supplied)

    cond do
      not Enum.empty?(missing) ->
        {:error, %MissingVariables{missing: MapSet.to_list(missing)}}

      Keyword.get(opts, :strict, true) ->
        unknown = MapSet.difference(supplied, InputSchema.names(prompt.input_schema))

        if Enum.empty?(unknown),
          do: :ok,
          else: {:error, %UnknownVariables{unknown: MapSet.to_list(unknown)}}

      true ->
        :ok
    end
  end

  @doc """
  Validate then substitute `variables` into the prompt template.

  Returns `{:ok, string}` with every `{name}` placeholder replaced by
  `to_string(value)`, or `{:error, error}` if validation fails. Validation runs
  first, so a missing variable returns an error rather than leaking an
  unsubstituted placeholder.
  """
  @spec render(t(), map(), keyword()) :: {:ok, String.t()} | {:error, Exception.t()}
  def render(%__MODULE__{} = prompt, variables \\ %{}, opts \\ []) do
    with :ok <- validate(prompt, variables, opts) do
      lookup = normalize_keys(variables)

      rendered =
        Regex.replace(@var_regex, prompt.text, fn whole, name ->
          case Map.fetch(lookup, name) do
            {:ok, value} -> to_string(value)
            # A declared-but-unsupplied name only reaches here when it wasn't
            # required (validate guarded the required set); leave it intact.
            :error -> whole
          end
        end)

      {:ok, rendered}
    end
  end

  @doc "Like `render/3` but raises on a validation error."
  @spec render!(t(), map(), keyword()) :: String.t()
  def render!(%__MODULE__{} = prompt, variables \\ %{}, opts \\ []) do
    case render(prompt, variables, opts) do
      {:ok, rendered} -> rendered
      {:error, error} -> raise error
    end
  end

  defp supplied_names(variables), do: variables |> normalize_keys() |> Map.keys() |> MapSet.new()

  # Accept either string- or atom-keyed variable maps.
  defp normalize_keys(variables) do
    Map.new(variables, fn {k, v} -> {to_string(k), v} end)
  end
end
