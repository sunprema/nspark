defmodule Nspark.Accounts.ApiKey do
  @moduledoc """
  A scoped, hashed credential a calling application uses to fetch prompts from
  the runtime API (`GET /api/v1/prompts/:slug`). Unlike a user JWT, the key
  itself is the principal: it carries its own scope and is not tied to a session.

  Scope (narrowing, all optional except org):

    * `organization_id` — the tenant the key acts within (required)
    * `project_id`      — limits the key to one project (nil = any project in org)
    * `environment`     — limits environment-alias lookups to one env
                          (nil = any environment)

  Like `Membership` and `Token`, this is a **global** (non-multitenant) auth
  resource so a key can be resolved from its hash before any tenant is known.
  Only the SHA-256 `hash` of the secret is stored; the plaintext is shown once
  at issue time and never persisted. Audit lives in columns: `created_by`,
  `revoked_by`/`revoked_at`, and `last_used_at`.

  Authorization is enforced by the management UI (admin-gated), mirroring the
  policy-free `Membership` resource; the security-critical path — authenticating
  a presented key — runs through `get_by_hash` + the expiry/revocation checks in
  `NsparkWeb.ApiKeyAuth`.
  """
  use Ash.Resource,
    otp_app: :nspark,
    domain: Nspark.Accounts,
    data_layer: AshPostgres.DataLayer

  @secret_prefix "nsk_"

  postgres do
    table "api_keys"
    repo Nspark.Repo
  end

  actions do
    defaults [:read]

    create :issue do
      description "Issue a new API key. Returns the plaintext secret once via metadata."
      accept [:name, :environment, :organization_id, :project_id, :expires_at]

      # The one-time plaintext secret. Read it from the returned record's
      # metadata (`Ash.Resource.get_metadata(key, :plaintext)`); it is never stored.
      metadata :plaintext, :string, allow_nil?: false

      change Nspark.Accounts.Changes.GenerateApiKey
    end

    read :list_for_org do
      description "All keys issued for an organization (management screen)."
      argument :organization_id, :uuid, allow_nil?: false
      filter expr(organization_id == ^arg(:organization_id))
      # `:project` is multitenant and can't be eager-loaded from this global
      # resource without a tenant; the UI maps `project_id` from its own project
      # list. `:created_by` (User) is global and safe to load.
      prepare build(load: [:created_by], sort: [inserted_at: :desc])
    end

    read :get_by_hash do
      description "Look up a key by its SHA-256 hash (authentication path)."
      get? true
      argument :hash, :string, allow_nil?: false, sensitive?: true
      filter expr(hash == ^arg(:hash))
    end

    update :revoke do
      description "Permanently revoke a key."
      require_atomic? false
      change set_attribute(:revoked_at, &DateTime.utc_now/0)
      change relate_actor(:revoked_by, allow_nil?: true)
    end

    update :touch_last_used do
      description "Record that the key was just used (called from the auth plug)."
      require_atomic? false
      change set_attribute(:last_used_at, &DateTime.utc_now/0)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    # A non-secret display hint (the secret's leading characters) so a key is
    # identifiable in the UI without revealing it.
    attribute :prefix, :string do
      allow_nil? false
      public? true
    end

    # SHA-256 hex digest of the plaintext secret. The plaintext is never stored.
    attribute :hash, :string do
      allow_nil? false
      sensitive? true
    end

    attribute :environment, :atom do
      constraints one_of: [:dev, :staging, :production]
      public? true
    end

    attribute :last_used_at, :utc_datetime_usec, public?: true
    attribute :expires_at, :utc_datetime_usec, public?: true
    attribute :revoked_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  relationships do
    belongs_to :organization, Nspark.Accounts.Organization do
      allow_nil? false
      attribute_writable? true
      attribute_public? true
    end

    belongs_to :project, Nspark.Projects.Project do
      attribute_writable? true
      attribute_public? true
    end

    belongs_to :created_by, Nspark.Accounts.User
    belongs_to :revoked_by, Nspark.Accounts.User
  end

  identities do
    identity :unique_hash, [:hash]
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  @doc "The prefix every issued secret carries (`nsk_`)."
  def secret_prefix, do: @secret_prefix

  @doc "Generate a fresh plaintext secret, e.g. `nsk_AbC...` (URL-safe, ~32 chars)."
  @spec generate_secret() :: String.t()
  def generate_secret do
    @secret_prefix <> (24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
  end

  @doc "SHA-256 hex digest used for storage and constant-shape lookup."
  @spec hash_secret(String.t()) :: String.t()
  def hash_secret(secret) when is_binary(secret),
    do: :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)

  @doc "A short, non-secret display hint derived from a plaintext secret."
  @spec display_prefix(String.t()) :: String.t()
  def display_prefix(secret) when is_binary(secret), do: String.slice(secret, 0, 11)

  @doc "True if the key is neither revoked nor past its expiry."
  @spec active?(map()) :: boolean()
  def active?(%{revoked_at: revoked_at, expires_at: expires_at}) do
    is_nil(revoked_at) and
      (is_nil(expires_at) or DateTime.compare(expires_at, DateTime.utc_now()) == :gt)
  end
end
