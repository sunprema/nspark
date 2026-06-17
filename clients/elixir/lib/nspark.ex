defmodule Nspark do
  @moduledoc """
  Elixir client for Newtonian Spark runtime prompt delivery.

  Fetch governed, versioned prompts from a Newtonian Spark service, with
  caching, last-known-good fallback, and variable validation against the
  published input contract.

      cache = Nspark.Cache.Memory.new()
      client = Nspark.new("https://nspark.example.com", "nsk_…", cache: cache)

      {:ok, prompt} = Nspark.get_prompt(client, "support-agent", version: 5)
      {:ok, text} = Nspark.Prompt.render(prompt, %{"task" => "Issue a refund"})

  This module delegates to `Nspark.Client`; see it for full documentation.
  """

  defdelegate new(base_url, api_key, opts \\ []), to: Nspark.Client
  defdelegate get_prompt(client, slug, opts \\ []), to: Nspark.Client
  defdelegate get_prompt!(client, slug, opts \\ []), to: Nspark.Client
  defdelegate render(client, slug, variables \\ %{}, opts \\ []), to: Nspark.Client
end
