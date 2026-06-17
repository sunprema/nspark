defmodule Nspark.Accounts.Changes.GenerateApiKey do
  @moduledoc """
  Generate a fresh API key secret on `:issue`: set the stored `hash` and the
  non-secret `prefix`, attribute the issuer from the actor, and expose the
  plaintext exactly once via the action's `:plaintext` metadata. The plaintext
  is never written to the database.
  """
  use Ash.Resource.Change

  alias Nspark.Accounts.ApiKey

  @impl true
  def change(changeset, _opts, context) do
    secret = ApiKey.generate_secret()

    changeset
    |> Ash.Changeset.force_change_attribute(:hash, ApiKey.hash_secret(secret))
    |> Ash.Changeset.force_change_attribute(:prefix, ApiKey.display_prefix(secret))
    |> maybe_set_creator(context)
    |> Ash.Changeset.after_action(fn _changeset, record ->
      {:ok, Ash.Resource.put_metadata(record, :plaintext, secret)}
    end)
  end

  defp maybe_set_creator(changeset, %{actor: %{id: id}}) when not is_nil(id),
    do: Ash.Changeset.force_change_attribute(changeset, :created_by_id, id)

  defp maybe_set_creator(changeset, _context), do: changeset
end
