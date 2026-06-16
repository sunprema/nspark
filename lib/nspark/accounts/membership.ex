defmodule Nspark.Accounts.Membership do
  @moduledoc """
  Maps a (global) User to an Organization with a per-org role. This is the
  access layer; it is intentionally NOT multi-tenant so a user's memberships
  can be looked up before any tenant is established (login / org selection).
  """
  use Ash.Resource,
    otp_app: :nspark,
    domain: Nspark.Accounts,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "memberships"
    repo Nspark.Repo
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]

    read :list_for_user do
      description "All memberships for a given user (used for org selection)."
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
    end

    read :list_for_org do
      description "All memberships for an organization (members management screen)."
      argument :organization_id, :uuid, allow_nil?: false
      filter expr(organization_id == ^arg(:organization_id))
      prepare build(load: [:user], sort: [inserted_at: :asc])
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :role, Nspark.Accounts.Role do
      allow_nil? false
      default :viewer
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :user, Nspark.Accounts.User do
      allow_nil? false
      attribute_writable? true
      attribute_public? true
    end

    belongs_to :organization, Nspark.Accounts.Organization do
      allow_nil? false
      attribute_writable? true
      attribute_public? true
    end
  end

  identities do
    identity :unique_user_org, [:user_id, :organization_id]
  end
end
