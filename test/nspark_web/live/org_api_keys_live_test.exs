defmodule NsparkWeb.OrgApiKeysLiveTest do
  use NsparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Nspark.Accounts.{Organization, Membership}

  defp setup_user(conn, role) do
    org = Ash.create!(Organization, %{name: "KeysOrg", slug: "keys-live-#{System.unique_integer([:positive])}"})
    user = Ash.Seed.seed!(Nspark.Accounts.User, %{email: "keys_#{System.unique_integer([:positive])}@example.com"})
    Ash.create!(Membership, %{user_id: user.id, organization_id: org.id, role: role})
    %{conn: log_in_user(conn, user), org: org, user: user}
  end

  test "admin can issue a key and see its plaintext once", %{conn: conn} do
    %{conn: conn} = setup_user(conn, :admin)
    {:ok, view, _} = live(conn, "/org/api-keys")

    refute render(view) =~ "nsk_"

    html =
      view
      |> form("#issue-key-form", %{name: "ci-key", environment: "production", project_id: ""})
      |> render_submit()

    assert html =~ "nsk_"
    assert html =~ "NEW KEY"
    assert html =~ "shown again"
    assert html =~ "ci-key"
    assert html =~ "PRODUCTION"
  end

  test "a key can be revoked", %{conn: conn} do
    %{conn: conn, org: org, user: user} = setup_user(conn, :admin)
    Nspark.Accounts.issue_api_key!(%{name: "old", organization_id: org.id}, actor: user)

    {:ok, view, _} = live(conn, "/org/api-keys")
    assert render(view) =~ "ACTIVE"

    view |> element("button", "Revoke") |> render_click()
    assert render(view) =~ "REVOKED"
  end

  test "non-admins are redirected away", %{conn: conn} do
    %{conn: conn} = setup_user(conn, :editor)
    assert {:error, {:redirect, %{to: "/studio"}}} = live(conn, "/org/api-keys")
  end
end
