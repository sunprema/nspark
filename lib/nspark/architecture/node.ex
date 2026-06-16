defmodule Nspark.Architecture.Node do
  @moduledoc """
  A graph component. `type` is one of the nine node types; `source_asset_id`
  links a node to a Registry asset (e.g. a linked Skill). See docs/HLD.md §4.
  """
  use Ash.Resource,
    otp_app: :nspark,
    domain: Nspark.Architecture,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource]

  postgres do
    table "nodes"
    repo Nspark.Repo
  end

  paper_trail do
    change_tracking_mode :changes_only
    store_action_name? true
    reference_source? false
    attributes_as_attributes [:organization_id, :graph_id]

    belongs_to_actor :user, Nspark.Accounts.User, domain: Nspark.Accounts
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

    attribute :type, Nspark.Architecture.NodeType do
      allow_nil? false
      public? true
    end

    attribute :label, :string do
      allow_nil? false
      public? true
    end

    attribute :content, :string do
      public? true
    end

    attribute :metadata, :map do
      default %{}
      public? true
    end

    attribute :is_muted, :boolean do
      default false
      allow_nil? false
      public? true
    end

    attribute :source_asset_id, :uuid do
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
