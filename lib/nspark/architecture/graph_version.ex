defmodule Nspark.Architecture.GraphVersion do
  @moduledoc """
  An immutable snapshot of a graph captured on publish. `graph_snapshot` holds
  the canonical JSON representation of the graph at that version. Deployments
  compile from a pinned snapshot, never from live draft rows. See docs/HLD.md §4.
  """
  use Ash.Resource,
    otp_app: :nspark,
    domain: Nspark.Architecture,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

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

    read :list_for_graph do
      argument :graph_id, :uuid, allow_nil?: false
      filter expr(graph_id == ^arg(:graph_id))
      prepare build(sort: [version_number: :desc])
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if {Nspark.Checks.HasRole, min_role: :viewer}
    end

    # Any editor can publish a graph snapshot.
    policy action_type(:create) do
      authorize_if {Nspark.Checks.HasRole, min_role: :editor}
    end

    policy action_type(:update) do
      authorize_if {Nspark.Checks.HasRole, min_role: :admin}
    end

    # Versions are immutable snapshots; only owners may delete.
    policy action_type(:destroy) do
      authorize_if {Nspark.Checks.HasRole, min_role: :owner}
    end
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

    # Manifest of Registry assets resolved into `graph_snapshot` at publish time
    # (`[%{id, name, version}]`). With content frozen in the snapshot, this records
    # *which* Skill versions a deployment pins — for audit, impact, and rollback.
    attribute :resolved_skills, {:array, :map} do
      allow_nil? false
      default []
      public? true
    end

    # The version's frozen input/output contract (`Nspark.VersionDiff.contract/1`):
    # the `{variables}` a calling app must supply and the `output_var`s produced.
    # Exposed on read so an SDK/client can validate its inputs before calling.
    attribute :input_contract, :map do
      allow_nil? false
      default %{}
      public? true
    end

    # The classified diff of this version vs the immediately preceding one
    # (`Nspark.VersionDiff.diff/2`): `%{"level", "variables", "outputs", ...}`.
    # `%{"level" => "initial"}` for the first version. Denormalized cache for O(1)
    # history rendering — always recomputable from two snapshots.
    attribute :diff_summary, :map do
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
