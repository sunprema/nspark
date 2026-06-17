defmodule Nspark.ClientTest do
  use ExUnit.Case, async: false

  alias Nspark.Client

  alias Nspark.Error.{
    Auth,
    NotFound,
    RateLimit,
    ServiceUnavailable
  }

  @base "https://nspark.test"

  defp payload(version \\ 5, prompt \\ "Task: {task}") do
    %{
      "slug" => "support-agent",
      "version" => version,
      "resolved_via" => "version:#{version}",
      "prompt" => prompt,
      "input_schema" => %{
        "variables" => %{"task" => %{"required" => true, "refs" => ["n1"]}},
        "outputs" => ["resolution"],
        "provider" => "anthropic"
      },
      "metadata" => %{"graph_name" => "Support Agent"},
      "stats" => %{"token_estimate" => 12}
    }
  end

  # A request stub that dispenses queued responses and records calls. Each queued
  # entry is `{:ok, %{status:, headers:, body:}}` or `{:error, term}`.
  defp stub(responses) do
    {:ok, agent} = Agent.start_link(fn -> %{queue: responses, calls: []} end)

    fun = fn method, url, headers, _opts ->
      Agent.get_and_update(agent, fn state ->
        [next | rest] = state.queue
        call = %{method: method, url: url, headers: headers}
        {next, %{state | queue: rest, calls: state.calls ++ [call]}}
      end)
    end

    {fun, agent}
  end

  defp calls(agent), do: Agent.get(agent, & &1.calls)

  defp client(fun, opts \\ []) do
    # opts first so a caller's override (e.g. max_retries: 0) wins under
    # Keyword.get's first-match semantics.
    Client.new(@base, "nsk_test", opts ++ [request_fun: fun, max_retries: 1, backoff_ms: 0])
  end

  defp ok(status, body, headers \\ %{}),
    do: {:ok, %{status: status, headers: headers, body: body}}

  test "returns a parsed prompt" do
    {fun, _} = stub([ok(200, payload())])
    assert {:ok, prompt} = client(fun) |> Client.get_prompt("support-agent", version: 5)
    assert prompt.version == 5
    assert prompt.from_cache == false
    assert {:ok, "Task: refund"} = Nspark.Prompt.render(prompt, %{"task" => "refund"})
  end

  test "sends bearer auth and the version param" do
    {fun, agent} = stub([ok(200, payload())])
    client(fun) |> Client.get_prompt("support-agent", version: 5)
    [call] = calls(agent)
    assert call.headers["authorization"] == "Bearer nsk_test"
    assert call.url =~ "version=5"
  end

  test "serves immutable pinned versions from cache without a second request" do
    headers = %{"etag" => ~s("v5"), "cache-control" => "public, max-age=31536000, immutable"}
    {fun, agent} = stub([ok(200, payload(), headers)])
    c = client(fun)

    assert {:ok, first} = Client.get_prompt(c, "support-agent", version: 5)
    assert {:ok, second} = Client.get_prompt(c, "support-agent", version: 5)
    assert first.from_cache == false
    assert second.from_cache == true
    assert length(calls(agent)) == 1
  end

  test "revalidates moving aliases with If-None-Match and handles 304" do
    {fun, agent} =
      stub([
        ok(200, payload(), %{"etag" => ~s("v5"), "cache-control" => "no-cache"}),
        ok(304, nil, %{"etag" => ~s("v5")})
      ])

    c = client(fun)
    assert {:ok, first} = Client.get_prompt(c, "support-agent")
    assert {:ok, second} = Client.get_prompt(c, "support-agent")
    assert first.from_cache == false
    assert second.from_cache == true
    assert [_, second_call] = calls(agent)
    assert second_call.headers["if-none-match"] == ~s("v5")
  end

  test "falls back to last-known-good on a server error" do
    {fun, _} =
      stub([
        ok(200, payload(), %{"etag" => ~s("v5"), "cache-control" => "no-cache"}),
        ok(503, %{"error" => "boom"}),
        ok(503, %{"error" => "boom"})
      ])

    c = client(fun)
    assert {:ok, _} = Client.get_prompt(c, "support-agent")
    assert {:ok, during_outage} = Client.get_prompt(c, "support-agent")
    assert during_outage.from_cache == true
    assert during_outage.version == 5
  end

  test "falls back to last-known-good on a network error" do
    {fun, _} =
      stub([
        ok(200, payload(), %{"etag" => ~s("v5"), "cache-control" => "no-cache"}),
        {:error, :econnrefused},
        {:error, :econnrefused}
      ])

    c = client(fun)
    assert {:ok, _} = Client.get_prompt(c, "support-agent")
    assert {:ok, during_outage} = Client.get_prompt(c, "support-agent")
    assert during_outage.from_cache == true
  end

  test "returns ServiceUnavailable when the cache is cold" do
    {fun, _} = stub([ok(503, %{"error" => "boom"}), ok(503, %{"error" => "boom"})])

    assert {:error, %ServiceUnavailable{}} =
             client(fun) |> Client.get_prompt("support-agent", version: 5)
  end

  test "returns NotFound on 404" do
    {fun, _} = stub([ok(404, %{"error" => "prompt not found"})])

    assert {:error, %NotFound{}} =
             client(fun) |> Client.get_prompt("support-agent", version: 5)
  end

  test "returns Auth error on 401" do
    {fun, _} = stub([ok(401, %{"error" => "invalid api key"})])

    assert {:error, %Auth{status: 401}} =
             client(fun) |> Client.get_prompt("support-agent", version: 5)
  end

  test "returns RateLimit with retry_after on 429" do
    {fun, _} = stub([ok(429, %{"error" => "rate limit exceeded"}, %{"retry-after" => "30"})])

    assert {:error, %RateLimit{retry_after: 30}} =
             client(fun, max_retries: 0) |> Client.get_prompt("support-agent", version: 5)
  end

  test "get_prompt! raises on error" do
    {fun, _} = stub([ok(404, %{"error" => "prompt not found"})])

    assert_raise NotFound, fn ->
      client(fun) |> Client.get_prompt!("support-agent", version: 5)
    end
  end

  test "rejects version and environment together" do
    {fun, _} = stub([])

    assert_raise ArgumentError, fn ->
      client(fun) |> Client.get_prompt("support-agent", version: 5, environment: "production")
    end
  end

  test "render/4 fetches and renders in one call" do
    {fun, _} = stub([ok(200, payload())])

    assert {:ok, "Task: refund"} =
             client(fun) |> Client.render("support-agent", %{"task" => "refund"}, version: 5)
  end

  describe "FileCache durability" do
    test "serves a pinned version across client instances" do
      dir = Path.join(System.tmp_dir!(), "nspark-test-#{System.unique_integer([:positive])}")
      cache = Nspark.Cache.File.new(dir)
      headers = %{"etag" => ~s("v5"), "cache-control" => "public, max-age=31536000, immutable"}

      {fun, agent} = stub([ok(200, payload(), headers)])

      c1 = client(fun, cache: cache)
      assert {:ok, _} = Client.get_prompt(c1, "support-agent", version: 5)

      # A fresh client over the same on-disk cache serves without a network call.
      c2 = client(fun, cache: Nspark.Cache.File.new(dir))
      assert {:ok, prompt} = Client.get_prompt(c2, "support-agent", version: 5)
      assert prompt.from_cache == true
      assert length(calls(agent)) == 1

      File.rm_rf!(dir)
    end
  end
end
