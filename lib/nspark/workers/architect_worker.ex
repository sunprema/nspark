defmodule Nspark.Workers.ArchitectWorker do
  @moduledoc """
  Oban worker that calls Claude to decompose a raw prompt into graph nodes/edges,
  then applies the result and broadcasts via PubSub to the originating LiveView.

  Enqueued by `StudioLive` when the user submits the Architect modal. The LiveView
  subscribes to `"architect:{graph_id}"` and receives `{:architect_done, result}`.
  """
  use Oban.Worker, queue: :ai, max_attempts: 2

  alias Nspark.Architecture.Graph

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "prompt" => prompt,
          "graph_id" => graph_id,
          "org_id" => org_id,
          "user_id" => user_id
        }
      }) do
    with {:ok, user} <- fetch_user(user_id),
         {:ok, graph} <- fetch_graph(graph_id, org_id, user),
         {:ok, result} <- Nspark.Architect.from_prompt(prompt),
         {:ok, ids} <- Nspark.Architect.apply_to_graph(result, graph, user, org_id) do
      Phoenix.PubSub.broadcast(
        Nspark.PubSub,
        "architect:#{graph_id}",
        {:architect_done, :ok, ids}
      )

      :ok
    else
      {:error, reason} ->
        Phoenix.PubSub.broadcast(
          Nspark.PubSub,
          "architect:#{graph_id}",
          {:architect_done, :error, to_string(reason)}
        )

        # Return :ok so Oban doesn't retry on application-level failures (bad prompt, etc.)
        # Only network/API errors that raise exceptions will trigger retries.
        :ok
    end
  end

  defp fetch_user(user_id) do
    case Ash.get(Nspark.Accounts.User, user_id, authorize?: false) do
      {:ok, user} -> {:ok, user}
      _ -> {:error, "User not found"}
    end
  end

  defp fetch_graph(graph_id, org_id, user) do
    case Ash.get(Graph, graph_id, tenant: org_id, actor: user) do
      {:ok, graph} -> {:ok, graph}
      _ -> {:error, "Graph not found"}
    end
  end
end
