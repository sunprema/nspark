defmodule Nspark.RateLimiterTest do
  use ExUnit.Case, async: true

  alias Nspark.RateLimiter

  # The limiter process is started by the application; we just exercise check/3
  # against unique buckets so tests don't interfere with each other.
  defp bucket, do: "test:#{System.unique_integer([:positive])}"

  test "allows up to the limit, then denies" do
    b = bucket()

    assert {:allow, 2, _} = RateLimiter.check(b, 3, 60_000)
    assert {:allow, 1, _} = RateLimiter.check(b, 3, 60_000)
    assert {:allow, 0, _} = RateLimiter.check(b, 3, 60_000)
    assert {:deny, _} = RateLimiter.check(b, 3, 60_000)
    assert {:deny, _} = RateLimiter.check(b, 3, 60_000)
  end

  test "separate buckets are counted independently" do
    a = bucket()
    b = bucket()

    assert {:deny, _} = (fn -> Enum.map(1..2, fn _ -> RateLimiter.check(a, 1, 60_000) end) |> List.last() end).()
    assert {:allow, 0, _} = RateLimiter.check(b, 1, 60_000)
  end

  test "the window rolls over and the counter resets" do
    b = bucket()
    # A 1ms window guarantees a fresh window on the next call.
    assert {:allow, 0, _} = RateLimiter.check(b, 1, 1)
    assert {:deny, _} = RateLimiter.check(b, 1, 1)
    Process.sleep(3)
    assert {:allow, 0, _} = RateLimiter.check(b, 1, 1)
  end

  test "reset/retry time never exceeds the window" do
    assert {:allow, _, reset} = RateLimiter.check(bucket(), 5, 60_000)
    assert reset > 0 and reset <= 60_000
  end
end
