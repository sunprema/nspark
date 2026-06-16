defmodule Nspark.Checks.HasRole do
  @moduledoc """
  Policy check: actor holds a minimum org role in the current tenant.

  Role hierarchy (ascending): viewer < editor < admin < owner.

  Per-process memoization means at most one membership query per
  (user_id, tenant) pair per LiveView process lifetime.
  """
  use Ash.Policy.SimpleCheck

  @role_rank %{viewer: 1, editor: 2, admin: 3, owner: 4}

  @impl true
  def describe(opts), do: "actor has role >= #{opts[:min_role]}"

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, context, opts) do
    tenant = subject_tenant(context)

    if is_nil(tenant) do
      false
    else
      role = cached_role(actor.id, tenant)
      not is_nil(role) and rank(role) >= rank(opts[:min_role])
    end
  end

  defp subject_tenant(%{subject: %{tenant: t}}) when not is_nil(t), do: t
  defp subject_tenant(%{query: %{tenant: t}}) when not is_nil(t), do: t
  defp subject_tenant(%{changeset: %{tenant: t}}) when not is_nil(t), do: t
  defp subject_tenant(_), do: nil

  defp rank(role), do: Map.get(@role_rank, role, 0)

  defp cached_role(user_id, tenant) do
    key = {:role_cache, user_id, tenant}

    case Process.get(key) do
      nil ->
        role = fetch_role(user_id, tenant)
        Process.put(key, role)
        role

      role ->
        role
    end
  end

  defp fetch_role(user_id, tenant) do
    Nspark.Accounts.memberships_for_user!(user_id)
    |> Enum.find_value(fn m ->
      if m.organization_id == tenant, do: m.role
    end)
  end
end
