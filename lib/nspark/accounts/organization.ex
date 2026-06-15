defmodule Nspark.Accounts.Organization do
  @moduledoc """
  The tenant boundary for the platform. Every multi-tenant resource is scoped
  by `organization_id`. Organization itself is global (not multi-tenant).
  """
  use Ash.Resource,
    otp_app: :nspark,
    domain: Nspark.Accounts,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "organizations"
    repo Nspark.Repo
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :slug, :string do
      allow_nil? false
      public? true
    end

    attribute :settings, :map do
      default %{}
      public? true
    end

    timestamps()
  end

  identities do
    identity :unique_slug, [:slug]
  end

  relationships do
    has_many :projects, Nspark.Projects.Project
    has_many :memberships, Nspark.Accounts.Membership
    has_many :invitations, Nspark.Accounts.Invitation

    many_to_many :users, Nspark.Accounts.User do
      through Nspark.Accounts.Membership
      source_attribute_on_join_resource :organization_id
      destination_attribute_on_join_resource :user_id
    end
  end
end
