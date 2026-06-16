defmodule Nspark.Registry.Skill do
  @moduledoc """
  A reusable capability (e.g. Planning, Retrieval, Verification). Referenced by
  skill nodes via `Node.source_asset_id`. See PRD "Skill Registry".
  """
  use Ash.Resource,
    otp_app: :nspark,
    domain: Nspark.Registry,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "skills"
    repo Nspark.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :organization_id
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  policies do
    policy action_type(:read) do
      authorize_if {Nspark.Checks.HasRole, min_role: :viewer}
    end

    policy action_type(:create) do
      authorize_if {Nspark.Checks.HasRole, min_role: :editor}
    end

    policy action_type(:update) do
      authorize_if {Nspark.Checks.HasRole, min_role: :editor}
    end

    policy action_type(:destroy) do
      authorize_if {Nspark.Checks.HasRole, min_role: :admin}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :description, :string do
      public? true
    end

    attribute :content, :string do
      public? true
    end

    attribute :version, :integer do
      default 1
      allow_nil? false
      public? true
    end

    attribute :status, Nspark.Registry.AssetStatus do
      default :draft
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :organization, Nspark.Accounts.Organization do
      allow_nil? false
    end
  end
end
