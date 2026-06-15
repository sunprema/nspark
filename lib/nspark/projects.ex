defmodule Nspark.Projects do
  use Ash.Domain, otp_app: :nspark, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Nspark.Projects.Project
  end
end
