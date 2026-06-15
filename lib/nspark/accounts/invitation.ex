defmodule Nspark.Accounts.Invitation do
  @moduledoc """
  An invite-only onboarding token. An org admin invites an email with a role;
  accepting (by a logged-in user) creates the corresponding Membership.

  Global (not multi-tenant) so token-based acceptance can be looked up without
  a tenant. Email delivery of the token is a follow-up (see User.Senders).
  """
  use Ash.Resource,
    otp_app: :nspark,
    domain: Nspark.Accounts,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "invitations"
    repo Nspark.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :invite do
      description "Invite an email to an organization with a role."
      accept [:email, :role, :organization_id, :invited_by_id]

      change fn changeset, _context ->
        token = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

        changeset
        |> Ash.Changeset.force_change_attribute(:token, token)
        |> Ash.Changeset.force_change_attribute(:status, :pending)
        |> Ash.Changeset.force_change_attribute(
          :expires_at,
          DateTime.add(DateTime.utc_now(), 7, :day)
        )
      end
    end

    read :get_by_token do
      description "Look up a pending invitation by its token."
      argument :token, :string, allow_nil?: false
      get? true
      filter expr(token == ^arg(:token))
    end

    update :accept do
      description "Accept the invitation as the given user; creates a Membership."
      require_atomic? false
      argument :user_id, :uuid, allow_nil?: false

      validate attribute_equals(:status, :pending) do
        message "invitation is no longer pending"
      end

      change set_attribute(:status, :accepted)

      change fn changeset, _context ->
        user_id = Ash.Changeset.get_argument(changeset, :user_id)

        changeset
        |> Ash.Changeset.force_change_attribute(:accepted_at, DateTime.utc_now())
        |> Ash.Changeset.after_action(fn _changeset, invitation ->
          Nspark.Accounts.Membership
          |> Ash.Changeset.for_create(:create, %{
            user_id: user_id,
            organization_id: invitation.organization_id,
            role: invitation.role
          })
          |> Ash.create()
          |> case do
            {:ok, _membership} -> {:ok, invitation}
            {:error, error} -> {:error, error}
          end
        end)
      end
    end

    update :revoke do
      description "Revoke a pending invitation."
      accept []
      change set_attribute(:status, :revoked)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :email, :ci_string do
      allow_nil? false
      public? true
    end

    attribute :role, Nspark.Accounts.Role do
      allow_nil? false
      default :viewer
      public? true
    end

    attribute :token, :string do
      allow_nil? false
      # Not public: server-generated, delivered out of band (email).
      sensitive? true
    end

    attribute :status, :atom do
      constraints one_of: [:pending, :accepted, :revoked]
      default :pending
      allow_nil? false
      public? true
    end

    attribute :expires_at, :utc_datetime_usec do
      public? true
    end

    attribute :accepted_at, :utc_datetime_usec do
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :organization, Nspark.Accounts.Organization do
      allow_nil? false
      attribute_writable? true
      attribute_public? true
    end

    belongs_to :invited_by, Nspark.Accounts.User do
      allow_nil? true
      attribute_writable? true
      attribute_public? true
    end
  end

  identities do
    identity :unique_token, [:token]
  end
end
