defmodule Nspark.Architecture.Graph do
  @moduledoc """
  The primary architecture artifact. The editable working graph is reconciled
  to `Node`/`Edge` rows on save; `graph_version` tracks the current draft
  version number. See docs/HLD.md §4 "Graph Persistence Model".
  """
  use Ash.Resource,
    otp_app: :nspark,
    domain: Nspark.Architecture,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "graphs"
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

    attribute :graph_version, :integer do
      default 1
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :organization, Nspark.Accounts.Organization do
      allow_nil? false
    end

    belongs_to :project, Nspark.Projects.Project do
      allow_nil? false
      attribute_writable? true
      attribute_public? true
    end

    has_many :nodes, Nspark.Architecture.Node
    has_many :edges, Nspark.Architecture.Edge
    has_many :versions, Nspark.Architecture.GraphVersion
  end
end
