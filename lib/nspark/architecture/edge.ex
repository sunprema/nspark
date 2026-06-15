defmodule Nspark.Architecture.Edge do
  @moduledoc """
  A directed dependency relationship between two nodes. Arrow direction (source
  -> target) determines compilation/assembly order. See docs/HLD.md §4.
  """
  use Ash.Resource,
    otp_app: :nspark,
    domain: Nspark.Architecture,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "edges"
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

    attribute :edge_type, Nspark.Architecture.EdgeType do
      default :dependency
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :organization, Nspark.Accounts.Organization do
      allow_nil? false
    end

    belongs_to :graph, Nspark.Architecture.Graph do
      allow_nil? false
      attribute_writable? true
      attribute_public? true
    end

    belongs_to :source_node, Nspark.Architecture.Node do
      allow_nil? false
      attribute_writable? true
      attribute_public? true
    end

    belongs_to :target_node, Nspark.Architecture.Node do
      allow_nil? false
      attribute_writable? true
      attribute_public? true
    end
  end
end
