defmodule NsparkWeb.Api.PromptControllerTest do
  @moduledoc """
  Covers the P0 runtime retrieval surface: `GET /api/v1/prompts/:slug`.
  Resolution by exact version, @latest, and environment alias, plus auth,
  not-found, validation, and ETag/304 caching behaviour.
  """
  use NsparkWeb.ConnCase, async: false

  alias Nspark.Accounts.{Organization, Membership}
  alias Nspark.Projects.Project
  alias Nspark.Architecture.{Graph, Node}

  setup %{conn: conn} do
    org = Ash.create!(Organization, %{name: "Demo", slug: "prompt-demo"})
    user = Ash.Seed.seed!(Nspark.Accounts.User, %{email: "prompt_api@example.com"})
    Ash.create!(Membership, %{user_id: user.id, organization_id: org.id, role: :owner})

    t = [tenant: org.id, authorize?: false]
    project = Ash.create!(Project, %{name: "P", status: :active}, t)
    graph = Ash.create!(Graph, %{name: "Support Agent", project_id: project.id}, t)

    persona =
      Ash.create!(
        Node,
        %{
          type: :persona,
          label: "Persona",
          content: "You are a support agent for {customer_name}.",
          graph_id: graph.id
        },
        t
      )

    output = Ash.create!(Node, %{type: :output, label: "Reply", graph_id: graph.id}, t)

    # Publish v1, then reload the graph (its version counter bumped) and publish v2.
    {:ok, _v1} =
      Nspark.Architecture.publish_graph(graph, [persona, output], [], user, org.id)

    graph = Ash.get!(Graph, graph.id, tenant: org.id, authorize?: false)

    {:ok, v2} =
      Nspark.Architecture.publish_graph(graph, [persona, output], [], user, org.id)

    %{conn: api_conn(conn, user), org: org, user: user, graph: graph, project: project, v2: v2}
  end

  describe "version resolution" do
    test "defaults to @latest when no qualifier is given", %{conn: conn, graph: graph} do
      conn = get(conn, "/api/v1/prompts/#{graph.slug}")
      body = json_response(conn, 200)

      assert body["slug"] == "support-agent"
      assert body["version"] == 2
      assert body["resolved_via"] == "latest"
      assert body["prompt"] =~ "support agent for {customer_name}"
      assert get_resp_header(conn, "cache-control") == ["no-cache"]
    end

    test "?version=1 returns the exact immutable version", %{conn: conn, graph: graph} do
      conn = get(conn, "/api/v1/prompts/#{graph.slug}?version=1")
      body = json_response(conn, 200)

      assert body["version"] == 1
      assert body["resolved_via"] == "version:1"
      assert ["public, max-age=" <> _] = get_resp_header(conn, "cache-control")
      assert [_etag] = get_resp_header(conn, "etag")
    end

    test "exposes the input contract for client-side validation", %{conn: conn, graph: graph} do
      body = conn |> get("/api/v1/prompts/#{graph.slug}") |> json_response(200)

      assert get_in(body, ["input_schema", "variables", "customer_name", "required"]) == true
    end

    test "resolves the version live in an environment", %{
      conn: conn,
      graph: graph,
      project: project,
      v2: v2,
      user: user,
      org: org
    } do
      # Deploy v2 to production; ?environment=production should resolve to it.
      Nspark.Deployments.deploy_version(
        %{
          environment: :production,
          project_id: project.id,
          graph_version_id: v2.id,
          deployed_version: v2.version_number
        },
        tenant: org.id,
        actor: user
      )

      body =
        conn |> get("/api/v1/prompts/#{graph.slug}?environment=production") |> json_response(200)

      assert body["version"] == 2
      assert body["resolved_via"] == "environment:production"
    end

    test "404s when no version is deployed to the requested environment", %{
      conn: conn,
      graph: graph
    } do
      body =
        conn |> get("/api/v1/prompts/#{graph.slug}?environment=staging") |> json_response(404)

      assert body["error"] =~ "no matching version"
    end
  end

  describe "caching" do
    test "honours If-None-Match with a 304", %{conn: conn, graph: graph} do
      first = get(conn, "/api/v1/prompts/#{graph.slug}?version=1")
      [etag] = get_resp_header(first, "etag")

      second =
        conn
        |> put_req_header("if-none-match", etag)
        |> get("/api/v1/prompts/#{graph.slug}?version=1")

      assert response(second, 304)
    end
  end

  describe "errors" do
    test "401 without a bearer token", %{graph: graph} do
      conn = get(build_conn(), "/api/v1/prompts/#{graph.slug}")
      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "404 for an unknown slug", %{conn: conn} do
      assert json_response(get(conn, "/api/v1/prompts/nope"), 404)["error"] == "prompt not found"
    end

    test "404 for a version that doesn't exist", %{conn: conn, graph: graph} do
      body = conn |> get("/api/v1/prompts/#{graph.slug}?version=99") |> json_response(404)
      assert body["error"] =~ "no matching version"
    end

    test "400 for a malformed version qualifier", %{conn: conn, graph: graph} do
      body = conn |> get("/api/v1/prompts/#{graph.slug}?version=abc") |> json_response(400)
      assert body["error"] =~ "invalid version"
    end

    test "400 for an unknown environment", %{conn: conn, graph: graph} do
      body = conn |> get("/api/v1/prompts/#{graph.slug}?environment=prod") |> json_response(400)
      assert body["error"] =~ "unknown environment"
    end
  end

  describe "api key auth" do
    test "an org-scoped key resolves the prompt", %{org: org, user: user, graph: graph} do
      conn = key_conn(issue(org, user, %{name: "k"})) |> get("/api/v1/prompts/#{graph.slug}")
      assert json_response(conn, 200)["version"] == 2
    end

    test "the key also works as an Authorization: Bearer credential", %{
      org: org,
      user: user,
      graph: graph
    } do
      secret = issue(org, user, %{name: "k"})

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{secret}")
        |> get("/api/v1/prompts/#{graph.slug}")

      assert json_response(conn, 200)["version"] == 2
    end

    test "stamps last_used_at on use", %{org: org, user: user, graph: graph} do
      secret = issue(org, user, %{name: "k"})
      key_conn(secret) |> get("/api/v1/prompts/#{graph.slug}")

      {:ok, key} = Nspark.Accounts.get_api_key_by_hash(Nspark.Accounts.ApiKey.hash_secret(secret))
      assert key.last_used_at
    end

    test "401 for an unknown key", %{graph: graph} do
      conn = key_conn("nsk_totally-bogus") |> get("/api/v1/prompts/#{graph.slug}")
      assert json_response(conn, 401)["error"] =~ "invalid api key"
    end

    test "401 for a revoked key", %{org: org, user: user, graph: graph} do
      secret = issue(org, user, %{name: "k"})
      {:ok, key} = Nspark.Accounts.get_api_key_by_hash(Nspark.Accounts.ApiKey.hash_secret(secret))
      Nspark.Accounts.revoke_api_key!(key, actor: user)

      conn = key_conn(secret) |> get("/api/v1/prompts/#{graph.slug}")
      assert json_response(conn, 401)["error"] =~ "revoked or expired"
    end

    test "a project-scoped key only sees prompts in its project", %{
      org: org,
      user: user,
      project: project,
      graph: graph
    } do
      in_scope = issue(org, user, %{name: "in", project_id: project.id})
      assert key_conn(in_scope) |> get("/api/v1/prompts/#{graph.slug}") |> json_response(200)

      other = Ash.create!(Project, %{name: "Other", status: :active}, tenant: org.id, authorize?: false)
      out_scope = issue(org, user, %{name: "out", project_id: other.id})
      body = key_conn(out_scope) |> get("/api/v1/prompts/#{graph.slug}") |> json_response(404)
      assert body["error"] == "prompt not found"
    end

    test "an environment-scoped key is limited to its environment alias", %{
      org: org,
      user: user,
      project: project,
      graph: graph,
      v2: v2
    } do
      Nspark.Deployments.deploy_version(
        %{
          environment: :production,
          project_id: project.id,
          graph_version_id: v2.id,
          deployed_version: v2.version_number
        },
        tenant: org.id,
        actor: user
      )

      secret = issue(org, user, %{name: "prod", environment: :production})

      ok = key_conn(secret) |> get("/api/v1/prompts/#{graph.slug}?environment=production")
      assert json_response(ok, 200)["resolved_via"] == "environment:production"

      denied = key_conn(secret) |> get("/api/v1/prompts/#{graph.slug}?environment=staging")
      assert json_response(denied, 403)["error"] =~ "not scoped to that environment"
    end
  end

  defp issue(org, user, attrs) do
    attrs = Map.merge(%{organization_id: org.id}, attrs)
    key = Nspark.Accounts.issue_api_key!(attrs, actor: user)
    Ash.Resource.get_metadata(key, :plaintext)
  end

  defp key_conn(secret), do: put_req_header(build_conn(), "x-api-key", secret)

  # Attach a stored bearer token so the :api pipeline's load_from_bearer resolves
  # the current_user, mirroring how a real client calls the runtime API.
  defp api_conn(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    :ok =
      AshAuthentication.TokenResource.Actions.store_token(
        Nspark.Accounts.Token,
        %{"token" => token, "purpose" => "user"},
        []
      )

    put_req_header(conn, "authorization", "Bearer #{token}")
  end
end
