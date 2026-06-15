defmodule Nspark.Registry.PackageItem do
  @moduledoc """
  Membership of a registry asset in a package. Uses a polymorphic reference
  (`asset_type` + `asset_id`) so a package can bundle mixed asset types without
  one join table per type. There is no DB foreign key on `asset_id`; referential
  integrity is enforced in application logic.
  """
  use Ash.Resource,
    otp_app: :nspark,
    domain: Nspark.Registry,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "package_items"
    repo Nspark.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :organization_id
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  attributes do
    uuid_primary_key :id

    attribute :asset_type, :atom do
      constraints one_of: [:skill, :policy, :schema, :memory_template]
      allow_nil? false
      public? true
    end

    attribute :asset_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :position, :integer do
      default 0
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :organization, Nspark.Accounts.Organization do
      allow_nil? false
    end

    belongs_to :package, Nspark.Registry.Package do
      allow_nil? false
      attribute_writable? true
      attribute_public? true
    end
  end

  identities do
    identity :unique_package_asset, [:package_id, :asset_type, :asset_id]
  end
end
