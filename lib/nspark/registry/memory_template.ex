defmodule Nspark.Registry.MemoryTemplate do
  @moduledoc """
  A reusable memory structure (Episodic, Working, Retrieval). See docs/HLD.md §4.
  """
  use Ash.Resource,
    otp_app: :nspark,
    domain: Nspark.Registry,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "memory_templates"
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

    attribute :kind, :atom do
      constraints one_of: [:episodic, :working, :retrieval]
      default :episodic
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
