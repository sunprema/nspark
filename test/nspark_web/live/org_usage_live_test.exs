defmodule NsparkWeb.OrgUsageLiveTest do
  use NsparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Nspark.Accounts.{Organization, Membership}

  defp setup_user(conn, role) do
    org =
      Ash.create!(Organization, %{
        name: "UsageOrg",
        slug: "usage-live-#{System.unique_integer([:positive])}"
      })

    user =
      Ash.Seed.seed!(Nspark.Accounts.User, %{
        email: "usage_#{System.unique_integer([:positive])}@example.com"
      })

    Ash.create!(Membership, %{user_id: user.id, organization_id: org.id, role: role})
    %{conn: log_in_user(conn, user), org: org, user: user}
  end

  test "shows empty state when there is no activity", %{conn: conn} do
    %{conn: conn} = setup_user(conn, :viewer)
    {:ok, view, _} = live(conn, "/org/usage")

    assert render(view) =~ "No runtime activity yet"
    assert render(view) =~ "TOTAL CALLS"
  end

  test "renders a recorded run event and its stats", %{conn: conn} do
    %{conn: conn, org: org} = setup_user(conn, :viewer)

    # Record directly (fire-and-forget) and wait for the supervised task to land.
    Nspark.Observability.record(%{
      source: :prompt_fetch,
      organization_id: org.id,
      status: :ok,
      http_status: 200,
      resolved_via: "@latest",
      latency_ms: 42,
      token_estimate: 128,
      principal_type: :api_key
    })

    # The write is async; poll briefly until it's visible.
    wait_for(fn ->
      [] != Nspark.Observability.recent_run_events!(nil, tenant: org.id, authorize?: false)
    end)

    {:ok, view, _} = live(conn, "/org/usage")
    html = render(view)

    assert html =~ "FETCH"
    assert html =~ "@latest"
    assert html =~ "42ms"
    assert html =~ "128"
    assert html =~ "100%"
  end

  defp wait_for(fun, attempts \\ 50)
  defp wait_for(_fun, 0), do: flunk("condition not met in time")

  defp wait_for(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_for(fun, attempts - 1)
    end
  end
end
