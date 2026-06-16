defmodule NsparkWeb.InvitationController do
  use NsparkWeb, :controller

  alias Nspark.Accounts

  def accept(conn, %{"token" => token}) do
    user = conn.assigns[:current_user]

    if is_nil(user) do
      conn
      |> put_session(:return_to, ~p"/invitations/#{token}")
      |> redirect(to: ~p"/sign-in")
    else
      case Accounts.get_invitation_by_token(token) do
        {:ok, nil} ->
          conn
          |> put_flash(:error, "Invitation not found.")
          |> redirect(to: ~p"/studio")

        {:ok, invitation} ->
          cond do
            invitation.status != :pending ->
              conn
              |> put_flash(:error, "This invitation has already been used or revoked.")
              |> redirect(to: ~p"/studio")

            expired?(invitation) ->
              conn
              |> put_flash(:error, "This invitation has expired.")
              |> redirect(to: ~p"/studio")

            to_string(invitation.email) != to_string(user.email) ->
              conn
              |> put_flash(:error, "This invitation was sent to a different email address.")
              |> redirect(to: ~p"/studio")

            true ->
              do_accept(conn, invitation, user)
          end

        {:error, _} ->
          conn
          |> put_flash(:error, "Invitation not found.")
          |> redirect(to: ~p"/studio")
      end
    end
  end

  defp do_accept(conn, invitation, user) do
    case Accounts.accept_invitation(invitation, user.id) do
      {:ok, _} ->
        conn
        |> put_session("active_org_id", invitation.organization_id)
        |> put_flash(:info, "Welcome! You've joined the organization.")
        |> redirect(to: ~p"/studio")

      {:error, _} ->
        conn
        |> put_flash(:error, "Could not accept invitation.")
        |> redirect(to: ~p"/studio")
    end
  end

  defp expired?(%{expires_at: nil}), do: false
  defp expired?(%{expires_at: expires_at}),
    do: DateTime.compare(expires_at, DateTime.utc_now()) == :lt
end
