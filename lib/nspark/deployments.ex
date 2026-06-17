defmodule Nspark.Deployments do
  @moduledoc """
  The deployments domain: pinned GraphVersion endpoints per environment.
  See docs/HLD.md §8 "Deployment Architecture".
  """
  use Ash.Domain, otp_app: :nspark, extensions: [AshAdmin.Domain, AshPaperTrail.Domain]

  alias Nspark.Deployments.Deployment
  require Ash.Query

  admin do
    show? true
  end

  paper_trail do
    include_versions?(true)
  end

  resources do
    resource Nspark.Deployments.Deployment do
      define :deploy_version, action: :deploy
      define :deployments_for_project, action: :for_project, args: [:project_id]
      define :retire_deployment, action: :retire
    end
  end

  @doc """
  The `GraphVersion` currently live in `environment` for `graph_id` — i.e. the
  most recent **active** deployment of any of that graph's versions to that
  environment, with `:graph_version` loaded. Returns `{:ok, deployment}`,
  `{:ok, nil}` when nothing is live there, or `{:error, _}`.

  This is the "what is this environment serving right now" lookup the deploy-time
  breaking-change gate diffs against (see `Nspark.Architecture.deploy_impact/3`).
  Mirrors the resolver in `Nspark.PromptDelivery` for environment aliases.
  """
  def active_deployment_for(graph_id, environment, opts) do
    Deployment
    |> Ash.Query.filter(
      graph_version.graph_id == ^graph_id and environment == ^environment and status == :active
    )
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.Query.load(:graph_version)
    |> Ash.read(opts)
    |> case do
      {:ok, [deployment]} -> {:ok, deployment}
      {:ok, []} -> {:ok, nil}
      error -> error
    end
  end
end
