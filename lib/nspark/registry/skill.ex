defmodule Nspark.Registry.Skill do
  @moduledoc """
  A reusable capability (e.g. Planning, Retrieval, Verification). Referenced by
  skill nodes via `Node.source_asset_id`. See PRD "Skill Registry".
  """
  use Ash.Resource,
    otp_app: :nspark,
    domain: Nspark.Registry,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource]

  postgres do
    table "skills"
    repo Nspark.Repo
  end

  paper_trail do
    change_tracking_mode :changes_only
    store_action_name? true
    reference_source? false
    attributes_as_attributes [:organization_id]

    belongs_to_actor :user, Nspark.Accounts.User, domain: Nspark.Accounts
  end

  multitenancy do
    strategy :attribute
    attribute :organization_id
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:name, :description, :content]
      change set_attribute(:status, :draft)
      change relate_actor(:created_by, allow_nil?: true)
      change relate_actor(:updated_by, allow_nil?: true)
    end

    # Editors edit Skill *content* but cannot change its lifecycle status/version.
    update :update do
      primary? true
      accept [:name, :description, :content]
      require_atomic? false
      change relate_actor(:updated_by, allow_nil?: true)
    end

    # Admin-only: promote to a new published version (integer-bump versioning).
    update :publish do
      description "Promote the Skill to a new published version."
      accept []
      require_atomic? false
      change set_attribute(:status, :published)
      change increment(:version)
      change relate_actor(:updated_by, allow_nil?: true)
    end

    # Admin-only: retire the Skill. Deprecated Skills fail graph resolution.
    update :archive do
      description "Deprecate the Skill."
      accept []
      require_atomic? false
      change set_attribute(:status, :deprecated)
      change relate_actor(:updated_by, allow_nil?: true)
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
      authorize_if {Nspark.Checks.HasRole, min_role: :editor}
    end

    # publish/archive are update actions, so the editor policy above also applies;
    # this additional policy ANDs an admin requirement onto just those two.
    policy action([:publish, :archive]) do
      authorize_if {Nspark.Checks.HasRole, min_role: :admin}
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

    belongs_to :created_by, Nspark.Accounts.User do
      domain Nspark.Accounts
      allow_nil? true
    end

    belongs_to :updated_by, Nspark.Accounts.User do
      domain Nspark.Accounts
      allow_nil? true
    end
  end
end
