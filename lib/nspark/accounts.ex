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
      define :members_for_org, action: :list_for_org, args: [:organization_id]
    end

    resource Nspark.Accounts.ApiKey do
      define :issue_api_key, action: :issue
      define :api_keys_for_org, action: :list_for_org, args: [:organization_id]
      define :get_api_key_by_hash, action: :get_by_hash, args: [:hash]
      define :revoke_api_key, action: :revoke
      define :touch_api_key, action: :touch_last_used
    end

    resource Nspark.Accounts.Invitation do
      define :invite_to_organization, action: :invite
      define :get_invitation_by_token, action: :get_by_token, args: [:token]
      define :accept_invitation, action: :accept, args: [:user_id]
      define :revoke_invitation, action: :revoke
      define :pending_invitations_for_org, action: :list_pending_for_org, args: [:organization_id]
    end
  end
end
