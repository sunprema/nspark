defmodule NsparkWeb.OrgMembersLive do
  @moduledoc """
  Org members and invitations management screen. Accessible from the studio
  header. Only admin+ can invite or remove; all members can view the roster.
  """
  use NsparkWeb, :live_view

  on_mount {NsparkWeb.LiveUserAuth, :live_user_and_tenant_required}

  alias Nspark.Accounts
  alias Nspark.Accounts.Invitation.Senders.SendInvitationEmail

  @roles [:viewer, :editor, :admin, :owner]

  @impl true
  def mount(_params, _session, socket) do
    role = socket.assigns.current_role

    socket =
      socket
      |> assign(:can_manage, role in [:admin, :owner])
      |> assign(:invite_email, "")
      |> assign(:invite_role, :viewer)
      |> assign(:invite_error, nil)
      |> load_data()

    {:ok, socket}
  end

  # ── invite form ──────────────────────────────────────────────────────────────

  @impl true
  def handle_event("invite_change", %{"email" => email, "role" => role}, socket) do
    {:noreply,
     socket
     |> assign(:invite_email, email)
     |> assign(:invite_role, safe_role(role))}
  end

  def handle_event("invite", %{"email" => email, "role" => role}, socket) do
    unless socket.assigns.can_manage, do: {:noreply, socket}

    email = String.trim(email)
    org = socket.assigns.current_org

    case Accounts.invite_to_organization(%{
           email: email,
           role: safe_role(role),
           organization_id: org.id,
           invited_by_id: socket.assigns.current_user.id
         }) do
      {:ok, invitation} ->
        SendInvitationEmail.deliver(
          invitation,
          to_string(socket.assigns.current_user.email)
        )

        {:noreply,
         socket
         |> assign(:invite_email, "")
         |> assign(:invite_error, nil)
         |> put_flash(:info, "Invitation sent to #{email}")
         |> load_data()}

      {:error, error} ->
        msg =
          case error do
            %Ash.Error.Invalid{errors: [%{message: m} | _]} -> m
            _ -> "Could not send invitation"
          end

        {:noreply, assign(socket, :invite_error, msg)}
    end
  end

  # ── revoke invitation ────────────────────────────────────────────────────────

  def handle_event("revoke", %{"id" => id}, socket) do
    unless socket.assigns.can_manage, do: {:noreply, socket}

    case Enum.find(socket.assigns.invitations, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      invitation ->
        case Accounts.revoke_invitation(invitation) do
          {:ok, _} ->
            {:noreply,
             socket |> put_flash(:info, "Invitation revoked.") |> load_data()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not revoke invitation.")}
        end
    end
  end

  # ── remove member ────────────────────────────────────────────────────────────

  def handle_event("remove_member", %{"id" => id}, socket) do
    unless socket.assigns.can_manage, do: {:noreply, socket}

    case Enum.find(socket.assigns.memberships, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      membership ->
        if membership.user_id == socket.assigns.current_user.id do
          {:noreply, put_flash(socket, :error, "You cannot remove yourself.")}
        else
          case Ash.destroy(membership) do
            {:ok, _} ->
              {:noreply,
               socket |> put_flash(:info, "Member removed.") |> load_data()}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Could not remove member.")}
          end
        end
    end
  end

  # ── data ──────────────────────────────────────────────────────────────────────

  defp load_data(socket) do
    org_id = socket.assigns.current_org.id

    memberships =
      Accounts.members_for_org!(org_id)
      |> Ash.load!([:user], authorize?: false)

    invitations = Accounts.pending_invitations_for_org!(org_id)

    socket
    |> assign(:memberships, memberships)
    |> assign(:invitations, invitations)
  end

  defp safe_role(str) when is_binary(str) do
    atom = String.to_existing_atom(str)
    if atom in @roles, do: atom, else: :viewer
  rescue
    ArgumentError -> :viewer
  end

  # ── render ──────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.workspace flash={@flash}>
      <div class="members-page">
        <div class="members-bar">
          <a href={~p"/studio"} class="studio-btn" style="text-decoration: none;">← Studio</a>
          <div class="members-title">MEMBERS · {String.upcase(@current_org.name)}</div>
          <div class="members-role-chip">
            You: {String.upcase(to_string(@current_role))}
          </div>
        </div>

        <%!-- Current members --%>
        <section class="members-section">
          <div class="members-section-head">MEMBERS ({length(@memberships)})</div>
          <table class="members-table">
            <thead>
              <tr>
                <th>EMAIL</th>
                <th>ROLE</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={m <- @memberships}>
                <td>{m.user && to_string(m.user.email) || "—"}</td>
                <td>
                  <span class="role-chip" data-role={m.role}>{String.upcase(to_string(m.role))}</span>
                </td>
                <td>
                  <button
                    :if={@can_manage and m.user_id != @current_user.id}
                    type="button"
                    phx-click="remove_member"
                    phx-value-id={m.id}
                    data-confirm={"Remove #{m.user && to_string(m.user.email) || "this member"}?"}
                    class="members-action-btn members-action-btn--danger"
                  >
                    Remove
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </section>

        <%!-- Pending invitations --%>
        <section :if={@can_manage} class="members-section">
          <div class="members-section-head">PENDING INVITATIONS ({length(@invitations)})</div>
          <div :if={@invitations == []} class="members-empty">No pending invitations.</div>
          <table :if={@invitations != []} class="members-table">
            <thead>
              <tr>
                <th>EMAIL</th>
                <th>ROLE</th>
                <th>SENT</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={inv <- @invitations}>
                <td>{to_string(inv.email)}</td>
                <td>
                  <span class="role-chip" data-role={inv.role}>{String.upcase(to_string(inv.role))}</span>
                </td>
                <td class="members-date">{Calendar.strftime(inv.inserted_at, "%b %d, %Y")}</td>
                <td>
                  <button
                    type="button"
                    phx-click="revoke"
                    phx-value-id={inv.id}
                    data-confirm={"Revoke invitation for #{to_string(inv.email)}?"}
                    class="members-action-btn"
                  >
                    Revoke
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </section>

        <%!-- Invite form --%>
        <section :if={@can_manage} class="members-section members-invite">
          <div class="members-section-head">INVITE SOMEONE</div>
          <.form
            for={%{}}
            id="invite-form"
            phx-submit="invite"
            phx-change="invite_change"
          >
            <div class="invite-row">
              <input
                type="email"
                name="email"
                value={@invite_email}
                placeholder="name@example.com"
                class="invite-input"
                required
              />
              <select name="role" class="invite-select">
                <option :for={r <- [:viewer, :editor, :admin]} value={r} selected={r == @invite_role}>
                  {String.capitalize(to_string(r))}
                </option>
              </select>
              <button type="submit" class="studio-btn studio-btn--accent" disabled={String.trim(@invite_email) == ""}>
                Send Invite
              </button>
            </div>
            <div :if={@invite_error} class="invite-error">{@invite_error}</div>
          </.form>
        </section>
      </div>
    </Layouts.workspace>
    """
  end
end
