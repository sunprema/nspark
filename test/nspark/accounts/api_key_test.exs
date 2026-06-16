defmodule Nspark.Accounts.ApiKeyTest do
  @moduledoc "Issuance, hashing, scope, and lifecycle of scoped API keys."
  use NsparkWeb.ConnCase, async: false

  alias Nspark.Accounts.{ApiKey, Organization, Membership}
  alias Nspark.Projects.Project

  setup do
    org = Ash.create!(Organization, %{name: "Keys", slug: "keys-org"})
    user = Ash.Seed.seed!(Nspark.Accounts.User, %{email: "key_owner@example.com"})
    Ash.create!(Membership, %{user_id: user.id, organization_id: org.id, role: :admin})
    project = Ash.create!(Project, %{name: "P", status: :active}, tenant: org.id, authorize?: false)
    %{org: org, user: user, project: project}
  end

  test "issue returns a one-time plaintext and stores only the hash", %{org: org, user: user} do
    key =
      Nspark.Accounts.issue_api_key!(
        %{name: "ci", environment: :production, organization_id: org.id},
        actor: user
      )

    secret = Ash.Resource.get_metadata(key, :plaintext)

    assert String.starts_with?(secret, "nsk_")
    assert key.hash == ApiKey.hash_secret(secret)
    assert key.hash != secret
    assert key.prefix == String.slice(secret, 0, 11)
    assert key.created_by_id == user.id
    assert key.environment == :production
  end

  test "get_by_hash resolves an issued key", %{org: org, user: user} do
    key = Nspark.Accounts.issue_api_key!(%{name: "k", organization_id: org.id}, actor: user)
    secret = Ash.Resource.get_metadata(key, :plaintext)

    {:ok, found} = Nspark.Accounts.get_api_key_by_hash(ApiKey.hash_secret(secret))
    assert found.id == key.id
  end

  describe "active?/1" do
    test "true for a fresh key, false once revoked", %{org: org, user: user} do
      key = Nspark.Accounts.issue_api_key!(%{name: "k", organization_id: org.id}, actor: user)
      assert ApiKey.active?(key)

      revoked = Nspark.Accounts.revoke_api_key!(key, actor: user)
      refute ApiKey.active?(revoked)
      assert revoked.revoked_by_id == user.id
      assert revoked.revoked_at
    end

    test "false for an expired key", %{org: org, user: user} do
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      key =
        Nspark.Accounts.issue_api_key!(
          %{name: "k", organization_id: org.id, expires_at: past},
          actor: user
        )

      refute ApiKey.active?(key)
    end
  end

  test "list_for_org returns keys newest-first and scoped to the org", %{org: org, user: user} do
    Nspark.Accounts.issue_api_key!(%{name: "a", organization_id: org.id}, actor: user)
    Nspark.Accounts.issue_api_key!(%{name: "b", organization_id: org.id}, actor: user)

    other = Ash.create!(Organization, %{name: "Other", slug: "other-org"})
    Nspark.Accounts.issue_api_key!(%{name: "c", organization_id: other.id}, actor: user)

    names = Nspark.Accounts.api_keys_for_org!(org.id) |> Enum.map(& &1.name)
    assert names == ["b", "a"]
  end
end
