defmodule Nspark.Architecture.Edge do
  @moduledoc """
  A directed dependency relationship between two nodes. Arrow direction (source
  -> target) determines compilation/assembly order. See docs/HLD.md §4.
  """
  use Ash.Resource,
    otp_app: :nspark,
    domain: Nspark.Architecture,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

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
      authorize_if {Nspark.Checks.HasRole, min_role: :editor}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :edge_type, Nspark.Architecture.EdgeType do
      default :dependency
      allow_nil? false
      public? true
    end

    attribute :metadata, :map do
      default %{}
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
