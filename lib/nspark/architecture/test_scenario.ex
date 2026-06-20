defmodule Nspark.Architecture.TestScenario do
  @moduledoc """
  An author-defined behavioral scenario for a graph's PromptBasic control layer
  (BUILD_PLAN Phase 4 / memo §6). A scenario declares the slice of intended behavior
  the static lens cannot infer — `given {state, memory, true conditions}` → `expect
  {handled, state_to, tool}` — and is run deterministically through
  `Nspark.PromptBasic.TestRunner` (no LLM).

  Expectations are stored as stable facts (handled / target state / tool name), never
  IR rule ids, since rule ids shift with compile order.
  """
  use Ash.Resource,
    otp_app: :nspark,
    domain: Nspark.Architecture,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "test_scenarios"
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
      prepare build(sort: [inserted_at: :asc])
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if {Nspark.Checks.HasRole, min_role: :viewer}
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if {Nspark.Checks.HasRole, min_role: :editor}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      default "New scenario"
      public? true
    end

    # The starting state for this turn (nil = the program's initial state).
    attribute :given_state, :string do
      public? true
    end

    # Memory facts true at the start of the turn (string => string).
    attribute :given_memory, :map do
      allow_nil? false
      default %{}
      public? true
    end

    # Semantic conditions the author asserts are TRUE this turn.
    attribute :given_conds, {:array, :string} do
      allow_nil? false
      default []
      public? true
    end

    # Expected outcome: any of "handled" (bool), "state_to" (string), "tool" (string).
    # Only the provided keys are checked by the runner.
    attribute :expect, :map do
      allow_nil? false
      default %{}
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
