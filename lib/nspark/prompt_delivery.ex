defmodule Nspark.PromptDelivery do
  @moduledoc """
  Runtime retrieval of a published prompt by its stable slug.

  This is the primary product surface (NEXT_STEPS.md P0): a calling app fetches
  "the prompt for slug X at version/environment Y", gets back the compiled prompt
  plus the input contract it must satisfy, and injects its own variables. Unlike
  `/run`, this performs no orchestration — it resolves an immutable
  `GraphVersion`, compiles its frozen snapshot, and returns the artifact.

  Resolution qualifiers (normalized by the controller):

    * `{:version, n}`        — the exact published version number
    * `:latest`              — the highest published version of the graph
    * `{:environment, env}`  — whatever version is live (active deployment) in
                               `env` (`:dev` / `:staging` / `:production`)

  All reads are tenant-scoped; the caller passes `tenant:` and `actor:`.
  """

  import Ash.Query, only: [filter: 2, sort: 2, limit: 2, load: 2]

  alias Nspark.Architecture.{Graph, GraphVersion}
  alias Nspark.Deployments.Deployment

  @type qualifier :: {:version, pos_integer()} | :latest | {:environment, atom()}

  @type resolved :: %{
          graph: Graph.t(),
          version: GraphVersion.t(),
          resolved_via: String.t(),
          compiled: map()
        }

  @doc """
  Resolve a slug + qualifier to a compiled prompt artifact.

  Returns `{:ok, resolved}` or one of:

    * `{:error, :prompt_not_found}`  — no graph with that slug in the tenant
    * `{:error, :version_not_found}` — qualifier resolved to nothing published/deployed
  """
  @spec resolve(String.t(), qualifier(), keyword()) ::
          {:ok, resolved()} | {:error, :prompt_not_found | :version_not_found}
  def resolve(slug, qualifier, opts) do
    with {:ok, graph} <- fetch_graph(slug, opts),
         {:ok, version, via} <- fetch_version(graph, qualifier, opts) do
      {:ok,
       %{
         graph: graph,
         version: version,
         resolved_via: via,
         compiled: compile(version)
       }}
    end
  end

  defp fetch_graph(slug, opts) do
    case Graph |> filter(slug == ^slug) |> limit(1) |> Ash.read(opts) do
      {:ok, [graph]} -> {:ok, graph}
      {:ok, []} -> {:error, :prompt_not_found}
      {:error, _} -> {:error, :prompt_not_found}
    end
  end

  defp fetch_version(graph, {:version, n}, opts) do
    GraphVersion
    |> filter(graph_id == ^graph.id and version_number == ^n)
    |> limit(1)
    |> Ash.read(opts)
    |> one_or_missing("version:#{n}")
  end

  defp fetch_version(graph, :latest, opts) do
    GraphVersion
    |> filter(graph_id == ^graph.id)
    |> sort(version_number: :desc)
    |> limit(1)
    |> Ash.read(opts)
    |> one_or_missing("latest")
  end

  defp fetch_version(graph, {:environment, env}, opts) do
    # The version currently live in `env` = the most recent active deployment
    # of any of this graph's versions to that environment.
    with {:ok, [deployment]} <-
           Deployment
           |> filter(
             graph_version.graph_id == ^graph.id and environment == ^env and status == :active
           )
           |> sort(inserted_at: :desc)
           |> limit(1)
           |> load(:graph_version)
           |> Ash.read(opts) do
      {:ok, deployment.graph_version, "environment:#{env}"}
    else
      _ -> {:error, :version_not_found}
    end
  end

  defp one_or_missing({:ok, [version]}, via), do: {:ok, version, via}
  defp one_or_missing(_, _via), do: {:error, :version_not_found}

  # Compile the frozen snapshot. Skill content is already resolved into the
  # snapshot at publish time, so this is a pure transform with no Registry reads.
  defp compile(version) do
    snapshot = version.graph_snapshot || %{}
    nodes = snapshot["nodes"] || []
    edges = snapshot["edges"] || []
    Nspark.Compiler.compile(nodes, edges)
  end
end
