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

  Pass `project_id:` in `opts` to additionally constrain the lookup to one
  project (used by project-scoped API keys); other opts (`tenant`, `actor`,
  `authorize?`) flow through to the reads.
  """
  @spec resolve(String.t(), qualifier(), keyword()) ::
          {:ok, resolved()} | {:error, :prompt_not_found | :version_not_found}
  def resolve(slug, qualifier, opts) do
    {project_id, ash_opts} = Keyword.pop(opts, :project_id)

    with {:ok, graph} <- fetch_graph(slug, project_id, ash_opts),
         {:ok, version, via} <- fetch_version(graph, qualifier, ash_opts) do
      {:ok,
       %{
         graph: graph,
         version: version,
         resolved_via: via,
         compiled: compile(version)
       }}
    end
  end

  @type summary :: %{
          slug: String.t(),
          name: String.t(),
          description: String.t() | nil,
          version: pos_integer(),
          resolved_via: String.t(),
          published_at: DateTime.t()
        }

  @doc """
  List the prompts resolvable within a scope — the discovery counterpart to
  `resolve/3` (e.g. for an MCP `prompts/list` or an SDK index call).

  Resolution mirrors a no-qualifier `resolve/3`:

    * An **environment-scoped** caller (`environment:` set) sees only prompts with
      an active deployment in that environment, reporting the version live there.
    * Otherwise every prompt with at least one published version is returned,
      reporting its latest version.

  Opts mirror `resolve/3`: `tenant`, `actor`/`authorize?`, optional `project_id`,
  and optional `environment` (atom). A draft graph with no published version is
  never listed, so a slug that appears here always resolves.
  """
  @spec list(keyword()) :: {:ok, [summary()]} | {:error, term()}
  def list(opts) do
    {project_id, opts} = Keyword.pop(opts, :project_id)
    {environment, opts} = Keyword.pop(opts, :environment)

    case environment do
      nil -> list_latest(project_id, opts)
      env -> list_environment(env, project_id, opts)
    end
  end

  defp list_latest(project_id, opts) do
    with {:ok, graphs} <- Graph |> scope_project(project_id) |> Ash.read(opts) do
      latest = latest_versions(Enum.map(graphs, & &1.id), opts)

      {:ok,
       graphs
       |> Enum.flat_map(fn g ->
         case Map.fetch(latest, g.id) do
           {:ok, v} -> [summary(g, v.version_number, "latest", v.inserted_at)]
           :error -> []
         end
       end)
       |> Enum.sort_by(& &1.name)}
    end
  end

  # Highest published version per graph, in one read. `select` keeps the heavy
  # `graph_snapshot` off the wire — only the numbers we surface are loaded.
  defp latest_versions([], _opts), do: %{}

  defp latest_versions(graph_ids, opts) do
    GraphVersion
    |> filter(graph_id in ^graph_ids)
    |> Ash.Query.select([:graph_id, :version_number, :inserted_at])
    |> sort(version_number: :desc)
    |> Ash.read!(opts)
    |> Enum.reduce(%{}, fn v, acc -> Map.put_new(acc, v.graph_id, v) end)
  end

  defp list_environment(env, project_id, opts) do
    with {:ok, deployments} <-
           Deployment
           |> filter(environment == ^env and status == :active)
           |> scope_project(project_id)
           |> sort(inserted_at: :desc)
           |> load(graph_version: :graph)
           |> Ash.read(opts) do
      via = "environment:#{env}"

      {:ok,
       deployments
       # most-recent-first, so the first deployment seen per graph is the live one
       |> Enum.uniq_by(& &1.graph_version.graph.id)
       |> Enum.map(fn d ->
         summary(d.graph_version.graph, d.graph_version.version_number, via, d.inserted_at)
       end)
       |> Enum.sort_by(& &1.name)}
    end
  end

  defp scope_project(query, nil), do: query
  defp scope_project(query, project_id), do: filter(query, project_id == ^project_id)

  defp summary(graph, version_number, via, published_at) do
    %{
      slug: graph.slug,
      name: graph.name,
      description: graph.description,
      version: version_number,
      resolved_via: via,
      published_at: published_at
    }
  end

  defp fetch_graph(slug, project_id, opts) do
    query = if project_id, do: filter(Graph, project_id == ^project_id), else: Graph

    case query |> filter(slug == ^slug) |> limit(1) |> Ash.read(opts) do
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
