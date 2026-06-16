defmodule Nspark.Deployments do
  @moduledoc """
  The deployments domain: pinned GraphVersion endpoints per environment.
  See docs/HLD.md §8 "Deployment Architecture".
  """
  use Ash.Domain, otp_app: :nspark, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Nspark.Deployments.Deployment do
      define :deploy_version, action: :deploy
      define :deployments_for_project, action: :for_project, args: [:project_id]
      define :retire_deployment, action: :retire
    end
  end
end
