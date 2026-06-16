defmodule NsparkWeb.OrgController do
  use NsparkWeb, :controller

  def switch(conn, %{"org_id" => org_id}) do
    user = conn.assigns[:current_user]

    if user do
      memberships = Nspark.Accounts.memberships_for_user!(user.id)

      if Enum.any?(memberships, &(&1.organization_id == org_id)) do
        conn
        |> put_session("active_org_id", org_id)
        |> redirect(to: ~p"/studio")
      else
        conn
        |> put_flash(:error, "You don't have access to that organization.")
        |> redirect(to: ~p"/studio")
      end
    else
      redirect(conn, to: ~p"/sign-in")
    end
  end
end
