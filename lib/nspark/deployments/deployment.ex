defmodule Nspark.Deployments.Deployment do
  @moduledoc """
  A pinned deployment of an immutable `GraphVersion` to a named environment.
  The `endpoint_slug` identifies the runtime endpoint; `deployed_version` mirrors
  the GraphVersion's version_number for display. See docs/HLD.md §8.
  """
  use Ash.Resource,
    otp_app: :nspark,
    domain: Nspark.Deployments,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "deployments"
    repo Nspark.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :organization_id
  end

  actions do
    defaults [:read, :destroy, update: :*]

    create :deploy do
      description "Pin a GraphVersion to an environment and activate it."
      accept [:environment, :project_id, :graph_version_id, :deployed_version]

      change set_attribute(:status, :active)

      change fn changeset, _context ->
        env = Ash.Changeset.get_attribute(changeset, :environment) || :dev
        rand = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
        Ash.Changeset.change_attribute(changeset, :endpoint_slug, "#{env}-#{rand}")
      end
    end

    read :for_project do
      argument :project_id, :uuid, allow_nil?: false
      filter expr(project_id == ^arg(:project_id))
      prepare build(sort: [inserted_at: :desc])
    end

    update :retire do
      change set_attribute(:status, :retired)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if {Nspark.Checks.HasRole, min_role: :viewer}
    end

    policy action_type(:create) do
      authorize_if {Nspark.Checks.HasRole, min_role: :editor}
    end

    policy action_type(:update) do
      authorize_if {Nspark.Checks.HasRole, min_role: :admin}
    end

    policy action_type(:destroy) do
      authorize_if {Nspark.Checks.HasRole, min_role: :admin}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :environment, :atom do
      constraints one_of: [:dev, :staging, :production]
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      constraints one_of: [:pending, :active, :failed, :retired]
      default :pending
      allow_nil? false
      public? true
    end

    attribute :endpoint_slug, :string do
      allow_nil? false
      public? true
    end

    attribute :deployed_version, :integer do
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

    belongs_to :graph_version, Nspark.Architecture.GraphVersion do
      allow_nil? false
      attribute_writable? true
      attribute_public? true
    end
  end
end
