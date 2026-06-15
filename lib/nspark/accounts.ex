defmodule Nspark.Accounts do
  use Ash.Domain, otp_app: :nspark, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Nspark.Accounts.Token
    resource Nspark.Accounts.User
  end
end
