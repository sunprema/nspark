defmodule Nspark.Architecture.GraphVersion do
  @moduledoc """
  An immutable snapshot of a graph captured on publish. `graph_snapshot` holds
  the canonical JSON representation of the graph at that version. Deployments
  compile from a pinned snapshot, never from live draft rows. See docs/HLD.md §4.
  """
  use Ash.Resource,
    otp_app: :nspark,
    domain: Nspark.Architecture,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "graph_versions"
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

    attribute :version_number, :integer do
      allow_nil? false
      public? true
    end

    attribute :changelog, :string do
      public? true
    end

    attribute :graph_snapshot, :map do
      allow_nil? false
      default %{}
      public? true
    end

    # Loose reference to the authoring user. Promoted to a managed relationship
    # once User<->Organization membership is formalized.
    attribute :author_id, :uuid do
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
  end
end
