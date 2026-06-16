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
    {:output, 300},
    {:agent, 255}
  ]
  @palette_types Enum.map(@node_palette, fn {t, _} -> t end)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:org_id, socket.assigns.current_org.id)
     |> assign(:current_role, current_role(socket.assigns.current_user, socket.assigns.current_org.id))
     # graph canvas state — populated by handle_params
     |> assign(:graph, nil)
     |> assign(:nodes, [])
     |> assign(:flow_nodes, [])
     |> assign(:flow_edges, [])
     |> assign(:edges, [])
     |> assign(:edge_count, 0)
     |> assign(:variables, [])
     |> assign(:compiled, %{markdown: "", token_estimate: 0, included: 0, excluded: 0, cost_estimate: 0.0, provider: :anthropic, resolved_assets: []})
     |> assign(:compiled_html, "")
     |> assign(:selected, nil)
     |> assign(:graph_dirty, false)
     |> assign(:graph_versions, [])
     |> assign(:diagnostics, [])
     |> assign(:selected_variable, nil)
     |> assign(:variable_producers, [])
     |> assign(:variable_consumers, [])
     # registry
     |> assign(:registry_items, [])
     |> assign(:packages, [])
     |> assign(:registry_search, "")
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
     |> assign(:show_skill_modal, false)
     |> assign(:skill_detail, nil)
     |> assign(:show_new_skill_modal, false)
     |> assign(:new_skill_name, "")
     |> assign(:new_skill_description, "")
     |> assign(:new_skill_content, "")
     |> assign(:skill_suggestions, [])
     |> assign(:show_suggestions_modal, false)
     |> assign(:zen, nil)
     |> assign(:compiler_view, :rendered)
     |> assign(:selected_provider, :anthropic)
     # architect
     |> assign(:show_architect_modal, false)
     |> assign(:architect_loading, false)
     |> assign(:architect_error, nil)}
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
      |> assign(:zen, zen_mode(params["zen"]))
      |> load_from_params(params, all_graphs)
      |> load_registry()

    {:noreply, socket}
  end

  # ── zen view (fullscreen canvas / compiler) ──────────────────────────────────
  #
  # Zen state is driven entirely by the `zen` query param so the Svelte canvas
  # stays mounted in place — CSS on `.studio` hides the surrounding chrome rather
  # than re-rendering the canvas into a new container (which would reset zoom).

  defp zen_mode("canvas"), do: :canvas
  defp zen_mode("compiler"), do: :compiler
  defp zen_mode(_), do: nil

  defp zen_path(socket, mode) do
    base = if socket.assigns.graph, do: ~p"/studio/#{socket.assigns.graph.id}", else: ~p"/studio"
    if mode, do: "#{base}?zen=#{mode}", else: base
  end

  def handle_event("enter_zen", %{"mode" => mode}, socket) when mode in ["canvas", "compiler"] do
    {:noreply, push_patch(socket, to: zen_path(socket, mode))}
  end

  def handle_event("exit_zen", _params, socket) do
    {:noreply, push_patch(socket, to: zen_path(socket, nil))}
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
    {:noreply, socket |> assign(:selected, find(socket, id)) |> clear_var_selection()}
  end

  def handle_event("select_node", _params, socket) do
    {:noreply, socket |> assign(:selected, nil) |> clear_var_selection()}
  end

  def handle_event("select_variable", %{"name" => name}, socket) do
    socket =
      if socket.assigns.selected_variable == name do
        socket
        |> assign(:selected_variable, nil)
        |> assign(:variable_producers, [])
        |> assign(:variable_consumers, [])
      else
        {producers, consumers} = compute_variable_info(name, socket.assigns.nodes)

        socket
        |> assign(:selected, nil)
        |> assign(:selected_variable, name)
        |> assign(:variable_producers, producers)
        |> assign(:variable_consumers, consumers)
      end

    {:noreply, apply_var_highlight(socket)}
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

  def handle_event("connect_nodes", %{"source" => s, "target" => t} = params, socket)
      when is_binary(s) and is_binary(t) and s != t do
    branch = Map.get(params, "sourceHandle")
    metadata = if branch, do: %{"branch" => branch, "label" => branch}, else: %{}

    case Ash.create(
           Edge,
           %{
             graph_id: socket.assigns.graph.id,
             source_node_id: s,
             target_node_id: t,
             metadata: metadata
           },
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

  def handle_event("update_agent_metadata", params, socket) do
    case socket.assigns.selected do
      %{type: :agent} = node ->
        meta = node.metadata || %{}

        meta =
          meta
          |> then(fn m ->
            case Map.get(params, "source_graph_id") do
              nil -> m
              "" -> Map.put(m, "source_graph_id", nil)
              id -> Map.put(m, "source_graph_id", id)
            end
          end)
          |> then(fn m ->
            case Map.get(params, "output_var") do
              nil -> m
              v -> Map.put(m, "output_var", String.trim(v))
            end
          end)
          |> then(fn m ->
            case Map.get(params, "on_error") do
              e when e in ["fail", "continue"] -> Map.put(m, "on_error", e)
              _ -> m
            end
          end)
          |> then(fn m ->
            case Integer.parse(Map.get(params, "timeout_ms", "")) do
              {ms, ""} when ms >= 500 -> Map.put(m, "timeout_ms", ms)
              _ -> m
            end
          end)

        _ = Ash.update!(node, %{metadata: meta}, ash_opts(socket))
        {:noreply, socket |> refresh() |> mark_dirty()}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_node", %{"id" => id}, socket) do
    destroy_node(id, socket)
    {:noreply, socket |> assign(:selected, nil) |> refresh() |> mark_dirty()}
  end

  # ── registry: add linked node ────────────────────────────────────────────────

  def handle_event("add_registry_node_at", %{"asset_id" => id, "asset_type" => type, "x" => x, "y" => y}, socket) do
    if socket.assigns.graph do
      create_linked_node(id, type, %{"x" => x, "y" => y}, socket)
      {:noreply, socket |> refresh() |> mark_dirty()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("add_registry_node", %{"asset_id" => id, "asset_type" => type}, socket) do
    if socket.assigns.graph do
      count = length(socket.assigns.nodes)
      pos = %{"x" => 440, "y" => 60 + rem(count, 8) * 44}
      create_linked_node(id, type, pos, socket)
      {:noreply, socket |> refresh() |> mark_dirty()}
    else
      {:noreply, socket}
    end
  end

  # ── registry: convert / detach ───────────────────────────────────────────────

  def handle_event("convert_to_skill", _params, socket) do
    case socket.assigns.selected do
      %{type: :skill, source_asset_id: nil} = node ->
        opts = ash_opts(socket)

        case Ash.create(
               Nspark.Registry.Skill,
               %{name: node.label, content: node.content || ""},
               opts
             ) do
          {:ok, skill} ->
            # The node becomes a content-less linked node; the Skill is now the
            # single source of truth and is resolved at compile time.
            _ = Ash.update!(node, %{source_asset_id: skill.id, content: nil}, opts)

            {:noreply,
             socket
             |> load_registry()
             |> refresh()
             |> put_flash(:info, "Saved as Skill \"#{skill.name}\"")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to save skill: #{inspect(reason)}")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("inspect_skill", %{"skill_id" => id}, socket) do
    opts = ash_opts(socket)

    case Ash.get(Nspark.Registry.Skill, id, opts) do
      {:ok, skill} ->
        usage = Nspark.Registry.skill_usage(id, opts)

        {:noreply,
         assign(socket, show_skill_modal: true, skill_detail: %{skill: skill, usage: usage})}

      _ ->
        {:noreply, put_flash(socket, :error, "Skill not found.")}
    end
  end

  def handle_event("close_skill_modal", _params, socket) do
    {:noreply, assign(socket, :show_skill_modal, false)}
  end

  def handle_event("publish_skill", %{"skill_id" => id}, socket),
    do: transition_skill(socket, id, :publish, "published")

  def handle_event("archive_skill", %{"skill_id" => id}, socket),
    do: transition_skill(socket, id, :archive, "archived")

  # ── registry suggestions (refactor duplicates → shared skill) ────────────────

  def handle_event("open_suggestions", _params, socket) do
    {:noreply, assign(socket, :show_suggestions_modal, true)}
  end

  def handle_event("close_suggestions", _params, socket) do
    {:noreply, assign(socket, :show_suggestions_modal, false)}
  end

  def handle_event("extract_shared_skill", %{"signature" => signature}, socket) do
    opts = ash_opts(socket)

    case Enum.find(socket.assigns.skill_suggestions, &(&1.signature == signature)) do
      nil ->
        {:noreply, socket}

      group ->
        case Ash.create(Nspark.Registry.Skill, %{name: group.label, content: group.content}, opts) do
          {:ok, skill} ->
            # Link every duplicate node (across graphs) to the new Skill and drop
            # its copied content — the Skill is now the single source of truth.
            Enum.each(group.node_ids, fn node_id ->
              case Ash.get(Node, node_id, opts) do
                {:ok, node} -> Ash.update!(node, %{source_asset_id: skill.id, content: nil}, opts)
                _ -> :ok
              end
            end)

            {:noreply,
             socket
             |> load_registry()
             |> refresh()
             |> then(fn s -> assign(s, :show_suggestions_modal, s.assigns.skill_suggestions != []) end)
             |> put_flash(:info, "Extracted Skill \"#{skill.name}\" — linked #{group.count} nodes across #{length(group.graphs)} graph(s).")}

          {:error, %Ash.Error.Forbidden{}} ->
            {:noreply, put_flash(socket, :error, "You need editor access to extract skills.")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Could not extract skill.")}
        end
    end
  end

  # ── new skill modal ──────────────────────────────────────────────────────────

  def handle_event("open_new_skill_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_new_skill_modal, true)
     |> assign(:new_skill_name, "")
     |> assign(:new_skill_description, "")
     |> assign(:new_skill_content, "")}
  end

  def handle_event("close_new_skill_modal", _params, socket) do
    {:noreply, assign(socket, :show_new_skill_modal, false)}
  end

  def handle_event("new_skill_change", params, socket) do
    {:noreply,
     socket
     |> assign(:new_skill_name, Map.get(params, "name", ""))
     |> assign(:new_skill_description, Map.get(params, "description", ""))
     |> assign(:new_skill_content, Map.get(params, "content", ""))}
  end

  def handle_event("create_skill", params, socket) do
    name = params |> Map.get("name", "") |> String.trim()

    if name == "" do
      {:noreply, socket}
    else
      attrs = %{
        name: name,
        description: blank_to_nil(Map.get(params, "description", "")),
        content: Map.get(params, "content", "")
      }

      case Ash.create(Nspark.Registry.Skill, attrs, ash_opts(socket)) do
        {:ok, skill} ->
          {:noreply,
           socket
           |> assign(:show_new_skill_modal, false)
           |> load_registry()
           |> put_flash(:info, "Created Skill \"#{skill.name}\" (draft).")}

        {:error, %Ash.Error.Forbidden{}} ->
          {:noreply, put_flash(socket, :error, "You need editor access to create skills.")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Could not create skill.")}
      end
    end
  end

  def handle_event("detach_node", _params, socket) do
    case socket.assigns.selected do
      nil ->
        {:noreply, socket}

      node ->
        # Detach = clone: copy the currently-resolved content into the node so it
        # becomes a usable standalone node rather than an empty one.
        content = resolved_content_for(node, socket.assigns.registry_items)
        _ = Ash.update!(node, %{source_asset_id: nil, content: content}, ash_opts(socket))
        {:noreply, socket |> refresh() |> put_flash(:info, "Node detached — content copied from the Skill.")}
    end
  end

  defp resolved_content_for(%{source_asset_id: nil} = node, _items), do: node.content

  defp resolved_content_for(%{source_asset_id: id} = node, items) do
    case Enum.find(items, &(&1.id == id)) do
      %{content: content} -> content
      _ -> node.content
    end
  end

  # ── packages: install ────────────────────────────────────────────────────────

  def handle_event("install_package", %{"package_id" => pkg_id}, socket) do
    if is_nil(socket.assigns.graph) do
      {:noreply, put_flash(socket, :error, "Select or create a graph first.")}
    else
      opts = ash_opts(socket)
      alias Nspark.Registry.{Package, PackageItem}

      with {:ok, pkg} <- Ash.get(Package, pkg_id, opts),
           {:ok, items} <- Ash.read(PackageItem |> Ash.Query.filter(package_id == ^pkg.id), opts) do
        count = length(socket.assigns.nodes)

        Enum.with_index(items, count)
        |> Enum.each(fn {item, idx} ->
          col = rem(idx, 3)
          row = div(idx, 3)
          pos = %{"x" => col * 320 + 60, "y" => row * 200 + 60}
          create_linked_node(to_string(item.asset_id), to_string(item.asset_type), pos, socket)
        end)

        {:noreply,
         socket
         |> refresh()
         |> mark_dirty()
         |> put_flash(:info, "Installed package \"#{pkg.name}\" (#{length(items)} nodes).")}
      else
        _ -> {:noreply, put_flash(socket, :error, "Failed to load package.")}
      end
    end
  end

  # ── registry: search ─────────────────────────────────────────────────────────

  def handle_event("registry_search_change", %{"value" => q}, socket) do
    {:noreply, assign(socket, :registry_search, q)}
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

      {:error, {:unresolved_skills, problems}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Can't publish: #{length(problems)} linked Skill#{if length(problems) > 1, do: "s"} could not be resolved. Fix the highlighted nodes first."
         )}

      {:error, {:breaking_change, diff}} ->
        reasons = diff["reasons"] |> Enum.take(3) |> Enum.join("; ")

        {:noreply,
         put_flash(
           socket,
           :error,
           "Breaking change vs the last version (#{reasons}). It was not published."
         )}

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

  # ── AI Architect ─────────────────────────────────────────────────────────────

  def handle_event("open_architect", _params, socket) do
    {:noreply, assign(socket, show_architect_modal: true, architect_error: nil)}
  end

  def handle_event("close_architect", _params, socket) do
    {:noreply, assign(socket, show_architect_modal: false, architect_loading: false, architect_error: nil)}
  end

  def handle_event("run_architect", %{"prompt" => prompt}, socket) do
    if is_nil(socket.assigns.graph) do
      {:noreply, put_flash(socket, :error, "Select or create a graph first.")}
    else
      graph = socket.assigns.graph

      # Subscribe so the Oban worker can broadcast back to us.
      Phoenix.PubSub.subscribe(Nspark.PubSub, "architect:#{graph.id}")

      %{
        "prompt" => String.trim(prompt),
        "graph_id" => graph.id,
        "org_id" => socket.assigns.org_id,
        "user_id" => socket.assigns.current_user.id
      }
      |> Nspark.Workers.ArchitectWorker.new()
      |> Oban.insert!()

      {:noreply, assign(socket, architect_loading: true, architect_error: nil)}
    end
  end

  @impl true
  def handle_info({:architect_done, :ok, _ids}, socket) do
    Phoenix.PubSub.unsubscribe(Nspark.PubSub, "architect:#{socket.assigns.graph.id}")

    socket =
      socket
      |> assign(show_architect_modal: false, architect_loading: false, architect_error: nil)
      |> assign(:graph_dirty, true)
      |> refresh()

    {:noreply, put_flash(socket, :info, "Graph architected — review and publish when ready.")}
  end

  def handle_info({:architect_done, :error, reason}, socket) do
    Phoenix.PubSub.unsubscribe(Nspark.PubSub, "architect:#{socket.assigns.graph.id}")
    {:noreply, assign(socket, architect_loading: false, architect_error: reason)}
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
    base_meta = %{"position" => pos}

    meta =
      if type_atom == :agent do
        Map.merge(base_meta, %{
          "output_var" => "",
          "input_mapping" => %{},
          "on_error" => "fail",
          "source_graph_id" => nil,
          "source_deployment_id" => nil
        })
      else
        base_meta
      end

    Ash.create!(
      Node,
      %{
        type: type_atom,
        label: "New #{type_atom |> to_string() |> String.capitalize()}",
        graph_id: socket.assigns.graph.id,
        metadata: meta
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
      |> assign(:edges, [])
      |> assign(:flow_nodes, [])
      |> assign(:flow_edges, [])
      |> assign(:edge_count, 0)
      |> assign(:variables, [])
      |> assign(:compiled, %{markdown: "", token_estimate: 0, included: 0, excluded: 0, cost_estimate: 0.0, provider: :anthropic, resolved_assets: []})
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

    # Resolve linked Skill nodes from the Registry before compiling so the graph
    # is the single source of truth (Knowledge Layer, plan Phase 2). Compile,
    # ordering, diagnostics, and variable analysis all run over resolved content;
    # `nodes` stays the raw set so the inspector still edits the real records.
    resolution = Nspark.Registry.resolve_skills(nodes, opts)
    resolved_nodes = resolution.nodes

    compiled =
      Nspark.Compiler.compile(resolved_nodes, edges,
        provider: provider,
        resolved_assets: resolution.manifest
      )

    node_order = Nspark.Compiler.node_order(resolved_nodes, edges)

    diagnostics =
      Nspark.Registry.resolution_diagnostics(resolution.problems) ++
        Nspark.Diagnostics.run(resolved_nodes, edges)

    node_diagnostics = build_node_diagnostics(diagnostics)
    var_node_ids = var_node_ids_for(socket.assigns[:selected_variable], resolved_nodes)
    parallel_ids = parallel_agent_ids(resolved_nodes, edges)

    {var_producers, var_consumers} =
      case socket.assigns[:selected_variable] do
        nil -> {[], []}
        name -> compute_variable_info(name, resolved_nodes)
      end

    socket
    |> assign(:nodes, nodes)
    |> assign(:edges, edges)
    |> assign(:flow_nodes, to_flow_nodes(nodes, node_diagnostics, var_node_ids, node_order, parallel_ids))
    |> assign(:flow_edges, to_flow_edges(edges))
    |> assign(:edge_count, length(edges))
    |> assign(:variables, variables_in(resolved_nodes))
    |> assign(:compiled, compiled)
    |> assign(:compiled_html, render_compiled(compiled.markdown))
    |> assign(:diagnostics, diagnostics)
    |> assign(:variable_producers, var_producers)
    |> assign(:variable_consumers, var_consumers)
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

  defp resolved_assets_title(assets) do
    "Resolved skills: " <> Enum.map_join(assets, ", ", &"#{&1.name} v#{&1.version}")
  end

  # Manifest read back from JSONB has string keys.
  defp version_skills_title(skills) do
    "Pinned skills: " <>
      Enum.map_join(skills, ", ", fn s ->
        "#{s["name"] || s[:name]} v#{s["version"] || s[:version]}"
      end)
  end

  defp current_role(user, org_id) do
    user.id
    |> Nspark.Accounts.memberships_for_user!()
    |> Enum.find_value(fn m -> if m.organization_id == org_id, do: m.role end)
  end

  defp admin_role?(role), do: role in [:admin, :owner]

  defp transition_skill(socket, id, action, verb) do
    opts = ash_opts(socket)

    with {:ok, skill} <- Ash.get(Nspark.Registry.Skill, id, opts),
         {:ok, updated} <- Ash.update(skill, %{}, Keyword.put(opts, :action, action)) do
      {:noreply,
       socket
       |> load_registry()
       |> assign(:skill_detail, %{skill: updated, usage: Nspark.Registry.skill_usage(id, opts)})
       |> put_flash(:info, "Skill #{verb}.")}
    else
      {:error, %Ash.Error.Forbidden{}} ->
        {:noreply, put_flash(socket, :error, "Only admins can #{action} skills.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not #{action} skill.")}
    end
  end

  defp skill_publish_confirm(%{skill: s, usage: u}) do
    "Publish v#{s.version + 1} of \"#{s.name}\"? Affects #{length(u.graphs)} graph(s) and " <>
      "#{length(u.deployments)} live deployment(s). Deployments keep their pinned version " <>
      "until each graph is re-published."
  end

  defp usage_summary(%{graphs: graphs, deployments: deployments}) do
    graphs_text = "Used in #{length(graphs)} graph(s): " <> Enum.map_join(graphs, ", ", & &1.name)

    case deployments do
      [] -> graphs_text
      ds -> graphs_text <> " · #{length(ds)} deployment(s)"
    end
  end

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

  defp blank_to_nil(value) do
    case String.trim(value || "") do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp load_registry(socket) do
    opts = ash_opts(socket)

    alias Nspark.Registry.{Skill, Policy, Schema, MemoryTemplate, Package}

    usage = Nspark.Registry.skill_usage_index(opts)

    items =
      Enum.map(Ash.read!(Skill, opts), &to_registry_item(&1, :skill, Map.get(usage, &1.id))) ++
      Enum.map(Ash.read!(Policy, opts), &to_registry_item(&1, :policy)) ++
      Enum.map(Ash.read!(Schema, opts), &to_registry_item(&1, :schema)) ++
      Enum.map(Ash.read!(MemoryTemplate, opts), &to_registry_item(&1, :memory_template))

    packages = Ash.read!(Package, opts) |> Enum.map(&to_package_item/1)

    socket
    |> assign(:registry_items, items)
    |> assign(:packages, packages)
    |> assign(:skill_suggestions, Nspark.Registry.duplicate_skill_candidates(opts))
  end

  defp to_registry_item(resource, asset_type, usage \\ nil) do
    %{
      id: resource.id,
      name: resource.name,
      description: resource.description,
      content: resource.content,
      status: resource.status,
      asset_type: asset_type,
      usage: usage
    }
  end

  defp to_package_item(pkg) do
    %{
      id: pkg.id,
      name: pkg.name,
      description: pkg.description,
      version: pkg.version,
      status: pkg.status
    }
  end

  defp create_linked_node(asset_id, asset_type, pos, socket) do
    item = Enum.find(socket.assigns.registry_items, &(&1.id == asset_id))

    if item do
      Ash.create!(
        Node,
        %{
          type: registry_node_type(asset_type),
          label: item.name,
          # Linked Skill nodes own no content — it's resolved from the Skill at
          # compile time. Other linked asset types still carry a content copy
          # (they have no resolver yet; out of scope this phase).
          content: if(asset_type == "skill", do: nil, else: item.content),
          source_asset_id: asset_id,
          graph_id: socket.assigns.graph.id,
          metadata: %{"position" => pos}
        },
        ash_opts(socket)
      )
    end
  end

  defp registry_node_type("skill"), do: :skill
  defp registry_node_type("policy"), do: :constraint
  defp registry_node_type("schema"), do: :output
  defp registry_node_type("memory_template"), do: :memory
  defp registry_node_type(_), do: :skill

  defp filter_registry(items, ""), do: items

  defp filter_registry(items, q) do
    q = String.downcase(q)

    Enum.filter(items, fn item ->
      String.contains?(String.downcase(item.name), q) or
        (is_binary(item.description) and String.contains?(String.downcase(item.description), q))
    end)
  end

  defp registry_group_label(:skill), do: "SKILLS"
  defp registry_group_label(:policy), do: "POLICIES"
  defp registry_group_label(:schema), do: "SCHEMAS"
  defp registry_group_label(:memory_template), do: "MEMORY"

  defp registry_hue(:skill), do: 220
  defp registry_hue(:policy), do: 28
  defp registry_hue(:schema), do: 300
  defp registry_hue(:memory_template), do: 330

  defp registry_type_label(:skill), do: "SKILL"
  defp registry_type_label(:policy), do: "POLICY"
  defp registry_type_label(:schema), do: "SCHEMA"
  defp registry_type_label(:memory_template), do: "MEMORY"
  defp registry_type_label(_), do: "ASSET"

  defp build_node_diagnostics(diagnostics) do
    Enum.reduce(diagnostics, %{}, fn diag, acc ->
      Enum.reduce(diag.node_ids, acc, fn id, acc ->
        Map.update(acc, id, diag.level, fn existing ->
          if diag.level == :error, do: :error, else: existing
        end)
      end)
    end)
  end

  defp var_node_ids_for(nil, _nodes), do: %{}

  defp var_node_ids_for(name, nodes) do
    {producers, consumers} = compute_variable_info(name, nodes)
    Map.merge(
      Map.new(producers, &{&1.id, "producer"}),
      Map.new(consumers, &{&1.id, "consumer"})
    )
  end

  defp compute_variable_info(var_name, nodes) do
    pattern = "{#{var_name}}"
    provider_types = [:context, :memory]

    producers =
      Enum.filter(nodes, fn n ->
        n.type in provider_types and
          is_binary(n.content) and
          String.contains?(n.content, pattern)
      end)

    consumers =
      Enum.filter(nodes, fn n ->
        n.type not in provider_types and
          is_binary(n.content) and
          String.contains?(n.content, pattern)
      end)

    {producers, consumers}
  end

  defp apply_var_highlight(socket) do
    nodes = socket.assigns.nodes
    edges = socket.assigns.edges
    node_diag = build_node_diagnostics(socket.assigns.diagnostics)
    var_node_ids = var_node_ids_for(socket.assigns.selected_variable, nodes)
    node_order = Nspark.Compiler.node_order(nodes, edges)
    parallel_ids = parallel_agent_ids(nodes, edges)
    assign(socket, :flow_nodes, to_flow_nodes(nodes, node_diag, var_node_ids, node_order, parallel_ids))
  end

  defp clear_var_selection(socket) do
    if socket.assigns.selected_variable do
      socket
      |> assign(:selected_variable, nil)
      |> assign(:variable_producers, [])
      |> assign(:variable_consumers, [])
      |> apply_var_highlight()
    else
      socket
    end
  end

  # ── flow serialization ──────────────────────────────────────────────────────

  # Returns the set of agent node IDs that share a dependency wave with at least
  # one other agent node (i.e., will be dispatched in parallel by the orchestrator).
  defp parallel_agent_ids(nodes, edges) do
    agent_nodes = Enum.filter(nodes, &(&1.type == :agent))

    if length(agent_nodes) < 2 do
      MapSet.new()
    else
      output_var_to_id =
        Map.new(agent_nodes, fn n ->
          {(n.metadata || %{}) |> Map.get("output_var", ""), n.id}
        end)

      dep_map =
        Map.new(agent_nodes, fn n ->
          input_vars =
            (n.metadata || %{}) |> Map.get("input_mapping", %{}) |> Map.values()

          deps =
            Enum.flat_map(input_vars, fn var ->
              case Map.get(output_var_to_id, var) do
                nil -> []
                dep_id -> [dep_id]
              end
            end)
            |> MapSet.new()

          {n.id, deps}
        end)

      # Also account for edges between agent nodes (sequential dependencies).
      agent_ids = MapSet.new(agent_nodes, & &1.id)

      dep_map =
        Enum.reduce(edges, dep_map, fn e, acc ->
          src = e.source_node_id
          tgt = e.target_node_id

          if MapSet.member?(agent_ids, src) and MapSet.member?(agent_ids, tgt) do
            Map.update(acc, tgt, MapSet.new([src]), &MapSet.put(&1, src))
          else
            acc
          end
        end)

      wave_map = compute_agent_wave_map(agent_nodes, dep_map)

      wave_map
      |> Enum.group_by(fn {_id, wave} -> wave end, fn {id, _} -> id end)
      |> Enum.flat_map(fn {_wave, ids} ->
        if length(ids) > 1, do: ids, else: []
      end)
      |> MapSet.new()
    end
  end

  defp compute_agent_wave_map(agent_nodes, dep_map) do
    Enum.reduce(agent_nodes, %{}, fn n, acc ->
      wave = compute_agent_wave(n.id, dep_map, acc, MapSet.new())
      Map.put(acc, n.id, wave)
    end)
  end

  defp compute_agent_wave(node_id, dep_map, wave_map, visited) do
    if MapSet.member?(visited, node_id) do
      0
    else
      deps = Map.get(dep_map, node_id, MapSet.new())

      if MapSet.size(deps) == 0 do
        0
      else
        visited = MapSet.put(visited, node_id)

        deps
        |> Enum.map(fn dep_id ->
          case Map.get(wave_map, dep_id) do
            nil -> compute_agent_wave(dep_id, dep_map, wave_map, visited)
            w -> w
          end
        end)
        |> Enum.max()
        |> Kernel.+(1)
      end
    end
  end

  defp to_flow_nodes(nodes, node_diagnostics, var_node_ids, node_order, parallel_ids) do
    nodes
    |> Enum.with_index()
    |> Enum.map(fn {n, i} ->
      diag =
        case Map.get(node_diagnostics, n.id) do
          :error -> "error"
          :warning -> "warning"
          nil -> nil
        end

      meta = n.metadata || %{}

      %{
        id: n.id,
        type: cond do
          n.type == :conditional -> "conditional"
          n.type == :agent -> "agent"
          true -> "blueprint"
        end,
        position: position_for(n, i),
        data: %{
          label: n.label,
          node_type: to_string(n.type),
          content: n.content,
          muted: n.is_muted,
          diagnostic: diag,
          var_role: Map.get(var_node_ids, n.id),
          compile_order: Map.get(node_order, n.id),
          linked: not is_nil(n.source_asset_id),
          agent_name: Map.get(meta, "agent_name") || n.label,
          output_var: Map.get(meta, "output_var"),
          input_mapping: Map.get(meta, "input_mapping", %{}),
          on_error: Map.get(meta, "on_error", "fail"),
          deployment_version: Map.get(meta, "deployment_version"),
          timeout_ms: Map.get(meta, "timeout_ms", 10_000),
          parallel: n.type == :agent and MapSet.member?(parallel_ids, n.id)
        }
      }
    end)
  end

  defp position_for(%{metadata: %{"position" => %{"x" => x, "y" => y}}}, _i), do: %{x: x, y: y}
  defp position_for(_n, i), do: %{x: 160, y: 40 + i * 150}

  defp to_flow_edges(edges) do
    Enum.map(edges, fn e ->
      %{
        id: e.id,
        source: e.source_node_id,
        target: e.target_node_id,
        sourceHandle: Map.get(e.metadata, "branch"),
        label: Map.get(e.metadata, "label"),
        type: "smoothstep"
      }
    end)
  end

  # ── render ──────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.workspace flash={@flash}>
      <div
        :if={@zen}
        id="zen-escape"
        phx-window-keydown="exit_zen"
        phx-key="Escape"
        style="display: none;"
      >
      </div>
      <button :if={@zen} type="button" phx-click="exit_zen" class="zen-exit">
        Esc ⤶ Exit Zen
      </button>
      <div class={[
        "studio",
        @zen == :canvas && "studio--zen-canvas",
        @zen == :compiler && "studio--zen-compiler"
      ]}>
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
          <button
            :if={@graph}
            type="button"
            phx-click="open_architect"
            class="studio-btn studio-btn--accent"
          >
            ✦ Architect
          </button>
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
            <button
              :for={v <- @variables}
              type="button"
              class={["rail-var", @selected_variable == v && "rail-var--selected"]}
              phx-click="select_variable"
              phx-value-name={v}
            >
              {"{" <> v <> "}"}
            </button>
            <%= if @selected_variable do %>
              <div class="var-detail">
                <div class="var-detail-row">
                  <div class="var-detail-label">DEFINES</div>
                  <div :if={@variable_producers == []} class="var-detail-empty">—</div>
                  <button
                    :for={n <- @variable_producers}
                    type="button"
                    class="var-detail-node var-detail-node--producer"
                    phx-click="select_node"
                    phx-value-id={n.id}
                  >{n.label}</button>
                </div>
                <div class="var-detail-row">
                  <div class="var-detail-label">USED BY</div>
                  <div :if={@variable_consumers == []} class="var-detail-empty">—</div>
                  <button
                    :for={n <- @variable_consumers}
                    type="button"
                    class="var-detail-node var-detail-node--consumer"
                    phx-click="select_node"
                    phx-value-id={n.id}
                  >{n.label}</button>
                </div>
              </div>
            <% end %>

            <div class="rail-head rail-head--mt rail-head--row">
              <span>REGISTRY</span>
              <button type="button" phx-click="open_new_skill_modal" class="rail-add-btn" title="Create a new Skill">
                + New Skill
              </button>
            </div>
            <input
              type="text"
              value={@registry_search}
              phx-keyup="registry_search_change"
              phx-debounce="200"
              placeholder="Search…"
              class="rail-search"
            />
            <button
              :if={@skill_suggestions != []}
              type="button"
              phx-click="open_suggestions"
              class="reg-suggest-banner"
              title="Duplicated logic found across graphs"
            >
              ✦ {length(@skill_suggestions)} reusable pattern{if length(@skill_suggestions) > 1, do: "s"} found — review
            </button>
            <% reg_filtered = filter_registry(@registry_items, @registry_search) %>
            <div :if={@registry_items == [] && @packages == []} class="rail-hint">No registry assets yet</div>
            <div :if={@registry_items != [] && reg_filtered == [] && @packages == []} class="rail-hint">No matches</div>
            <%= for group_type <- [:skill, :policy, :schema, :memory_template] do %>
              <% group = Enum.filter(reg_filtered, &(&1.asset_type == group_type)) %>
              <%= if group != [] do %>
                <div class="reg-group-label">{registry_group_label(group_type)}</div>
                <div :for={item <- group} class="reg-row">
                  <button
                    id={"reg-#{item.id}"}
                    type="button"
                    class={["reg-item", item.status == :deprecated && "reg-item--deprecated"]}
                    draggable="true"
                    phx-hook="DragRegistryAsset"
                    data-asset-id={item.id}
                    data-asset-type={Atom.to_string(item.asset_type)}
                    phx-click="add_registry_node"
                    phx-value-asset_id={item.id}
                    phx-value-asset_type={Atom.to_string(item.asset_type)}
                    title={"#{item.name}#{if item.description, do: " — #{item.description}", else: ""}"}
                    disabled={is_nil(@graph)}
                  >
                    <span class="reg-swatch" style={"background: oklch(0.55 0.13 #{registry_hue(group_type)});"}></span>
                    <span class="reg-name">{item.name}</span>
                    <span
                      :if={item.usage && item.usage.graphs != []}
                      class="reg-usage"
                      title={usage_summary(item.usage)}
                    >▦ {length(item.usage.graphs)}</span>
                    <span class="reg-badge">{item.status}</span>
                  </button>
                  <button
                    :if={item.asset_type == :skill}
                    type="button"
                    class="reg-inspect"
                    phx-click="inspect_skill"
                    phx-value-skill_id={item.id}
                    title="View usage & impact"
                  >ⓘ</button>
                </div>
              <% end %>
            <% end %>
            <%= if @packages != [] do %>
              <div class="reg-group-label">PACKAGES</div>
              <button
                :for={pkg <- @packages}
                id={"pkg-#{pkg.id}"}
                type="button"
                class={["reg-item reg-item--package", pkg.status == :deprecated && "reg-item--deprecated"]}
                phx-click="install_package"
                phx-value-package_id={pkg.id}
                title={"#{pkg.name}#{if pkg.description, do: " — #{pkg.description}", else: ""} (click to install)"}
                disabled={is_nil(@graph)}
              >
                <span class="reg-swatch reg-swatch--pkg" style="background: oklch(0.55 0.13 200);"></span>
                <span class="reg-name">{pkg.name}</span>
                <span class="reg-badge">v{pkg.version}</span>
              </button>
            <% end %>
          </aside>

          <main class="studio-canvas">
            <button
              :if={@graph}
              type="button"
              phx-click="enter_zen"
              phx-value-mode="canvas"
              class="zen-btn"
              title="Zen view — fullscreen canvas (Esc to exit)"
            >
              ⛶ Zen
            </button>
            <%= if @graph do %>
              <.svelte
                name="GraphCanvas"
                id="studio-graph-canvas"
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

                <%= if @selected.type == :agent do %>
                  <%!-- Agent node wiring --%>
                  <% agent_meta = @selected.metadata || %{} %>
                  <.form
                    for={%{}}
                    id={"agent-form-#{@selected.id}"}
                    phx-change="update_agent_metadata"
                  >
                    <div class="insp-field-label">SUB-AGENT GRAPH</div>
                    <select name="source_graph_id" class="insp-agent-select">
                      <option value="">— select graph —</option>
                      <%= for g <- @all_graphs, g.id != (@graph && @graph.id) do %>
                        <option value={g.id} selected={Map.get(agent_meta, "source_graph_id") == g.id}>
                          {g.name}
                        </option>
                      <% end %>
                    </select>

                    <div class="insp-field-label">OUTPUT VARIABLE</div>
                    <input
                      type="text"
                      name="output_var"
                      value={Map.get(agent_meta, "output_var", "")}
                      phx-debounce="500"
                      class="insp-agent-input"
                      placeholder="e.g. research_result"
                    />
                    <div class="insp-agent-hint">Downstream nodes reference this as &#123;output_var&#125;</div>

                    <div class="insp-field-label">ON ERROR</div>
                    <div class="insp-on-error">
                      <label class={["insp-radio-label", Map.get(agent_meta, "on_error", "fail") == "fail" && "insp-radio-label--active"]}>
                        <input type="radio" name="on_error" value="fail" checked={Map.get(agent_meta, "on_error", "fail") == "fail"} />
                        Fail
                      </label>
                      <label class={["insp-radio-label", Map.get(agent_meta, "on_error", "fail") == "continue" && "insp-radio-label--active"]}>
                        <input type="radio" name="on_error" value="continue" checked={Map.get(agent_meta, "on_error", "fail") == "continue"} />
                        Continue
                      </label>
                    </div>

                    <div class="insp-field-label">TIMEOUT (ms)</div>
                    <input
                      type="number"
                      name="timeout_ms"
                      value={Map.get(agent_meta, "timeout_ms", 10000)}
                      min="500"
                      max="120000"
                      step="500"
                      phx-debounce="800"
                      class="insp-agent-input"
                    />
                  </.form>

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
                <% else %>
                  <% linked_asset = @selected.source_asset_id && Enum.find(@registry_items, &(&1.id == @selected.source_asset_id)) %>
                  <%= if @selected.type == :skill && linked_asset do %>
                    <%!-- Linked Skill: content is managed in the Registry, read-only here --%>
                    <div class="insp-managed">
                      <span class="insp-managed-badge">⟳ MANAGED BY REGISTRY</span>
                      <button
                        type="button"
                        phx-click="inspect_skill"
                        phx-value-skill_id={linked_asset.id}
                        class="insp-open-skill"
                      >
                        Open “{linked_asset.name}” ↗
                      </button>
                    </div>
                    <div class="insp-field-label">RESOLVED CONTENT · READ-ONLY</div>
                    <div class="insp-readonly">{linked_asset.content || "(this Skill has no content yet)"}</div>

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

                    <div class="insp-linked">
                      <button type="button" phx-click="detach_node" class="insp-detach-btn">
                        Detach &amp; edit locally
                      </button>
                    </div>
                  <% else %>
                    <div class="insp-field-label">INSTRUCTION · MARKDOWN</div>
                    <.svelte
                      name="CodeEditor"
                      id="studio-code-editor"
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

                    <%!-- Non-skill linked asset (e.g. policy/schema): copy-based for now --%>
                    <%= if linked_asset do %>
                      <div class="insp-linked">
                        <span class="insp-linked-badge">{registry_type_label(linked_asset.asset_type)}</span>
                        <span class="insp-linked-name">{linked_asset.name}</span>
                        <button type="button" phx-click="detach_node" class="insp-detach-btn">
                          Detach
                        </button>
                      </div>
                    <% end %>
                    <%= if @selected.type == :skill && is_nil(@selected.source_asset_id) do %>
                      <button type="button" phx-click="convert_to_skill" class="insp-convert-btn">
                        → Save as Skill
                      </button>
                    <% end %>
                  <% end %>
                <% end %>

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
                      <span
                        :if={v.resolved_skills != []}
                        class="version-skills"
                        title={version_skills_title(v.resolved_skills)}
                      >▦ {length(v.resolved_skills)}</span>
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
                  class={["diag-item",
                    d.level == :error && "diag-item--error",
                    d.level == :warning && "diag-item--warn",
                    d.node_ids != [] && "diag-item--clickable"
                  ]}
                  phx-click={d.node_ids != [] && "select_node"}
                  phx-value-id={List.first(d.node_ids)}
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
                    type="button"
                    phx-click="enter_zen"
                    phx-value-mode="compiler"
                    class="compiler-ctrl-btn"
                    title="Zen view — fullscreen prompt (Esc to exit)"
                  >
                    ⛶ Zen
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
                ≈ {@compiled.token_estimate} tokens<span :if={@compiled.cost_estimate > 0}> · ~{format_cost(@compiled.cost_estimate)}</span> · {@compiled.included} nodes<span :if={@compiled.excluded > 0}> · {@compiled.excluded} muted</span><span :if={@compiled.resolved_assets != []} title={resolved_assets_title(@compiled.resolved_assets)}> · {length(@compiled.resolved_assets)} linked skill{if length(@compiled.resolved_assets) > 1, do: "s"}</span>
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
      <%= if @show_new_skill_modal do %>
        <div class="dlg-overlay">
          <div class="dlg-backdrop" phx-click="close_new_skill_modal"></div>
          <div class="dlg-box dlg-box--wide">
            <div class="dlg-head">▦ NEW SKILL</div>
            <div class="dlg-sub">
              A reusable capability you can link into multiple graphs. Created as a draft.
            </div>
            <.form for={%{}} id="new-skill-form" phx-submit="create_skill" phx-change="new_skill_change">
              <div class="dlg-field-label">NAME</div>
              <input
                type="text"
                name="name"
                value={@new_skill_name}
                placeholder="e.g. Citation Enforcement"
                class="dlg-input"
                autofocus
                required
              />
              <div class="dlg-field-label">DESCRIPTION <span class="dlg-optional">(optional)</span></div>
              <input
                type="text"
                name="description"
                value={@new_skill_description}
                placeholder="What capability does this provide?"
                class="dlg-input"
              />
              <div class="dlg-field-label">CONTENT · MARKDOWN</div>
              <textarea
                name="content"
                rows="6"
                placeholder="The reusable instruction text. May reference {variables}."
                class="dlg-input dlg-textarea"
              >{@new_skill_content}</textarea>
              <div class="dlg-actions">
                <button type="button" phx-click="close_new_skill_modal" class="dlg-btn dlg-btn--cancel">
                  Cancel
                </button>
                <button type="submit" class="dlg-btn dlg-btn--create" disabled={String.trim(@new_skill_name) == ""}>
                  Create Skill
                </button>
              </div>
            </.form>
          </div>
        </div>
      <% end %>
      <%= if @show_suggestions_modal do %>
        <div class="dlg-overlay">
          <div class="dlg-backdrop" phx-click="close_suggestions"></div>
          <div class="dlg-box dlg-box--wide">
            <div class="dlg-head">✦ REGISTRY SUGGESTIONS</div>
            <div class="dlg-sub">
              The same Skill content is copy-pasted across graphs. Extract each into one
              shared Skill — every node becomes a linked reference you can update in one place.
            </div>
            <div :if={@skill_suggestions == []} class="skill-usage-empty">
              No duplicated logic found. Nice and DRY.
            </div>
            <div class="suggest-list">
              <div :for={group <- @skill_suggestions} class="suggest-row">
                <div class="suggest-meta">
                  <span class="suggest-count">{group.count}×</span>
                  <span class="suggest-graphs">{Enum.map_join(group.graphs, ", ", & &1.name)}</span>
                </div>
                <div class="suggest-content">{String.slice(group.content, 0, 180)}</div>
                <button
                  type="button"
                  phx-click="extract_shared_skill"
                  phx-value-signature={group.signature}
                  data-confirm={"Extract \"#{group.label}\" as a shared Skill and link #{group.count} nodes across #{length(group.graphs)} graph(s)?"}
                  class="dlg-btn dlg-btn--create suggest-extract"
                >
                  Extract as shared Skill
                </button>
              </div>
            </div>
            <div class="dlg-actions">
              <button type="button" phx-click="close_suggestions" class="dlg-btn dlg-btn--cancel">
                Close
              </button>
            </div>
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
      <%= if @show_skill_modal && @skill_detail do %>
        <div class="dlg-overlay">
          <div class="dlg-backdrop" phx-click="close_skill_modal"></div>
          <div class="dlg-box dlg-box--wide">
            <div class="dlg-head">▦ {@skill_detail.skill.name}</div>
            <div class="dlg-sub">
              <span class="skill-meta-badge">{@skill_detail.skill.status} · v{@skill_detail.skill.version}</span>
              Impact analysis — review the blast radius before editing this shared Skill.
            </div>
            <div class="skill-impact">
              <span class="skill-impact-stat">
                Affected Graphs <strong>{length(@skill_detail.usage.graphs)}</strong>
              </span>
              <span class="skill-impact-stat">
                Affected Deployments <strong>{length(@skill_detail.usage.deployments)}</strong>
              </span>
              <span class="skill-impact-stat">
                Linked Nodes <strong>{@skill_detail.usage.nodes}</strong>
              </span>
            </div>
            <div class="dlg-field-label">USED BY</div>
            <div :if={@skill_detail.usage.graphs == []} class="skill-usage-empty">
              Not referenced by any graph yet.
            </div>
            <ul :if={@skill_detail.usage.graphs != []} class="skill-usage-list">
              <li :for={g <- @skill_detail.usage.graphs}>{g.name}</li>
            </ul>
            <%= if @skill_detail.usage.deployments != [] do %>
              <div class="dlg-field-label">LIVE DEPLOYMENTS</div>
              <ul class="skill-usage-list">
                <li :for={d <- @skill_detail.usage.deployments}>{d.environment}</li>
              </ul>
            <% end %>
            <div class="dlg-actions">
              <button type="button" phx-click="close_skill_modal" class="dlg-btn dlg-btn--cancel">
                Close
              </button>
              <button
                :if={admin_role?(@current_role) && @skill_detail.skill.status != :deprecated}
                type="button"
                phx-click="archive_skill"
                phx-value-skill_id={@skill_detail.skill.id}
                data-confirm="Deprecate this Skill? Graphs that link it will fail to compile until they are relinked."
                class="dlg-btn dlg-btn--cancel"
              >
                Archive
              </button>
              <button
                :if={admin_role?(@current_role)}
                type="button"
                phx-click="publish_skill"
                phx-value-skill_id={@skill_detail.skill.id}
                data-confirm={skill_publish_confirm(@skill_detail)}
                class="dlg-btn dlg-btn--create"
              >
                Publish v{@skill_detail.skill.version + 1}
              </button>
            </div>
          </div>
        </div>
      <% end %>
      <%= if @show_architect_modal do %>
        <div class="dlg-overlay">
          <div class="dlg-backdrop" phx-click="close_architect"></div>
          <div class="dlg-box dlg-box--wide">
            <div class="dlg-head">✦ AI ARCHITECT</div>
            <div class="dlg-sub">
              Paste a raw prompt or agent description. Claude will decompose it into a structured graph of typed nodes.
            </div>
            <%= if @architect_error do %>
              <div class="arch-error">{@architect_error}</div>
            <% end %>
            <.form for={%{}} id="architect-form" phx-submit="run_architect">
              <div class="dlg-field-label">AGENT PROMPT / DESCRIPTION</div>
              <textarea
                name="prompt"
                rows="10"
                placeholder={"You are a customer support agent for Acme Corp.\nYou help users with billing questions, account issues, and product information.\nAlways be polite and escalate to a human when you cannot resolve the issue.\nRespond in the same language as the user.\n\nContext: {user_message}, {account_info}"}
                class="dlg-input dlg-textarea dlg-textarea--tall"
                autofocus
                required
              ></textarea>
              <div class="dlg-actions">
                <button type="button" phx-click="close_architect" class="dlg-btn dlg-btn--cancel" disabled={@architect_loading}>
                  Cancel
                </button>
                <button type="submit" class="dlg-btn dlg-btn--create" disabled={@architect_loading}>
                  <%= if @architect_loading do %>
                    ⟳ Architecting…
                  <% else %>
                    ✦ Architect Graph
                  <% end %>
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
