defmodule Nspark.Accounts do
  use Ash.Domain, otp_app: :nspark, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Nspark.Accounts.Token
    resource Nspark.Accounts.User

    resource Nspark.Accounts.Organization do
      define :create_organization, action: :create, args: [:name, :slug]
    end

    resource Nspark.Accounts.Membership do
      define :memberships_for_user, action: :list_for_user, args: [:user_id]
    end

    resource Nspark.Accounts.Invitation do
      define :invite_to_organization, action: :invite
      define :get_invitation_by_token, action: :get_by_token, args: [:token]
      define :accept_invitation, action: :accept, args: [:user_id]
      define :revoke_invitation, action: :revoke
    end
  end
end
