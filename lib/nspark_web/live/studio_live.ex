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
  def mount(params, _session, socket) do
    org = socket.assigns.current_org

    socket =
      case load_studio(params, org) do
        {:ok, graph} ->
          socket
          |> assign(:org_id, org.id)
          |> assign(:graph, graph)
          |> assign(:selected, nil)
          |> refresh()

        :empty ->
          socket
          |> assign(:org_id, org.id)
          |> assign(:graph, nil)
          |> assign(:nodes, [])
          |> assign(:flow_nodes, [])
          |> assign(:flow_edges, [])
          |> assign(:edge_count, 0)
          |> assign(:variables, [])
          |> assign(:compiled, %{markdown: "", token_estimate: 0, included: 0, excluded: 0})
          |> assign(:compiled_html, "")
          |> assign(:selected, nil)
      end

    {:ok,
     socket
     |> assign(:palette, @node_palette)
     |> assign(:show_new_graph_modal, false)
     |> assign(:new_graph_name, "")
     |> assign(:new_graph_description, "")}
  end

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
    nodes =
      Enum.map(socket.assigns.nodes, fn n ->
        if n.id == id do
          meta = Map.put(n.metadata || %{}, "position", %{"x" => x, "y" => y})
          Ash.update!(n, %{metadata: meta}, tenant: socket.assigns.org_id)
        else
          n
        end
      end)

    {:noreply, assign(socket, :nodes, nodes)}
  end

  # ── connect → create edge ────────────────────────────────────────────────────

  def handle_event("connect_nodes", %{"source" => s, "target" => t}, socket)
      when is_binary(s) and is_binary(t) and s != t do
    case Ash.create(
           Edge,
           %{graph_id: socket.assigns.graph.id, source_node_id: s, target_node_id: t},
           tenant: socket.assigns.org_id
         ) do
      {:ok, _edge} -> {:noreply, refresh(socket)}
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
      {:noreply, refresh(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  # ── add node from the rail (drag-drop → exact canvas position) ───────────────

  def handle_event("add_node_at", %{"type" => type, "x" => x, "y" => y}, socket) do
    with {:ok, type_atom} <- palette_type(type) do
      pos = %{"x" => x, "y" => y}
      create_node(type_atom, pos, socket)
      {:noreply, refresh(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  # ── delete (keyboard from canvas) ────────────────────────────────────────────

  def handle_event("delete_elements", params, socket) do
    org_id = socket.assigns.org_id
    Enum.each(Map.get(params, "edges", []), &destroy_edge(&1, org_id))
    Enum.each(Map.get(params, "nodes", []), &destroy_node(&1, socket, org_id))
    {:noreply, socket |> assign(:selected, nil) |> refresh()}
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

        _ = Ash.update!(node, attrs, tenant: socket.assigns.org_id)
        {:noreply, refresh(socket)}
    end
  end

  def handle_event("update_node_content", params, socket) do
    id = Map.get(params, "id") || (socket.assigns.selected && socket.assigns.selected.id)
    content = Map.get(params, "content", "")

    case id && find(socket, id) do
      nil ->
        {:noreply, socket}

      node ->
        _ = Ash.update!(node, %{content: content}, tenant: socket.assigns.org_id)
        {:noreply, refresh(socket)}
    end
  end

  def handle_event("toggle_mute", _params, socket) do
    case socket.assigns.selected do
      nil ->
        {:noreply, socket}

      node ->
        _ = Ash.update!(node, %{is_muted: !node.is_muted}, tenant: socket.assigns.org_id)
        {:noreply, refresh(socket)}
    end
  end

  def handle_event("delete_node", %{"id" => id}, socket) do
    destroy_node(id, socket, socket.assigns.org_id)
    {:noreply, socket |> assign(:selected, nil) |> refresh()}
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
      org_id = socket.assigns.org_id

      project_id =
        case Project |> Ash.read!(tenant: org_id) do
          [p | _] -> p.id
          [] ->
            p = Ash.create!(Project, %{name: "Default", status: :active}, tenant: org_id)
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

      graph = Ash.create!(Graph, attrs, tenant: org_id)

      {:noreply,
       socket
       |> assign(:show_new_graph_modal, false)
       |> push_navigate(to: ~p"/studio/#{graph.id}")}
    end
  end

  # ── data ──────────────────────────────────────────────────────────────────────

  defp create_node(type_atom, pos, socket) do
    Ash.create!(
      Node,
      %{
        type: type_atom,
        label: "New #{type_atom |> to_string() |> String.capitalize()}",
        graph_id: socket.assigns.graph.id,
        metadata: %{"position" => pos}
      },
      tenant: socket.assigns.org_id
    )
  end

  defp load_studio(params, org) do
    graphs = Ash.read!(Graph, tenant: org.id)

    graph =
      case params["graph_id"] do
        nil -> List.first(graphs)
        id -> Enum.find(graphs, &(&1.id == id)) || List.first(graphs)
      end

    if graph, do: {:ok, graph}, else: :empty
  end

  defp refresh(socket) do
    %{org_id: org_id, graph: graph} = socket.assigns
    selected_id = socket.assigns[:selected] && socket.assigns.selected.id

    nodes =
      Node |> filter(graph_id == ^graph.id) |> sort(inserted_at: :asc) |> Ash.read!(tenant: org_id)

    edges = Edge |> filter(graph_id == ^graph.id) |> Ash.read!(tenant: org_id)

    compiled = Nspark.Compiler.compile(nodes)

    socket
    |> assign(:nodes, nodes)
    |> assign(:flow_nodes, to_flow_nodes(nodes))
    |> assign(:flow_edges, to_flow_edges(edges))
    |> assign(:edge_count, length(edges))
    |> assign(:variables, variables_in(nodes))
    |> assign(:compiled, compiled)
    |> assign(:compiled_html, render_compiled(compiled.markdown))
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

  defp destroy_node(id, socket, org_id) do
    case find(socket, id) do
      nil ->
        :ok

      node ->
        Edge
        |> filter(source_node_id == ^id or target_node_id == ^id)
        |> Ash.read!(tenant: org_id)
        |> Enum.each(&Ash.destroy!(&1, tenant: org_id))

        Ash.destroy!(node, tenant: org_id)
    end
  end

  defp destroy_edge(id, org_id) do
    case Edge |> filter(id == ^id) |> Ash.read_one(tenant: org_id) do
      {:ok, %Edge{} = edge} -> Ash.destroy!(edge, tenant: org_id)
      _ -> :ok
    end
  end

  defp palette_type(type) do
    atom = String.to_existing_atom(type)
    if atom in @palette_types, do: {:ok, atom}, else: :error
  rescue
    ArgumentError -> :error
  end

  defp put_if_present(attrs, params, key, valid? \\ fn _ -> true end) do
    case Map.fetch(params, key) do
      {:ok, value} -> if valid?.(value), do: Map.put(attrs, String.to_atom(key), value), else: attrs
      :error -> attrs
    end
  end

  # ── flow serialization ──────────────────────────────────────────────────────

  defp to_flow_nodes(nodes) do
    nodes
    |> Enum.with_index()
    |> Enum.map(fn {n, i} ->
      %{
        id: n.id,
        type: "blueprint",
        position: position_for(n, i),
        data: %{
          label: n.label,
          node_type: to_string(n.type),
          content: n.content,
          muted: n.is_muted
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
          <div class="studio-graph">/ {if @graph, do: @graph.name, else: "no graph"}</div>
          <div :if={@graph} class="studio-chip">v{@graph.graph_version}</div>
          <div class="studio-spacer"></div>
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
          <button type="button" phx-click="open_new_graph_modal" class="studio-btn studio-btn--new">
            + New Agent
          </button>
          <div class="studio-btn">Import Prompt</div>
          <div class="studio-btn studio-btn--accent">✦ Import &amp; Architect</div>
          <div class="studio-btn studio-btn--solid">▸ Compile</div>
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
              <% end %>

              <div class="insp-foot">
                {length(@nodes)} nodes · {@edge_count} edges
              </div>
            </div>

            <div class="compiler-panel">
              <div class="compiler-head">
                <span>Live Compiler</span>
                <span class="compiler-live"><i></i>LIVE</span>
              </div>
              <div class="compiler-stats">
                ≈ {@compiled.token_estimate} tokens · {@compiled.included} nodes<span :if={
                  @compiled.excluded > 0
                }>· {@compiled.excluded} muted</span>
              </div>
              <div class="compiler-body">
                <%= if @compiled_html == "" do %>
                  <div class="compiler-empty">Nothing to compile yet.</div>
                <% else %>
                  <div class="compiler-md">{raw(@compiled_html)}</div>
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
    </Layouts.workspace>
    """
  end
end
