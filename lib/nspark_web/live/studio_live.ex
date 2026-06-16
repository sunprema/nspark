defmodule NsparkWeb.StudioLive do
  @moduledoc """
  The architecture studio: three-column blueprint shell (node library / Svelte
  Flow canvas / inspector). The LiveView is the source of truth — node/edge
  edits mutate Ash rows (tenant-scoped) and re-push flow props to the canvas.
  See docs/UX_DESIGN.md §3 and the graph persistence model in docs/HLD.md §4.
  """
  use NsparkWeb, :live_view

  on_mount {NsparkWeb.LiveUserAuth, :live_user_and_tenant_required}

  import Ash.Query, only: [filter: 2, sort: 2]

  alias Nspark.Architecture.{Graph, Node, Edge}
  alias Nspark.Projects.Project

  # The nine node types, in compile order, for the left-rail palette.
  @node_palette [
    {:persona, 255},
    {:constraint, 28},
    {:context, 155},
    {:conditional, 78},
    {:skill, 220},
    {:memory, 330},
    {:tool, 50},
    {:evaluation, 130},
    {:output, 300}
  ]
  @palette_types Enum.map(@node_palette, fn {t, _} -> t end)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:org_id, socket.assigns.current_org.id)
     # graph canvas state — populated by handle_params
     |> assign(:graph, nil)
     |> assign(:nodes, [])
     |> assign(:flow_nodes, [])
     |> assign(:flow_edges, [])
     |> assign(:edge_count, 0)
     |> assign(:variables, [])
     |> assign(:compiled, %{markdown: "", token_estimate: 0, included: 0, excluded: 0, cost_estimate: 0.0, provider: :anthropic})
     |> assign(:compiled_html, "")
     |> assign(:selected, nil)
     |> assign(:graph_dirty, false)
     |> assign(:graph_versions, [])
     |> assign(:diagnostics, [])
     # agent picker
     |> assign(:all_graphs, [])
     |> assign(:graph_search, "")
     |> assign(:show_agent_picker, false)
     # ui
     |> assign(:palette, @node_palette)
     |> assign(:show_new_graph_modal, false)
     |> assign(:new_graph_name, "")
     |> assign(:new_graph_description, "")
     |> assign(:show_deploy_modal, false)
     |> assign(:compiler_view, :rendered)
     |> assign(:selected_provider, :anthropic)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    org = socket.assigns.current_org
    actor = socket.assigns.current_user
    all_graphs = Ash.read!(Graph, tenant: org.id, actor: actor)

    socket =
      socket
      |> assign(:all_graphs, all_graphs)
      |> assign(:show_agent_picker, false)
      |> assign(:graph_search, "")
      |> load_from_params(params, all_graphs)

    {:noreply, socket}
  end

  # ── agent picker ────────────────────────────────────────────────────────────

  def handle_event("toggle_agent_picker", _params, socket) do
    show = !socket.assigns.show_agent_picker
    socket = assign(socket, :show_agent_picker, show)
    socket = if show, do: assign(socket, :graph_search, ""), else: socket
    {:noreply, socket}
  end

  def handle_event("close_agent_picker", _params, socket) do
    {:noreply, assign(socket, :show_agent_picker, false)}
  end

  def handle_event("search_agents", %{"value" => query}, socket) do
    {:noreply, assign(socket, :graph_search, query)}
  end

  def handle_event("agent_picker_keydown", %{"key" => "Escape"}, socket) do
    {:noreply, assign(socket, :show_agent_picker, false)}
  end

  def handle_event("agent_picker_keydown", _params, socket), do: {:noreply, socket}

  # ── selection ───────────────────────────────────────────────────────────────

  @impl true
  def handle_event("select_node", %{"id" => id}, socket) when is_binary(id) do
    {:noreply, assign(socket, :selected, find(socket, id))}
  end

  def handle_event("select_node", _params, socket) do
    {:noreply, assign(socket, :selected, nil)}
  end

  # ── drag → persist position (no re-push; client already shows it) ────────────

  def handle_event("node_moved", %{"id" => id, "x" => x, "y" => y}, socket) do
    opts = ash_opts(socket)

    nodes =
      Enum.map(socket.assigns.nodes, fn n ->
        if n.id == id do
          meta = Map.put(n.metadata || %{}, "position", %{"x" => x, "y" => y})
          Ash.update!(n, %{metadata: meta}, opts)
        else
          n
        end
      end)

    {:noreply, socket |> assign(:nodes, nodes) |> mark_dirty()}
  end

  # ── connect → create edge ────────────────────────────────────────────────────

  def handle_event("connect_nodes", %{"source" => s, "target" => t}, socket)
      when is_binary(s) and is_binary(t) and s != t do
    case Ash.create(
           Edge,
           %{graph_id: socket.assigns.graph.id, source_node_id: s, target_node_id: t},
           ash_opts(socket)
         ) do
      {:ok, _edge} -> {:noreply, socket |> refresh() |> mark_dirty()}
      # ignore duplicate / invalid connections
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_event("connect_nodes", _params, socket), do: {:noreply, socket}

  # ── add node from the rail (click → stacked position) ──────────────────────

  def handle_event("add_node", %{"type" => type}, socket) do
    with {:ok, type_atom} <- palette_type(type) do
      count = length(socket.assigns.nodes)
      pos = %{"x" => 440, "y" => 60 + rem(count, 8) * 44}
      create_node(type_atom, pos, socket)
      {:noreply, socket |> refresh() |> mark_dirty()}
    else
      _ -> {:noreply, socket}
    end
  end

  # ── add node from the rail (drag-drop → exact canvas position) ───────────────

  def handle_event("add_node_at", %{"type" => type, "x" => x, "y" => y}, socket) do
    with {:ok, type_atom} <- palette_type(type) do
      pos = %{"x" => x, "y" => y}
      create_node(type_atom, pos, socket)
      {:noreply, socket |> refresh() |> mark_dirty()}
    else
      _ -> {:noreply, socket}
    end
  end

  # ── delete (keyboard from canvas) ────────────────────────────────────────────

  def handle_event("delete_elements", params, socket) do
    Enum.each(Map.get(params, "edges", []), &destroy_edge(&1, socket))
    Enum.each(Map.get(params, "nodes", []), &destroy_node(&1, socket))
    {:noreply, socket |> assign(:selected, nil) |> refresh() |> mark_dirty()}
  end

  # ── inspector: edit, mute, delete ────────────────────────────────────────────

  def handle_event("update_node", params, socket) do
    case socket.assigns.selected do
      nil ->
        {:noreply, socket}

      node ->
        attrs =
          %{}
          |> put_if_present(params, "label", &(String.trim(&1) != ""))
          |> put_if_present(params, "content")

        _ = Ash.update!(node, attrs, ash_opts(socket))
        {:noreply, socket |> refresh() |> mark_dirty()}
    end
  end

  def handle_event("update_node_content", params, socket) do
    id = Map.get(params, "id") || (socket.assigns.selected && socket.assigns.selected.id)
    content = Map.get(params, "content", "")

    case id && find(socket, id) do
      nil ->
        {:noreply, socket}

      node ->
        _ = Ash.update!(node, %{content: content}, ash_opts(socket))
        {:noreply, socket |> refresh() |> mark_dirty()}
    end
  end

  def handle_event("toggle_mute", _params, socket) do
    case socket.assigns.selected do
      nil ->
        {:noreply, socket}

      node ->
        _ = Ash.update!(node, %{is_muted: !node.is_muted}, ash_opts(socket))
        {:noreply, socket |> refresh() |> mark_dirty()}
    end
  end

  def handle_event("delete_node", %{"id" => id}, socket) do
    destroy_node(id, socket)
    {:noreply, socket |> assign(:selected, nil) |> refresh() |> mark_dirty()}
  end

  # ── new graph modal ──────────────────────────────────────────────────────────

  def handle_event("open_new_graph_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_new_graph_modal, true)
     |> assign(:new_graph_name, "")
     |> assign(:new_graph_description, "")}
  end

  def handle_event("close_new_graph_modal", _params, socket) do
    {:noreply, assign(socket, :show_new_graph_modal, false)}
  end

  def handle_event("new_graph_change", %{"name" => name, "description" => desc}, socket) do
    {:noreply,
     socket
     |> assign(:new_graph_name, name)
     |> assign(:new_graph_description, desc)}
  end

  def handle_event("create_graph", %{"name" => name, "description" => desc}, socket) do
    name = String.trim(name)

    if name == "" do
      {:noreply, socket}
    else
      opts = ash_opts(socket)

      project_id =
        case Project |> Ash.read!(opts) do
          [p | _] -> p.id
          [] ->
            p = Ash.create!(Project, %{name: "Default", status: :active}, opts)
            p.id
        end

      attrs =
        %{name: name, project_id: project_id}
        |> then(fn a ->
          case String.trim(desc) do
            "" -> a
            d -> Map.put(a, :description, d)
          end
        end)

      graph = Ash.create!(Graph, attrs, opts)

      {:noreply,
       socket
       |> assign(:show_new_graph_modal, false)
       |> push_patch(to: ~p"/studio/#{graph.id}")}
    end
  end

  # ── publish / version restore ───────────────────────────────────────────────

  def handle_event("publish", _params, socket) do
    %{graph: graph, nodes: nodes} = socket.assigns
    # Fetch current edges (not in top-level assigns)
    opts = ash_opts(socket)
    edges = Edge |> filter(graph_id == ^graph.id) |> Ash.read!(opts)

    case Nspark.Architecture.publish_graph(graph, nodes, edges, socket.assigns.current_user, socket.assigns.org_id) do
      {:ok, version} ->
        updated_graph = Ash.reload!(graph, opts)

        {:noreply,
         socket
         |> assign(:graph, updated_graph)
         |> assign(:graph_dirty, false)
         |> load_versions()
         |> put_flash(:info, "Published v#{version.version_number}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Publish failed: #{inspect(reason)}")}
    end
  end

  def handle_event("restore_version", %{"id" => version_id}, socket) do
    version = Enum.find(socket.assigns.graph_versions, &(&1.id == version_id))

    if version do
      case Nspark.Architecture.restore_version(version, socket.assigns.graph, socket.assigns.current_user, socket.assigns.org_id) do
        {:ok, _id_map} ->
          {:noreply,
           socket
           |> assign(:selected, nil)
           |> refresh()
           |> assign(:graph_dirty, false)
           |> put_flash(:info, "Restored to v#{version.version_number}")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Restore failed: #{inspect(reason)}")}
      end
    else
      {:noreply, socket}
    end
  end

  # ── compiler controls ───────────────────────────────────────────────────────

  def handle_event("toggle_compiler_view", _params, socket) do
    view = if socket.assigns.compiler_view == :rendered, do: :raw, else: :rendered
    {:noreply, assign(socket, :compiler_view, view)}
  end

  def handle_event("set_provider", %{"provider" => prov_str}, socket) do
    provider =
      case prov_str do
        "openai" -> :openai
        "gemini" -> :gemini
        _ -> :anthropic
      end

    {:noreply, socket |> assign(:selected_provider, provider) |> refresh()}
  end

  # ── deploy ──────────────────────────────────────────────────────────────────

  def handle_event("open_deploy_modal", _params, socket) do
    {:noreply, assign(socket, :show_deploy_modal, true)}
  end

  def handle_event("close_deploy_modal", _params, socket) do
    {:noreply, assign(socket, :show_deploy_modal, false)}
  end

  def handle_event("deploy", %{"environment" => env_str}, socket) do
    case socket.assigns.graph_versions do
      [] ->
        {:noreply, put_flash(socket, :error, "Publish a version before deploying.")}

      [latest | _] ->
        env =
          case env_str do
            "staging" -> :staging
            "production" -> :production
            _ -> :dev
          end

        attrs = %{
          environment: env,
          project_id: socket.assigns.graph.project_id,
          graph_version_id: latest.id,
          deployed_version: latest.version_number
        }

        opts = ash_opts(socket)

        case Nspark.Deployments.deploy_version(attrs, opts) do
          {:ok, dep} ->
            {:noreply,
             socket
             |> assign(:show_deploy_modal, false)
             |> put_flash(
               :info,
               "Deployed v#{dep.deployed_version} to #{dep.environment} · endpoint: #{dep.endpoint_slug}"
             )}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Deploy failed: #{inspect(reason)}")}
        end
    end
  end

  # ── data ──────────────────────────────────────────────────────────────────────

  defp ash_opts(socket), do: [tenant: socket.assigns.org_id, actor: socket.assigns.current_user]

  defp mark_dirty(socket), do: assign(socket, :graph_dirty, true)

  defp load_versions(socket) do
    case socket.assigns[:graph] do
      nil ->
        assign(socket, :graph_versions, [])

      graph ->
        versions =
          Nspark.Architecture.versions_for_graph!(graph.id, tenant: socket.assigns.org_id, actor: socket.assigns.current_user)

        # Dirty on mount if no published version exists yet.
        dirty = socket.assigns[:graph_dirty] || versions == []
        socket |> assign(:graph_versions, versions) |> assign(:graph_dirty, dirty)
    end
  end

  defp create_node(type_atom, pos, socket) do
    Ash.create!(
      Node,
      %{
        type: type_atom,
        label: "New #{type_atom |> to_string() |> String.capitalize()}",
        graph_id: socket.assigns.graph.id,
        metadata: %{"position" => pos}
      },
      ash_opts(socket)
    )
  end

  defp load_from_params(socket, params, all_graphs) do
    graph =
      case params["graph_id"] do
        nil -> List.first(all_graphs)
        id -> Enum.find(all_graphs, &(&1.id == id)) || List.first(all_graphs)
      end

    if graph do
      socket
      |> assign(:graph, graph)
      |> assign(:selected, nil)
      |> assign(:graph_dirty, false)
      |> refresh()
      |> load_versions()
    else
      socket
      |> assign(:graph, nil)
      |> assign(:nodes, [])
      |> assign(:flow_nodes, [])
      |> assign(:flow_edges, [])
      |> assign(:edge_count, 0)
      |> assign(:variables, [])
      |> assign(:compiled, %{markdown: "", token_estimate: 0, included: 0, excluded: 0, cost_estimate: 0.0, provider: :anthropic})
      |> assign(:compiled_html, "")
      |> assign(:selected, nil)
      |> assign(:graph_dirty, false)
      |> assign(:graph_versions, [])
    end
  end

  defp filtered_graphs(graphs, ""), do: graphs
  defp filtered_graphs(graphs, search) do
    q = String.downcase(search)
    Enum.filter(graphs, fn g -> String.contains?(String.downcase(g.name), q) end)
  end

  defp refresh(socket) do
    %{graph: graph} = socket.assigns
    opts = ash_opts(socket)
    selected_id = socket.assigns[:selected] && socket.assigns.selected.id
    provider = socket.assigns[:selected_provider] || :anthropic

    nodes =
      Node |> filter(graph_id == ^graph.id) |> sort(inserted_at: :asc) |> Ash.read!(opts)

    edges = Edge |> filter(graph_id == ^graph.id) |> Ash.read!(opts)

    compiled = Nspark.Compiler.compile(nodes, edges, provider: provider)
    diagnostics = Nspark.Diagnostics.run(nodes, edges)

    node_diagnostics =
      Enum.reduce(diagnostics, %{}, fn diag, acc ->
        Enum.reduce(diag.node_ids, acc, fn id, acc ->
          Map.update(acc, id, diag.level, fn existing ->
            if diag.level == :error, do: :error, else: existing
          end)
        end)
      end)

    socket
    |> assign(:nodes, nodes)
    |> assign(:flow_nodes, to_flow_nodes(nodes, node_diagnostics))
    |> assign(:flow_edges, to_flow_edges(edges))
    |> assign(:edge_count, length(edges))
    |> assign(:variables, variables_in(nodes))
    |> assign(:compiled, compiled)
    |> assign(:compiled_html, render_compiled(compiled.markdown))
    |> assign(:diagnostics, diagnostics)
    |> assign(:selected, selected_id && Enum.find(nodes, &(&1.id == selected_id)))
  end

  defp render_compiled(""), do: ""
  defp render_compiled(markdown), do: MDEx.to_html!(markdown)

  # Auto-discovered {variables} across the graph (feeds the explorer + editor
  # autocomplete). See PRD "Variable System".
  defp variables_in(nodes) do
    nodes
    |> Enum.flat_map(fn n ->
      ~r/\{([a-zA-Z_]\w*)\}/
      |> Regex.scan(n.content || "")
      |> Enum.map(fn [_full, name] -> name end)
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp find(socket, id), do: Enum.find(socket.assigns.nodes, &(&1.id == id))

  defp destroy_node(id, socket) do
    opts = ash_opts(socket)

    case find(socket, id) do
      nil ->
        :ok

      node ->
        Edge
        |> filter(source_node_id == ^id or target_node_id == ^id)
        |> Ash.read!(opts)
        |> Enum.each(&Ash.destroy!(&1, opts))

        Ash.destroy!(node, opts)
    end
  end

  defp destroy_edge(id, socket) do
    opts = ash_opts(socket)

    case Edge |> filter(id == ^id) |> Ash.read_one(opts) do
      {:ok, %Edge{} = edge} -> Ash.destroy!(edge, opts)
      _ -> :ok
    end
  end

  defp palette_type(type) do
    atom = String.to_existing_atom(type)
    if atom in @palette_types, do: {:ok, atom}, else: :error
  rescue
    ArgumentError -> :error
  end

  defp format_cost(c) when c < 0.001, do: "<$0.001"
  defp format_cost(c), do: "$#{:erlang.float_to_binary(c, decimals: 4)}"

  defp diag_summary([]), do: {:ok, 0, 0}
  defp diag_summary(diags) do
    errors = Enum.count(diags, &(&1.level == :error))
    warnings = Enum.count(diags, &(&1.level == :warning))
    level = cond do
      errors > 0 -> :error
      warnings > 0 -> :warning
      true -> :ok
    end
    {level, errors, warnings}
  end

  defp diag_bar_label(:ok, _e, _w), do: "✓ Ready"
  defp diag_bar_label(:warning, _e, w), do: "⚠ #{w} warning#{if w > 1, do: "s"}"
  defp diag_bar_label(:error, e, 0), do: "✕ #{e} error#{if e > 1, do: "s"}"
  defp diag_bar_label(:error, e, w),
    do: "✕ #{e} error#{if e > 1, do: "s"} · #{w} warning#{if w > 1, do: "s"}"

  defp put_if_present(attrs, params, key, valid? \\ fn _ -> true end) do
    case Map.fetch(params, key) do
      {:ok, value} -> if valid?.(value), do: Map.put(attrs, String.to_atom(key), value), else: attrs
      :error -> attrs
    end
  end

  # ── flow serialization ──────────────────────────────────────────────────────

  defp to_flow_nodes(nodes, node_diagnostics) do
    nodes
    |> Enum.with_index()
    |> Enum.map(fn {n, i} ->
      diag =
        case Map.get(node_diagnostics, n.id) do
          :error -> "error"
          :warning -> "warning"
          nil -> nil
        end

      %{
        id: n.id,
        type: "blueprint",
        position: position_for(n, i),
        data: %{
          label: n.label,
          node_type: to_string(n.type),
          content: n.content,
          muted: n.is_muted,
          diagnostic: diag
        }
      }
    end)
  end

  defp position_for(%{metadata: %{"position" => %{"x" => x, "y" => y}}}, _i), do: %{x: x, y: y}
  defp position_for(_n, i), do: %{x: 160, y: 40 + i * 150}

  defp to_flow_edges(edges) do
    Enum.map(edges, fn e ->
      %{id: e.id, source: e.source_node_id, target: e.target_node_id, type: "smoothstep"}
    end)
  end

  # ── render ──────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.workspace flash={@flash}>
      <div class="studio">
        <div class="studio-bar">
          <div class="studio-mark"><span></span></div>
          <div class="studio-title">Newtonian&nbsp;Spark</div>
          <div class="studio-graph-wrap">
            <button type="button" phx-click="toggle_agent_picker" class="studio-graph-btn">
              <span class="studio-graph">/ {if @graph, do: @graph.name, else: "select agent"}</span>
              <span class="studio-graph-caret">{if @show_agent_picker, do: "▴", else: "▾"}</span>
            </button>
            <div :if={@graph} class="studio-chip">v{@graph.graph_version}</div>
            <%= if @show_agent_picker do %>
              <div class="studio-picker-overlay" phx-click="close_agent_picker"></div>
              <div class="agent-picker">
                <input
                  type="text"
                  value={@graph_search}
                  phx-keyup="search_agents"
                  phx-keydown="agent_picker_keydown"
                  placeholder="Search agents…"
                  class="agent-picker-search"
                  autofocus
                  phx-debounce="100"
                />
                <div class="agent-picker-list">
                  <% matches = filtered_graphs(@all_graphs, @graph_search) %>
                  <.link
                    :for={g <- matches}
                    patch={~p"/studio/#{g.id}"}
                    class={["agent-picker-item", @graph && @graph.id == g.id && "agent-picker-item--active"]}
                  >
                    <span class="agent-picker-name">{g.name}</span>
                    <span class="agent-picker-meta">v{g.graph_version}</span>
                  </.link>
                  <div :if={matches == []} class="agent-picker-empty">No agents match</div>
                </div>
              </div>
            <% end %>
          </div>
          <div class="studio-spacer"></div>
          <div class={["studio-dirty", @graph_dirty && "studio-dirty--on"]}>
            {if @graph_dirty, do: "● unsaved", else: "✓ published"}
          </div>
          <details class="relative">
            <summary class="studio-btn" style="list-style: none; cursor: pointer; user-select: none;">
              {@current_org.name} <span style="font-size: 9px; opacity: 0.6;">▾</span>
            </summary>
            <div style="position: absolute; top: 100%; right: 0; margin-top: 4px; background: oklch(0.985 0.004 245); border: 1px solid oklch(0.82 0.02 250); box-shadow: 0 4px 16px oklch(0.2 0.02 255 / 0.12); z-index: 200; min-width: 160px;">
              <a
                :for={m <- @memberships}
                href={~p"/switch-org/#{m.organization_id}"}
                style={"display: block; padding: 8px 14px; font: 500 11px/1 'IBM Plex Mono', monospace; text-decoration: none; color: #{if m.organization_id == @current_org.id, do: "oklch(0.5 0.13 255)", else: "oklch(0.38 0.02 255)"}; background: #{if m.organization_id == @current_org.id, do: "oklch(0.96 0.02 255)", else: "transparent"};"}
              >
                {m.organization.name}
              </a>
            </div>
          </details>
          <a href={~p"/org/members"} class="studio-btn" style="text-decoration: none;">Members</a>
          <button type="button" phx-click="open_new_graph_modal" class="studio-btn studio-btn--new">
            + New Agent
          </button>
          <div class="studio-btn">Import Prompt</div>
          <div class="studio-btn studio-btn--accent">✦ Import &amp; Architect</div>
          <button
            :if={@graph}
            type="button"
            phx-click="publish"
            class={["studio-btn studio-btn--solid", not @graph_dirty && "studio-btn--published"]}
            disabled={not @graph_dirty}
          >
            ▸ Publish
          </button>
          <button
            :if={@graph && @graph_versions != []}
            type="button"
            phx-click="open_deploy_modal"
            class="studio-btn studio-btn--deploy"
          >
            ⬆ Deploy
          </button>
        </div>

        <div class="studio-cols">
          <aside class="studio-rail">
            <div class="rail-head">ADD NODE</div>
            <button
              :for={{type, hue} <- @palette}
              id={"rail-#{type}"}
              type="button"
              class="rail-item"
              draggable="true"
              phx-hook="DragRailNode"
              data-node-type={type}
              phx-click="add_node"
              phx-value-type={type}
              title={"Add #{type |> to_string() |> String.capitalize()} node — drag to place"}
            >
              <span class="rail-swatch" style={"background: oklch(0.55 0.13 #{hue});"}></span>
              <span class="rail-name">{type |> to_string() |> String.capitalize()}</span>
            </button>
            <div class="rail-hint">Drag onto canvas to place · drag node to move · drag port to connect · ⌫ to delete</div>

            <div class="rail-head rail-head--mt">VARIABLES</div>
            <div :if={@variables == []} class="rail-hint">none discovered</div>
            <div :for={v <- @variables} class="rail-var">{"{" <> v <> "}"}</div>
          </aside>

          <main class="studio-canvas">
            <%= if @graph do %>
              <.svelte
                name="GraphCanvas"
                props={%{nodes: @flow_nodes, edges: @flow_edges}}
                socket={@socket}
                ssr={false}
              />
            <% else %>
              <div class="studio-empty">
                <div class="studio-empty-title">No agent graphs yet</div>
                <div class="studio-empty-body">
                  Use <code>+ New Agent</code> to create your first graph.
                </div>
              </div>
            <% end %>
          </main>

          <aside class="studio-inspector">
            <div class="insp-panel">
              <div class="insp-head">Node Inspector</div>
              <%= if @selected do %>
              <div class="insp-body">
                <div class="insp-field-label">TYPE</div>
                <div class="insp-type">{@selected.type |> to_string() |> String.upcase()}</div>

                <.form
                  for={%{}}
                  id={"node-form-#{@selected.id}"}
                  phx-change="update_node"
                  phx-submit="update_node"
                >
                  <div class="insp-field-label">LABEL</div>
                  <.input
                    type="text"
                    name="label"
                    value={@selected.label}
                    phx-debounce="500"
                  />
                </.form>

                <div class="insp-field-label">INSTRUCTION · MARKDOWN</div>
                <.svelte
                  name="CodeEditor"
                  props={%{
                    node_id: @selected.id,
                    content: @selected.content || "",
                    variables: @variables
                  }}
                  socket={@socket}
                  ssr={false}
                />

                <div class="insp-toggle">
                  <span>Include in compile</span>
                  <button
                    type="button"
                    phx-click="toggle_mute"
                    class={["insp-pill", @selected.is_muted && "insp-pill--off"]}
                  >
                    {if @selected.is_muted, do: "MUTED", else: "ON"}
                  </button>
                </div>

                <button
                  type="button"
                  phx-click="delete_node"
                  phx-value-id={@selected.id}
                  data-confirm="Delete this node and its connections?"
                  class="insp-delete"
                >
                  Delete node
                </button>
              </div>
            <% else %>
                <div class="insp-empty">Select a node to inspect it.</div>

                <%!-- Version history when no node selected --%>
                <div :if={@graph_versions != []} class="versions-panel">
                  <div class="versions-head">VERSION HISTORY</div>
                  <div class="versions-list">
                    <div :for={v <- @graph_versions} class="version-row">
                      <span class="version-num">v{v.version_number}</span>
                      <span class="version-date">{Calendar.strftime(v.inserted_at, "%b %d")}</span>
                      <button
                        type="button"
                        phx-click="restore_version"
                        phx-value-id={v.id}
                        data-confirm={"Restore to v#{v.version_number}? Current canvas will be replaced."}
                        class="version-restore-btn"
                      >
                        Restore
                      </button>
                    </div>
                  </div>
                </div>
              <% end %>

              <div class="insp-foot">
                {length(@nodes)} nodes · {@edge_count} edges
              </div>
            </div>

            <div class="compiler-panel">
              <% {diag_level, diag_errors, diag_warnings} = diag_summary(@diagnostics) %>
              <div class={["diag-bar",
                diag_level == :ok && "diag-bar--ok",
                diag_level == :warning && "diag-bar--warn",
                diag_level == :error && "diag-bar--error"
              ]}>
                {diag_bar_label(diag_level, diag_errors, diag_warnings)}
              </div>
              <div :if={@diagnostics != []} class="diag-list">
                <div
                  :for={d <- @diagnostics}
                  class={["diag-item", d.level == :error && "diag-item--error", d.level == :warning && "diag-item--warn"]}
                >
                  <span class="diag-icon">{if d.level == :error, do: "✕", else: "⚠"}</span>
                  <span class="diag-msg">{d.message}</span>
                </div>
              </div>
              <div class="compiler-head">
                <span>Live Compiler</span>
                <div class="compiler-controls">
                  <select
                    phx-change="set_provider"
                    name="provider"
                    class="compiler-select"
                  >
                    <option value="anthropic" selected={@selected_provider == :anthropic}>Anthropic</option>
                    <option value="openai" selected={@selected_provider == :openai}>OpenAI</option>
                    <option value="gemini" selected={@selected_provider == :gemini}>Gemini</option>
                  </select>
                  <button
                    type="button"
                    phx-click="toggle_compiler_view"
                    class="compiler-ctrl-btn"
                  >
                    {if @compiler_view == :rendered, do: "Raw", else: "Preview"}
                  </button>
                  <button
                    id="copy-compiled"
                    type="button"
                    phx-hook="CopyToClipboard"
                    data-content={@compiled.markdown}
                    class="compiler-ctrl-btn"
                  >
                    Copy
                  </button>
                  <span class="compiler-live"><i></i>LIVE</span>
                </div>
              </div>
              <div class="compiler-stats">
                ≈ {@compiled.token_estimate} tokens<span :if={@compiled.cost_estimate > 0}> · ~{format_cost(@compiled.cost_estimate)}</span> · {@compiled.included} nodes<span :if={@compiled.excluded > 0}> · {@compiled.excluded} muted</span>
              </div>
              <div class="compiler-body">
                <%= if @compiled_html == "" do %>
                  <div class="compiler-empty">Nothing to compile yet.</div>
                <% else %>
                  <%= if @compiler_view == :rendered do %>
                    <div class="compiler-md">{raw(@compiled_html)}</div>
                  <% else %>
                    <pre class="compiler-raw">{@compiled.markdown}</pre>
                  <% end %>
                <% end %>
              </div>
            </div>
          </aside>
        </div>
      </div>
      <%= if @show_new_graph_modal do %>
        <div class="dlg-overlay">
          <div class="dlg-backdrop" phx-click="close_new_graph_modal"></div>
          <div class="dlg-box">
            <div class="dlg-head">NEW AGENT GRAPH</div>
            <.form
              for={%{}}
              id="new-graph-form"
              phx-submit="create_graph"
              phx-change="new_graph_change"
            >
              <div class="dlg-field-label">AGENT NAME</div>
              <input
                type="text"
                name="name"
                value={@new_graph_name}
                placeholder="e.g. Customer Support Agent"
                class="dlg-input"
                autofocus
                required
              />
              <div class="dlg-field-label">DESCRIPTION <span class="dlg-optional">(optional)</span></div>
              <textarea
                name="description"
                rows="3"
                placeholder="What does this agent do?"
                class="dlg-input dlg-textarea"
              >{@new_graph_description}</textarea>
              <div class="dlg-actions">
                <button type="button" phx-click="close_new_graph_modal" class="dlg-btn dlg-btn--cancel">
                  Cancel
                </button>
                <button type="submit" class="dlg-btn dlg-btn--create" disabled={String.trim(@new_graph_name) == ""}>
                  Create Agent
                </button>
              </div>
            </.form>
          </div>
        </div>
      <% end %>
      <%= if @show_deploy_modal do %>
        <div class="dlg-overlay">
          <div class="dlg-backdrop" phx-click="close_deploy_modal"></div>
          <div class="dlg-box">
            <div class="dlg-head">DEPLOY AGENT</div>
            <div class="dlg-sub">
              Pinning version v{List.first(@graph_versions).version_number} of <strong>{@graph.name}</strong>
            </div>
            <.form for={%{}} id="deploy-form" phx-submit="deploy">
              <div class="dlg-field-label">ENVIRONMENT</div>
              <select name="environment" class="dlg-input dlg-select">
                <option value="dev">Development</option>
                <option value="staging">Staging</option>
                <option value="production">Production</option>
              </select>
              <div class="dlg-actions">
                <button type="button" phx-click="close_deploy_modal" class="dlg-btn dlg-btn--cancel">
                  Cancel
                </button>
                <button type="submit" class="dlg-btn dlg-btn--create">
                  Deploy
                </button>
              </div>
            </.form>
          </div>
        </div>
      <% end %>
    </Layouts.workspace>
    """
  end
end
