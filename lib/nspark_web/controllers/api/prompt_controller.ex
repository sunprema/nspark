defmodule NsparkWeb.Api.PromptController do
  @moduledoc """
  Pinned-version prompt retrieval — the primary runtime product surface
  (NEXT_STEPS.md P0). A calling app fetches a prompt by its stable slug and
  injects its own variables at runtime:

      GET /api/v1/prompts/:slug                  # → @latest published version
      GET /api/v1/prompts/:slug?version=5        # → exact published version
      GET /api/v1/prompts/:slug?version=@latest  # → highest published version
      GET /api/v1/prompts/:slug?version=@production
      GET /api/v1/prompts/:slug?environment=production  # → version live in env

  Returns the compiled prompt, the version's input contract (so a client can
  validate its variables before substituting), version metadata, and stats.

  Authn (`:api_runtime` pipeline) accepts either a **scoped API key** (preferred:
  `Authorization: Bearer nsk_…` or `x-api-key`) or a user bearer token. With a
  key, the tenant, project, and environment scope come from the key itself
  (`NsparkWeb.ApiKeyAuth`); a key bound to an environment may only resolve that
  environment's alias. With a user token, the tenant is resolved from the
  caller's memberships.

  ## Caching

  Every response carries a strong `ETag` derived from the resolved
  `GraphVersion` id (snapshots are immutable). An exact `?version=N` mapping can
  never change content, so it is returned `immutable`/long-lived; the moving
  `@latest`/environment aliases are `no-cache` (revalidate) but still answer
  `If-None-Match` with `304 Not Modified`.
  """
  use NsparkWeb, :controller

  @environments %{
    "dev" => :dev,
    "staging" => :staging,
    "production" => :production
  }

  @immutable_max_age 31_536_000

  @doc """
  List the prompts this caller can resolve — the discovery surface behind an MCP
  `prompts/list` or an SDK index. Scope (tenant/project/environment) is taken
  from the API key exactly as in `show/2`; an environment-scoped key lists only
  what's live in that environment. The listing is dynamic, so it is `no-store`.
  """
  def index(conn, _params) do
    api_key = conn.assigns[:api_key]
    user = conn.assigns[:current_user]

    cond do
      api_key ->
        result =
          Nspark.PromptDelivery.list(
            tenant: api_key.organization_id,
            project_id: api_key.project_id,
            environment: api_key.environment,
            authorize?: false
          )

        render_list(conn, api_key.environment, api_key.project_id, result)

      user ->
        render_list(conn, nil, nil, list_across_tenants(user))

      true ->
        error(conn, 401, "unauthorized")
    end
  end

  def show(conn, %{"slug" => slug} = params) do
    api_key = conn.assigns[:api_key]
    user = conn.assigns[:current_user]
    started = System.monotonic_time(:millisecond)

    cond do
      api_key ->
        with {:ok, qualifier} <- parse_qualifier(params),
             :ok <- enforce_key_scope(api_key, qualifier) do
          result = resolve_with_key(api_key, slug, qualifier)
          record_fetch(result, started, key_principal(api_key))
          render_result(conn, result)
        else
          {:error, :environment_forbidden} ->
            error(conn, 403, "api key is not scoped to that environment")

          {:error, msg} ->
            error(conn, 400, msg)
        end

      user ->
        case parse_qualifier(params) do
          {:ok, qualifier} ->
            result = resolve_across_tenants(user, slug, qualifier)
            record_fetch(result, started, %{type: :user})
            render_result(conn, result)

          {:error, msg} ->
            error(conn, 400, msg)
        end

      true ->
        error(conn, 401, "unauthorized")
    end
  end

  # ── observability ────────────────────────────────────────────────────────────

  defp key_principal(api_key),
    do: %{type: :api_key, api_key_id: api_key.id, organization_id: api_key.organization_id}

  # Fire-and-forget RunEvent for a prompt fetch. On success the tenant comes from
  # the resolved graph; on a cross-tenant miss (user path) there is no org to
  # attribute the event to, so `record/1` no-ops.
  defp record_fetch(result, started, principal) do
    latency = System.monotonic_time(:millisecond) - started

    base = %{
      source: :prompt_fetch,
      latency_ms: latency,
      principal_type: principal.type,
      api_key_id: Map.get(principal, :api_key_id)
    }

    attrs =
      case result do
        {:ok, %{graph: graph, version: version, resolved_via: via, compiled: compiled}} ->
          Map.merge(base, %{
            organization_id: graph.organization_id,
            status: :ok,
            http_status: 200,
            resolved_via: via,
            token_estimate: compiled[:token_estimate],
            graph_id: graph.id,
            graph_version_id: version.id
          })

        {:error, reason} ->
          Map.merge(base, %{
            organization_id: Map.get(principal, :organization_id),
            status: :error,
            http_status: 404,
            error_reason: to_string(reason)
          })
      end

    Nspark.Observability.record(attrs)
  end

  defp render_result(conn, result) do
    case result do
      {:ok, resolved} -> render_prompt(conn, resolved)
      {:error, :prompt_not_found} -> error(conn, 404, "prompt not found")
      {:error, :version_not_found} -> error(conn, 404, "no matching version for prompt")
    end
  end

  # An API key resolves within its own org tenant and (if set) project scope.
  # The key is the principal, so the read is unauthorized at the Ash layer —
  # scope is what constrains it.
  defp resolve_with_key(key, slug, qualifier) do
    Nspark.PromptDelivery.resolve(slug, qualifier,
      tenant: key.organization_id,
      project_id: key.project_id,
      authorize?: false
    )
  end

  # An environment-scoped key may only resolve the environment alias it's bound
  # to; version/@latest lookups are unaffected.
  defp enforce_key_scope(%{environment: env}, {:environment, requested})
       when not is_nil(env) and env != requested,
       do: {:error, :environment_forbidden}

  defp enforce_key_scope(_key, _qualifier), do: :ok

  # Try each org the caller belongs to until the slug resolves. A `prompt_not_found`
  # in one tenant should not mask a hit in another, so only a successful resolve
  # or an explicit `version_not_found` short-circuits.
  defp resolve_across_tenants(user, slug, qualifier) do
    user.id
    |> Nspark.Accounts.memberships_for_user!()
    |> Enum.reduce_while({:error, :prompt_not_found}, fn m, acc ->
      case Nspark.PromptDelivery.resolve(slug, qualifier, tenant: m.organization_id, actor: user) do
        {:ok, resolved} -> {:halt, {:ok, resolved}}
        {:error, :version_not_found} -> {:halt, {:error, :version_not_found}}
        {:error, :prompt_not_found} -> {:cont, acc}
      end
    end)
  end

  # Merge every org the caller belongs to, deduping by slug (the first org to
  # claim a slug wins, mirroring `resolve_across_tenants/3`'s first-hit order).
  defp list_across_tenants(user) do
    prompts =
      user.id
      |> Nspark.Accounts.memberships_for_user!()
      |> Enum.flat_map(fn m ->
        case Nspark.PromptDelivery.list(tenant: m.organization_id, actor: user) do
          {:ok, list} -> list
          _ -> []
        end
      end)
      |> Enum.uniq_by(& &1.slug)

    {:ok, prompts}
  end

  defp render_list(conn, _env, _project_id, {:error, _reason}) do
    error(conn, 500, "failed to list prompts")
  end

  defp render_list(conn, env, project_id, {:ok, prompts}) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(%{
      scope: %{
        environment: env && Atom.to_string(env),
        project_scoped: not is_nil(project_id)
      },
      prompts:
        Enum.map(prompts, fn p ->
          %{
            slug: p.slug,
            name: p.name,
            description: p.description,
            version: p.version,
            resolved_via: p.resolved_via,
            published_at: p.published_at
          }
        end)
    })
  end

  defp render_prompt(conn, %{graph: graph, version: version, resolved_via: via, compiled: compiled}) do
    etag = ~s("#{version.id}")

    if fresh?(conn, etag) do
      conn |> put_cache_headers(via, etag) |> send_resp(304, "")
    else
      conn
      |> put_cache_headers(via, etag)
      |> json(%{
        slug: graph.slug,
        version: version.version_number,
        resolved_via: via,
        prompt: compiled.markdown,
        input_schema: version.input_contract,
        metadata: %{
          graph_id: graph.id,
          graph_name: graph.name,
          version_number: version.version_number,
          changelog: version.changelog,
          published_at: version.inserted_at,
          resolved_skills: version.resolved_skills,
          diff_level: version.diff_summary["level"]
        },
        stats: %{
          token_estimate: compiled.token_estimate,
          included: compiled.included,
          excluded: compiled.excluded
        }
      })
    end
  end

  # ── version qualifier parsing ───────────────────────────────────────────────

  # Precedence: explicit `environment=`, then `version=` (number | @latest |
  # @<env>), then default to @latest.
  defp parse_qualifier(%{"environment" => env}) when env not in [nil, ""],
    do: parse_environment(env)

  defp parse_qualifier(%{"version" => v}) when v not in [nil, ""], do: parse_version(v)
  defp parse_qualifier(_), do: {:ok, :latest}

  defp parse_version("@latest"), do: {:ok, :latest}
  defp parse_version("@" <> env), do: parse_environment(env)

  defp parse_version(v) do
    case Integer.parse(v) do
      {n, ""} when n > 0 -> {:ok, {:version, n}}
      _ -> {:error, "invalid version: expected a positive integer, @latest, or @<environment>"}
    end
  end

  defp parse_environment(env) do
    case Map.fetch(@environments, env) do
      {:ok, atom} -> {:ok, {:environment, atom}}
      :error -> {:error, "unknown environment: #{env} (expected dev, staging, or production)"}
    end
  end

  # ── caching helpers ───────────────────────────────────────────────────────────

  defp fresh?(conn, etag) do
    case get_req_header(conn, "if-none-match") do
      [] -> false
      values -> Enum.any?(values, &(&1 == etag or &1 == "*"))
    end
  end

  defp put_cache_headers(conn, "version:" <> _, etag) do
    conn
    |> put_resp_header("etag", etag)
    |> put_resp_header("cache-control", "public, max-age=#{@immutable_max_age}, immutable")
  end

  defp put_cache_headers(conn, _moving_alias, etag) do
    conn
    |> put_resp_header("etag", etag)
    |> put_resp_header("cache-control", "no-cache")
  end

  defp error(conn, status, message) do
    conn |> put_status(status) |> json(%{error: message})
  end
end
