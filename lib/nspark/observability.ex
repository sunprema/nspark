defmodule Nspark.Observability do
  @moduledoc """
  Runtime observability: append-only `RunEvent` records of prompt fetches and
  deployment runs. This is the substrate the eval track reads and the usage
  surface the dashboard renders. See `Nspark.Observability.RunEvent`.
  """
  use Ash.Domain, otp_app: :nspark, extensions: [AshAdmin.Domain]

  alias Nspark.Observability.RunEvent

  admin do
    show? true
  end

  resources do
    resource RunEvent do
      define :recent_run_events, action: :recent, args: [{:optional, :graph_id}]
      define :record_run_feedback, action: :record_feedback
    end
  end

  @doc """
  Record a runtime resolution event, fire-and-forget.

  Telemetry must never slow down or fail the request it observes, so the write
  runs in a supervised task and all errors are swallowed (logged at `:warning`).
  The principal is the request's own API key or user, so the create runs
  unauthorized at the Ash layer — the tenant is what scopes it.

  `attrs` must include `:organization_id` and `:source`; everything else is
  optional and maps to `RunEvent` attributes.
  """
  @spec record(map()) :: :ok
  def record(%{organization_id: org_id} = attrs) when not is_nil(org_id) do
    # `organization_id` is the multitenancy attribute: it's set via `tenant:`,
    # not as an action input, so drop it from the accepted attrs.
    input = Map.delete(attrs, :organization_id)

    Task.Supervisor.start_child(Nspark.TaskSupervisor, fn ->
      try do
        Ash.create!(RunEvent, input, action: :record, tenant: org_id, authorize?: false)
        :ok
      rescue
        e ->
          require Logger
          Logger.warning("RunEvent record failed: #{Exception.message(e)}")
          :ok
      end
    end)

    :ok
  end

  def record(_attrs), do: :ok
end
