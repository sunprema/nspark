defmodule NsparkWeb.OrgApiKeysLive do
  @moduledoc """
  API key management for the active organization. Admin+ only: keys grant
  scoped, unattended access to the runtime prompt API, so issuance and
  revocation are restricted. A freshly issued key's plaintext is shown exactly
  once — the server only ever stores its hash.
  """
  use NsparkWeb, :live_view

  on_mount {NsparkWeb.LiveUserAuth, :live_user_and_tenant_required}

  alias Nspark.Accounts
  alias Nspark.Accounts.ApiKey
  alias Nspark.Projects.Project

  @environments [:dev, :staging, :production]

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns.current_role in [:admin, :owner] do
      {:ok,
       socket
       |> reset_form()
       |> assign(:new_secret, nil)
       |> load_data()}
    else
      {:ok,
       socket
       |> put_flash(:error, "API keys are admin-only.")
       |> redirect(to: ~p"/studio")}
    end
  end

  # ── issue ─────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("form_change", %{"name" => name, "environment" => env, "project_id" => proj}, socket) do
    {:noreply,
     socket
     |> assign(:form_name, name)
     |> assign(:form_env, env)
     |> assign(:form_project, proj)}
  end

  def handle_event("issue", %{"name" => name} = params, socket) do
    name = String.trim(name)
    org = socket.assigns.current_org

    if name == "" do
      {:noreply, assign(socket, :form_error, "Name is required.")}
    else
      attrs =
        %{name: name, organization_id: org.id}
        |> put_env(params["environment"])
        |> put_project(params["project_id"])

      case Accounts.issue_api_key(attrs, actor: socket.assigns.current_user) do
        {:ok, key} ->
          {:noreply,
           socket
           |> assign(:new_secret, Ash.Resource.get_metadata(key, :plaintext))
           |> reset_form()
           |> put_flash(:info, "Key “#{name}” issued. Copy it now — it won't be shown again.")
           |> load_data()}

        {:error, _} ->
          {:noreply, assign(socket, :form_error, "Could not issue key.")}
      end
    end
  end

  def handle_event("dismiss_secret", _params, socket), do: {:noreply, assign(socket, :new_secret, nil)}

  # ── revoke ────────────────────────────────────────────────────────────────

  def handle_event("revoke", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.keys, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      key ->
        case Accounts.revoke_api_key(key, actor: socket.assigns.current_user) do
          {:ok, _} -> {:noreply, socket |> put_flash(:info, "Key revoked.") |> load_data()}
          {:error, _} -> {:noreply, put_flash(socket, :error, "Could not revoke key.")}
        end
    end
  end

  # ── data ──────────────────────────────────────────────────────────────────

  defp load_data(socket) do
    org_id = socket.assigns.current_org.id

    projects =
      Project
      |> Ash.read!(tenant: org_id, actor: socket.assigns.current_user)
      |> Enum.sort_by(& &1.name)

    socket
    |> assign(:keys, Accounts.api_keys_for_org!(org_id))
    |> assign(:projects, projects)
    |> assign(:project_names, Map.new(projects, &{&1.id, &1.name}))
  end

  defp reset_form(socket) do
    socket
    |> assign(:form_name, "")
    |> assign(:form_env, "")
    |> assign(:form_project, "")
    |> assign(:form_error, nil)
  end

  defp put_env(attrs, env) when env in [nil, ""], do: attrs

  defp put_env(attrs, env) do
    atom = String.to_existing_atom(env)
    if atom in @environments, do: Map.put(attrs, :environment, atom), else: attrs
  rescue
    ArgumentError -> attrs
  end

  defp put_project(attrs, proj) when proj in [nil, ""], do: attrs
  defp put_project(attrs, proj), do: Map.put(attrs, :project_id, proj)

  # ── view helpers ────────────────────────────────────────────────────────────

  defp status(key) do
    cond do
      not is_nil(key.revoked_at) -> "REVOKED"
      not ApiKey.active?(key) -> "EXPIRED"
      true -> "ACTIVE"
    end
  end

  defp fmt(nil), do: "—"
  defp fmt(dt), do: Calendar.strftime(dt, "%b %d, %Y")

  # ── render ──────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.workspace flash={@flash}>
      <div class="members-page">
        <div class="members-bar">
          <a href={~p"/studio"} class="studio-btn" style="text-decoration: none;">← Studio</a>
          <div class="members-title">API KEYS · {String.upcase(@current_org.name)}</div>
          <div class="members-role-chip">You: {String.upcase(to_string(@current_role))}</div>
        </div>

        <%!-- One-time secret reveal --%>
        <div
          :if={@new_secret}
          style="margin: 16px 0; border: 1px solid oklch(0.55 0.13 255 / 0.5); background: oklch(0.96 0.03 255 / 0.5); padding: 16px;"
        >
          <div style="font-family: 'IBM Plex Mono', monospace; font-size: 11px; letter-spacing: 0.1em; color: oklch(0.45 0.1 255); margin-bottom: 8px;">
            NEW KEY — COPY NOW, IT WON'T BE SHOWN AGAIN
          </div>
          <div style="display: flex; gap: 12px; align-items: center;">
            <code style="flex: 1; font-family: 'IBM Plex Mono', monospace; font-size: 13px; padding: 8px 12px; background: oklch(0.99 0.003 245); border: 1px solid oklch(0.82 0.02 250); word-break: break-all;">{@new_secret}</code>
            <button type="button" phx-click="dismiss_secret" class="members-action-btn">Done</button>
          </div>
        </div>

        <%!-- Issue form --%>
        <section class="members-section members-invite">
          <div class="members-section-head">ISSUE A KEY</div>
          <.form for={%{}} id="issue-key-form" phx-submit="issue" phx-change="form_change">
            <div class="invite-row">
              <input
                type="text"
                name="name"
                value={@form_name}
                placeholder="e.g. checkout-service (prod)"
                class="invite-input"
                required
              />
              <select name="environment" class="invite-select">
                <option value="" selected={@form_env == ""}>All environments</option>
                <option :for={e <- [:dev, :staging, :production]} value={e} selected={to_string(e) == @form_env}>
                  {String.capitalize(to_string(e))}
                </option>
              </select>
              <select name="project_id" class="invite-select">
                <option value="" selected={@form_project == ""}>All projects</option>
                <option :for={p <- @projects} value={p.id} selected={p.id == @form_project}>
                  {p.name}
                </option>
              </select>
              <button type="submit" class="studio-btn studio-btn--accent" disabled={String.trim(@form_name) == ""}>
                Issue Key
              </button>
            </div>
            <div :if={@form_error} class="invite-error">{@form_error}</div>
          </.form>
        </section>

        <%!-- Keys table --%>
        <section class="members-section">
          <div class="members-section-head">KEYS ({length(@keys)})</div>
          <div :if={@keys == []} class="members-empty">No API keys yet.</div>
          <table :if={@keys != []} class="members-table">
            <thead>
              <tr>
                <th>NAME</th>
                <th>PREFIX</th>
                <th>SCOPE</th>
                <th>STATUS</th>
                <th>LAST USED</th>
                <th>CREATED</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={k <- @keys}>
                <td>{k.name}</td>
                <td style="font-family: 'IBM Plex Mono', monospace;">{k.prefix}…</td>
                <td>
                  <span class="role-chip">{k.environment && String.upcase(to_string(k.environment)) || "ALL ENVS"}</span>
                  <span class="role-chip">{k.project_id && @project_names[k.project_id] || "ALL PROJECTS"}</span>
                </td>
                <td><span class="role-chip" data-role={status(k) == "ACTIVE" && "editor" || "viewer"}>{status(k)}</span></td>
                <td class="members-date">{fmt(k.last_used_at)}</td>
                <td class="members-date">{fmt(k.inserted_at)}</td>
                <td>
                  <button
                    :if={status(k) == "ACTIVE"}
                    type="button"
                    phx-click="revoke"
                    phx-value-id={k.id}
                    data-confirm={"Revoke “#{k.name}”? Apps using it will stop working immediately."}
                    class="members-action-btn members-action-btn--danger"
                  >
                    Revoke
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </section>
      </div>
    </Layouts.workspace>
    """
  end
end
