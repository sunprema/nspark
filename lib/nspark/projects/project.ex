defmodule Nspark.Projects.Project do
  @moduledoc """
  A logical workspace within an organization. Owns graphs (and, later,
  deployments).
  """
  use Ash.Resource,
    otp_app: :nspark,
    domain: Nspark.Projects,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "projects"
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

    attribute :status, :atom do
      constraints one_of: [:draft, :active, :archived]
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

    has_many :graphs, Nspark.Architecture.Graph
  end
end
