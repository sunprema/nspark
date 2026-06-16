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
