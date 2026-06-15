defmodule Nspark.Registry.Policy do
  @moduledoc """
  A reusable governance rule (Safety, Privacy, Compliance, Legal, Tone).
  See docs/HLD.md §4 and UX §4.3.
  """
  use Ash.Resource,
    otp_app: :nspark,
    domain: Nspark.Registry,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "policies"
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

    attribute :category, :atom do
      constraints one_of: [:safety, :privacy, :compliance, :legal, :tone]
      default :safety
      allow_nil? false
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
