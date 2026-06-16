defmodule NsparkWeb.LiveUserAuth do
  @moduledoc """
  Helpers for authenticating users in LiveViews.
  """

  import Phoenix.Component
  use NsparkWeb, :verified_routes

  # This is used for nested liveviews to fetch the current user.
  # To use, place the following at the top of that liveview:
  # on_mount {NsparkWeb.LiveUserAuth, :current_user}
  def on_mount(:current_user, _params, session, socket) do
    {:cont, AshAuthentication.Phoenix.LiveSession.assign_new_resources(socket, session)}
  end

  def on_mount(:live_user_and_tenant_required, _params, session, socket) do
    if socket.assigns[:current_user] do
      user = socket.assigns.current_user

      memberships =
        Nspark.Accounts.memberships_for_user!(user.id)
        |> Ash.load!([:organization])

      active_org_id = session["active_org_id"]

      active_membership =
        Enum.find(memberships, &(&1.organization_id == active_org_id)) ||
          List.first(memberships)

      if active_membership do
        {:cont,
         socket
         |> assign(:current_org, active_membership.organization)
         |> assign(:current_role, active_membership.role)
         |> assign(:memberships, memberships)}
      else
        {:halt,
         socket
         |> Phoenix.LiveView.put_flash(:error, "No organization access found.")
         |> Phoenix.LiveView.redirect(to: ~p"/sign-in")}
      end
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/sign-in")}
    end
  end

  def on_mount(:live_user_optional, _params, _session, socket) do
    if socket.assigns[:current_user] do
      {:cont, socket}
    else
      {:cont, assign(socket, :current_user, nil)}
    end
  end

  def on_mount(:live_user_required, _params, _session, socket) do
    if socket.assigns[:current_user] do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/sign-in")}
    end
  end

  def on_mount(:live_no_user, _params, _session, socket) do
    if socket.assigns[:current_user] do
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    else
      {:cont, assign(socket, :current_user, nil)}
    end
  end
end
