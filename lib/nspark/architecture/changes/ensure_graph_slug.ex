defmodule Nspark.Architecture.Changes.EnsureGraphSlug do
  @moduledoc """
  Populate `Graph.slug` on create when the caller didn't supply one.

  Derives a readable base slug from the graph `name` and disambiguates it against
  the slugs already taken in the same organization (`base`, `base-2`, …). The
  `unique_slug` identity remains the authoritative race backstop.
  """
  use Ash.Resource.Change

  alias Nspark.Architecture.Graph

  @impl true
  def change(changeset, _opts, _context) do
    # Set the slug while the changeset is being built so the `allow_nil?: false`
    # requirement on `:slug` sees a value (it is validated before action hooks run).
    ensure_slug(changeset)
  end

  defp ensure_slug(changeset) do
    case Ash.Changeset.get_attribute(changeset, :slug) do
      slug when is_binary(slug) and slug != "" ->
        Ash.Changeset.force_change_attribute(changeset, :slug, Nspark.Slug.slugify(slug))

      _ ->
        base = changeset |> Ash.Changeset.get_attribute(:name) |> Nspark.Slug.slugify()
        slug = Nspark.Slug.uniquify(base, taken_slugs(changeset))
        Ash.Changeset.force_change_attribute(changeset, :slug, slug)
    end
  end

  # Slugs already used in this tenant. Authorization is bypassed: this is an
  # internal uniqueness probe, not a user-facing read, and runs inside the
  # create the actor is already permitted to perform.
  defp taken_slugs(changeset) do
    Graph
    |> Ash.Query.select([:slug])
    |> Ash.read!(tenant: changeset.tenant, authorize?: false)
    |> Enum.map(& &1.slug)
  end
end
