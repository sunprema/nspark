"""Client behavior: caching, revalidation, fallback, errors (mocked HTTP)."""

import json

import pytest
import responses

from nspark import (
    AuthenticationError,
    Client,
    FileCache,
    PromptNotFoundError,
    RateLimitError,
    ServiceUnavailableError,
)
from nspark.cache import InMemoryCache

BASE = "https://nspark.test"
URL = f"{BASE}/api/v1/prompts/support-agent"


def payload(version=5, prompt="Task: {task}"):
    return {
        "slug": "support-agent",
        "version": version,
        "resolved_via": f"version:{version}",
        "prompt": prompt,
        "input_schema": {
            "variables": {"task": {"required": True, "refs": ["n1"]}},
            "outputs": ["resolution"],
            "provider": "anthropic",
        },
        "metadata": {"graph_name": "Support Agent"},
        "stats": {"token_estimate": 12},
    }


def client(**kwargs):
    kwargs.setdefault("max_retries", 1)
    kwargs.setdefault("backoff", 0)
    return Client(BASE, "nsk_test", **kwargs)


@responses.activate
def test_get_prompt_returns_parsed_prompt():
    responses.add(responses.GET, URL, json=payload(), status=200)
    c = client()
    p = c.get_prompt("support-agent", version=5)
    assert p.version == 5
    assert p.from_cache is False
    assert p.render({"task": "refund"}) == "Task: refund"


@responses.activate
def test_sends_bearer_and_version_param():
    responses.add(responses.GET, URL, json=payload(), status=200)
    client().get_prompt("support-agent", version=5)
    req = responses.calls[0].request
    assert req.headers["Authorization"] == "Bearer nsk_test"
    assert "version=5" in req.url


@responses.activate
def test_immutable_pinned_version_served_from_cache_without_second_request():
    responses.add(
        responses.GET,
        URL,
        json=payload(),
        status=200,
        headers={"ETag": '"v5"', "Cache-Control": "public, max-age=31536000, immutable"},
    )
    c = client()
    first = c.get_prompt("support-agent", version=5)
    second = c.get_prompt("support-agent", version=5)
    assert first.from_cache is False
    assert second.from_cache is True
    assert len(responses.calls) == 1  # second served from cache, no network


@responses.activate
def test_moving_alias_revalidates_with_if_none_match_and_304():
    # First fetch of @latest: no-cache, carries an ETag.
    responses.add(
        responses.GET,
        URL,
        json=payload(),
        status=200,
        headers={"ETag": '"v5"', "Cache-Control": "no-cache"},
    )
    # Second fetch: server says Not Modified.
    responses.add(responses.GET, URL, status=304, headers={"ETag": '"v5"'})

    c = client()
    first = c.get_prompt("support-agent")  # @latest
    second = c.get_prompt("support-agent")
    assert first.from_cache is False
    assert second.from_cache is True
    assert len(responses.calls) == 2
    assert responses.calls[1].request.headers["If-None-Match"] == '"v5"'


@responses.activate
def test_falls_back_to_last_known_good_on_server_error():
    responses.add(
        responses.GET,
        URL,
        json=payload(),
        status=200,
        headers={"ETag": '"v5"', "Cache-Control": "no-cache"},
    )
    responses.add(responses.GET, URL, status=503)

    c = client()
    good = c.get_prompt("support-agent")  # warms cache
    during_outage = c.get_prompt("support-agent")  # 503 → last-known-good
    assert during_outage.from_cache is True
    assert during_outage.version == 5


@responses.activate
def test_service_unavailable_when_cache_cold():
    responses.add(responses.GET, URL, status=503)
    responses.add(responses.GET, URL, status=503)
    with pytest.raises(ServiceUnavailableError):
        client().get_prompt("support-agent", version=5)


@responses.activate
def test_404_raises_prompt_not_found():
    responses.add(responses.GET, URL, json={"error": "prompt not found"}, status=404)
    with pytest.raises(PromptNotFoundError):
        client().get_prompt("support-agent", version=5)


@responses.activate
def test_401_raises_authentication_error():
    responses.add(responses.GET, URL, json={"error": "invalid api key"}, status=401)
    with pytest.raises(AuthenticationError):
        client().get_prompt("support-agent", version=5)


@responses.activate
def test_429_raises_rate_limit_error_with_retry_after():
    responses.add(
        responses.GET, URL, json={"error": "rate limit exceeded"}, status=429,
        headers={"Retry-After": "30"},
    )
    responses.add(
        responses.GET, URL, json={"error": "rate limit exceeded"}, status=429,
        headers={"Retry-After": "30"},
    )
    with pytest.raises(RateLimitError) as exc:
        client(max_retries=0).get_prompt("support-agent", version=5)
    assert exc.value.retry_after == 30


@responses.activate
def test_file_cache_survives_new_client_instance(tmp_path):
    responses.add(
        responses.GET,
        URL,
        json=payload(),
        status=200,
        headers={"ETag": '"v5"', "Cache-Control": "public, max-age=31536000, immutable"},
    )
    cache_dir = str(tmp_path / "lkg")

    c1 = client(cache=FileCache(cache_dir))
    c1.get_prompt("support-agent", version=5)

    # A brand-new client with the same on-disk cache serves the pinned version
    # without any network call.
    c2 = client(cache=FileCache(cache_dir))
    p = c2.get_prompt("support-agent", version=5)
    assert p.from_cache is True
    assert len(responses.calls) == 1


@responses.activate
def test_render_convenience_method():
    responses.add(responses.GET, URL, json=payload(), status=200)
    text = client().render("support-agent", {"task": "refund"}, version=5)
    assert text == "Task: refund"


def test_version_and_environment_are_mutually_exclusive():
    with pytest.raises(ValueError):
        client().get_prompt("support-agent", version=5, environment="production")


def test_in_memory_cache_roundtrip():
    from nspark.cache import CacheEntry

    cache = InMemoryCache()
    assert cache.get("k") is None
    entry = CacheEntry(payload={"a": 1}, etag='"x"', immutable=True, stored_at=0.0)
    cache.set("k", entry)
    assert cache.get("k").payload == {"a": 1}
