defmodule Nspark.Observability.RunEvent do
  @moduledoc """
  An append-only record of one runtime resolution — either a pinned-version
  prompt fetch (`GET /api/v1/prompts/:slug`) or a deployment run
  (`POST /api/v1/deployments/:id/run`).

  This is the observability substrate for the platform: what was served, which
  immutable `GraphVersion` answered, who called, how it scoped, how long it took,
  and an optional `outcome` signal attached after the fact. It exists for its own
  sake — debugging, usage visibility, and the input the eval track reads — and is
  deliberately the *only* place runtime traffic is captured. See docs/HLD.md.

  ## Privacy

  Request payloads (the `variables` a caller injects) can carry customer data, so
  the event stores only `variable_keys` — the variable *names*, never values. No
  prompt output is stored either; the immutable `graph_version_id` already
  pins exactly what content was served.

  ## Immutability

  Events are append-only. After creation only the feedback signal
  (`outcome`/`feedback_note`) may be set, via `:record_feedback`. There is no
  general update. Deletion is reserved for `:admin` (retention/erasure).
  """
  use Ash.Resource,
    otp_app: :nspark,
    domain: Nspark.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "run_events"
    repo Nspark.Repo

    custom_indexes do
      # The dashboard reads recent events per org (and per graph), newest first.
      index [:organization_id, :inserted_at]
      index [:organization_id, :graph_id, :inserted_at]
    end

    references do
      # Telemetry must survive the things it observed: a graph/version/deployment
      # being deleted should not cascade away its historical run record.
      reference :graph, on_delete: :nilify
      reference :graph_version, on_delete: :nilify
      reference :deployment, on_delete: :nilify
      reference :api_key, on_delete: :nilify
    end
  end

  multitenancy do
    strategy :attribute
    attribute :organization_id
  end

  actions do
    defaults [:read, :destroy]

    create :record do
      description "Append a runtime resolution event. Written fire-and-forget by the runtime."

      accept [
        :source,
        :status,
        :http_status,
        :resolved_via,
        :latency_ms,
        :token_estimate,
        :error_reason,
        :principal_type,
        :variable_keys,
        :graph_id,
        :graph_version_id,
        :deployment_id,
        :api_key_id
      ]
    end

    update :record_feedback do
      description "Attach an outcome signal to an existing event (the eval/feedback hook)."
      accept [:outcome, :feedback_note]
      require_atomic? false
    end

    read :recent do
      description "Most recent events first, optionally filtered to one graph."
      argument :graph_id, :uuid, allow_nil?: true

      filter expr(is_nil(^arg(:graph_id)) or graph_id == ^arg(:graph_id))
      prepare build(sort: [inserted_at: :desc], limit: 200)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if {Nspark.Checks.HasRole, min_role: :viewer}
    end

    # The runtime records as the authenticated principal (an API key or user),
    # which is already a member; recording its own traffic needs no elevation.
    policy action(:record) do
      authorize_if {Nspark.Checks.HasRole, min_role: :viewer}
    end

    policy action(:record_feedback) do
      authorize_if {Nspark.Checks.HasRole, min_role: :viewer}
    end

    # Retention / erasure only.
    policy action_type(:destroy) do
      authorize_if {Nspark.Checks.HasRole, min_role: :admin}
    end
  end

  attributes do
    uuid_primary_key :id

    # Which runtime surface produced the event.
    attribute :source, :atom do
      allow_nil? false
      constraints one_of: [:prompt_fetch, :deployment_run]
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      default :ok
      constraints one_of: [:ok, :error]
      public? true
    end

    attribute :http_status, :integer, public?: true

    # The qualifier the request resolved through ("@latest", "version:5",
    # "production"), mirrored from PromptDelivery's `resolved_via`.
    attribute :resolved_via, :string, public?: true

    # Server-side processing time for the resolution, in milliseconds.
    attribute :latency_ms, :integer, public?: true

    # Estimated tokens of the compiled artifact that was served.
    attribute :token_estimate, :integer, public?: true

    # Present only when status is :error (e.g. "prompt_not_found").
    attribute :error_reason, :string, public?: true

    attribute :principal_type, :atom do
      constraints one_of: [:api_key, :user]
      public? true
    end

    # Variable *names* injected by the caller — never values (see @moduledoc).
    attribute :variable_keys, {:array, :string} do
      allow_nil? false
      default []
      public? true
    end

    # Outcome signal, attached after the fact via :record_feedback. The eval track
    # and any future improvement loop read this; it is :unrated until set.
    attribute :outcome, :atom do
      allow_nil? false
      default :unrated
      constraints one_of: [:unrated, :positive, :negative]
      public? true
    end

    attribute :feedback_note, :string, public?: true

    timestamps()
  end

  relationships do
    belongs_to :organization, Nspark.Accounts.Organization do
      allow_nil? false
    end

    # All nullable: error events may have no resolved version, prompt fetches have
    # no deployment, and user-token calls have no API key.
    belongs_to :graph, Nspark.Architecture.Graph do
      attribute_writable? true
      attribute_public? true
    end

    belongs_to :graph_version, Nspark.Architecture.GraphVersion do
      attribute_writable? true
      attribute_public? true
    end

    belongs_to :deployment, Nspark.Deployments.Deployment do
      attribute_writable? true
      attribute_public? true
    end

    belongs_to :api_key, Nspark.Accounts.ApiKey do
      attribute_writable? true
      attribute_public? true
    end
  end
end
