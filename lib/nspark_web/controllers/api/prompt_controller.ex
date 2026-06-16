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

  Authn is the shared bearer-token `:api` pipeline; the tenant is resolved from
  the caller's memberships. (Scoped, per-environment API keys are the next P0
  item and will replace user-bearer auth here.)

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

  def show(conn, %{"slug" => slug} = params) do
    user = conn.assigns[:current_user]

    cond do
      is_nil(user) ->
        error(conn, 401, "unauthorized")

      true ->
        case parse_qualifier(params) do
          {:ok, qualifier} -> resolve_and_render(conn, user, slug, qualifier)
          {:error, msg} -> error(conn, 400, msg)
        end
    end
  end

  defp resolve_and_render(conn, user, slug, qualifier) do
    case resolve_across_tenants(user, slug, qualifier) do
      {:ok, resolved} -> render_prompt(conn, resolved)
      {:error, :prompt_not_found} -> error(conn, 404, "prompt not found")
      {:error, :version_not_found} -> error(conn, 404, "no matching version for prompt")
    end
  end

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
