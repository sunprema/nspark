defmodule NsparkWeb.StudioLiveTest do
  use NsparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ash.Query, only: [filter: 2]

  alias Nspark.Accounts.{Organization, Membership}
  alias Nspark.Projects.Project
  alias Nspark.Architecture.{Graph, Node, Edge}

  setup %{conn: conn} do
    org = Ash.create!(Organization, %{name: "Demo", slug: "nspark-demo"})
    user = Ash.Seed.seed!(Nspark.Accounts.User, %{email: "studio_test@example.com"})
    Ash.create!(Membership, %{user_id: user.id, organization_id: org.id, role: :owner})

    t = [tenant: org.id, authorize?: false]
    project = Ash.create!(Project, %{name: "P", status: :active}, t)
    graph = Ash.create!(Graph, %{name: "Agent Planner", project_id: project.id}, t)
    a = Ash.create!(Node, %{type: :persona, label: "A", graph_id: graph.id}, t)
    b = Ash.create!(Node, %{type: :output, label: "B", graph_id: graph.id}, t)

    conn = log_in_user(conn, user)

    %{conn: conn, org: org, graph: graph, a: a, b: b}
  end

  test "renders the seeded graph", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/studio")
    html = render(view)
    assert html =~ "Agent Planner"
    assert html =~ "2 nodes · 0 edges"
  end

  test "adds a node from the rail", %{conn: conn} do
    {:ok, view, _} = live(conn, "/studio")
    render_hook(view, "add_node", %{"type" => "skill"})
    assert render(view) =~ "3 nodes · 0 edges"
  end

  test "connects two nodes into an edge", %{conn: conn, a: a, b: b} do
    {:ok, view, _} = live(conn, "/studio")
    render_hook(view, "connect_nodes", %{"source" => a.id, "target" => b.id})
    assert render(view) =~ "2 nodes · 1 edges"
  end

  test "rejects a self-connection", %{conn: conn, a: a} do
    {:ok, view, _} = live(conn, "/studio")
    render_hook(view, "connect_nodes", %{"source" => a.id, "target" => a.id})
    assert render(view) =~ "2 nodes · 0 edges"
  end

  test "persists a dragged position", %{conn: conn, a: a, org: org} do
    {:ok, view, _} = live(conn, "/studio")
    render_hook(view, "node_moved", %{"id" => a.id, "x" => 321, "y" => 123})

    updated = Node |> filter(id == ^a.id) |> Ash.read_one!(tenant: org.id, authorize?: false)
    assert updated.metadata["position"] == %{"x" => 321, "y" => 123}
  end

  test "selects, edits, mutes a node", %{conn: conn, a: a, org: org} do
    {:ok, view, _} = live(conn, "/studio")

    render_hook(view, "select_node", %{"id" => a.id})
    assert render(view) =~ "PERSONA"

    render_hook(view, "update_node", %{"label" => "Edited", "content" => "Use {x}"})
    html = render(view)
    assert html =~ "Edited"

    updated = Node |> filter(id == ^a.id) |> Ash.read_one!(tenant: org.id, authorize?: false)
    assert updated.label == "Edited"
    assert updated.content == "Use {x}"

    render_hook(view, "toggle_mute", %{})
    reloaded = Node |> filter(id == ^a.id) |> Ash.read_one!(tenant: org.id, authorize?: false)
    assert reloaded.is_muted == true
  end

  test "edits content via the editor and discovers variables", %{conn: conn, a: a, org: org} do
    {:ok, view, _} = live(conn, "/studio")

    render_hook(view, "select_node", %{"id" => a.id})
    render_hook(view, "update_node_content", %{"id" => a.id, "content" => "Use {inventory} now"})

    updated = Node |> filter(id == ^a.id) |> Ash.read_one!(tenant: org.id, authorize?: false)
    assert updated.content == "Use {inventory} now"

    # the discovered variable surfaces in the rail explorer
    assert render(view) =~ "{inventory}"
  end

  test "live compiler renders the assembled prompt and updates on edit", %{conn: conn, a: a} do
    {:ok, view, _} = live(conn, "/studio")

    # persona node A -> "# MISSION" section heading appears in the rendered panel
    assert render(view) =~ "MISSION"

    render_hook(view, "select_node", %{"id" => a.id})
    render_hook(view, "update_node_content", %{"id" => a.id, "content" => "Plan carefully"})

    assert render(view) =~ "Plan carefully"
  end

  test "deletes a node and its connected edges", %{conn: conn, a: a, b: b, org: org} do
    {:ok, view, _} = live(conn, "/studio")
    render_hook(view, "connect_nodes", %{"source" => a.id, "target" => b.id})
    assert render(view) =~ "2 nodes · 1 edges"

    render_hook(view, "delete_node", %{"id" => a.id})
    assert render(view) =~ "1 nodes · 0 edges"

    assert Edge |> Ash.read!(tenant: org.id, authorize?: false) == []
  end
end
