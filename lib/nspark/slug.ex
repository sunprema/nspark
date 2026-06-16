defmodule Nspark.Slug do
  @moduledoc """
  Pure slug helpers. A slug is a stable, URL-safe, human-friendly identifier a
  calling app uses to fetch a prompt at runtime (`GET /api/v1/prompts/:slug`).

  Unlike a deployment's random `endpoint_slug`, a graph's slug is meant to be
  readable and durable across versions, so it is derived from the graph name.
  """

  @doc """
  Slugify an arbitrary string into a lowercase, hyphen-separated token.

  Strips accents-free non-alphanumerics, collapses runs of separators, and trims
  leading/trailing hyphens. Empty/garbage input falls back to `"prompt"`.

      iex> Nspark.Slug.slugify("Agent Planner")
      "agent-planner"
      iex> Nspark.Slug.slugify("  Risk//Review!! ")
      "risk-review"
      iex> Nspark.Slug.slugify("***")
      "prompt"
  """
  @spec slugify(term()) :: String.t()
  def slugify(value) when is_binary(value) do
    slug =
      value
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    if slug == "", do: "prompt", else: slug
  end

  def slugify(_), do: "prompt"

  @doc """
  Disambiguate `base` against a set of already-taken slugs.

  Returns `base` if free, otherwise `base-2`, `base-3`, … until one is unused.
  `taken` may be any enumerable of strings (e.g. a `MapSet`).
  """
  @spec uniquify(String.t(), Enumerable.t()) :: String.t()
  def uniquify(base, taken) do
    set = MapSet.new(taken)

    if MapSet.member?(set, base) do
      Stream.iterate(2, &(&1 + 1))
      |> Enum.find_value(fn n ->
        candidate = "#{base}-#{n}"
        if MapSet.member?(set, candidate), do: nil, else: candidate
      end)
    else
      base
    end
  end
end
