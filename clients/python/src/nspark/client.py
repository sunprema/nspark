"""The Newtonian Spark runtime client.

A calling application fetches a published prompt by its stable slug, pins a
version (or follows ``@latest`` / an environment alias), and injects its own
variables. The client is built for the critical path:

* **Pinned versions are cached forever.** The server marks ``?version=N``
  immutable, so after the first fetch the client never hits the network for it.
* **Moving aliases revalidate cheaply.** ``@latest`` / environment lookups send
  ``If-None-Match`` and a ``304`` re-serves the cached body for free.
* **Outages fall back to last-known-good.** If the service is unreachable or
  returns 5xx, the client serves the last good copy from cache instead of
  raising — set ``from_cache`` is how the caller can tell.
* **Variables are validated before substitution**, against the version's
  published input contract, so a renamed/dropped variable surfaces as an error
  instead of a malformed prompt.

Basic use::

    from nspark import Client

    client = Client("https://nspark.example.com", api_key="nsk_…")
    prompt = client.get_prompt("support-agent", version=5)
    text = prompt.render({"task": "Issue a refund"})
"""

from __future__ import annotations

import time
from typing import Any, Mapping, Optional, Union

import requests

from .cache import Cache, CacheEntry, InMemoryCache
from .exceptions import (
    APIError,
    AuthenticationError,
    PromptNotFoundError,
    RateLimitError,
    ServiceUnavailableError,
)
from .models import Prompt

__all__ = ["Client"]

_DEFAULT_TIMEOUT = 5.0
_DEFAULT_MAX_RETRIES = 2
_DEFAULT_BACKOFF = 0.2


class Client:
    """Synchronous client for the prompt-retrieval API.

    Args:
        base_url: Root URL of the Newtonian Spark service (no trailing path).
        api_key: A scoped API key (``nsk_…``). Sent as a bearer token.
        timeout: Per-request timeout in seconds.
        max_retries: Retries on transient failures (network error / 5xx / 429)
            before falling back to cache.
        backoff: Base seconds for exponential backoff between retries.
        cache: Backing cache. Defaults to a per-process :class:`InMemoryCache`.
            Pass a :class:`~nspark.cache.FileCache` for durable last-known-good.
        session: An existing :class:`requests.Session` (e.g. with custom
            adapters). One is created if omitted.
    """

    def __init__(
        self,
        base_url: str,
        api_key: str,
        *,
        timeout: float = _DEFAULT_TIMEOUT,
        max_retries: int = _DEFAULT_MAX_RETRIES,
        backoff: float = _DEFAULT_BACKOFF,
        cache: Optional[Cache] = None,
        session: Optional[requests.Session] = None,
    ) -> None:
        if not base_url:
            raise ValueError("base_url is required")
        if not api_key:
            raise ValueError("api_key is required")

        self._base_url = base_url.rstrip("/")
        self._timeout = timeout
        self._max_retries = max(0, max_retries)
        self._backoff = backoff
        self._cache = cache if cache is not None else InMemoryCache()
        self._session = session or requests.Session()
        self._session.headers.update(
            {
                "Authorization": f"Bearer {api_key}",
                "Accept": "application/json",
            }
        )

    # ── public API ──────────────────────────────────────────────────────────

    def get_prompt(
        self,
        slug: str,
        *,
        version: Optional[Union[int, str]] = None,
        environment: Optional[str] = None,
    ) -> Prompt:
        """Fetch a prompt by slug.

        Specify at most one qualifier:

        * ``version=5`` — exact pinned version (immutable, cached forever)
        * ``version="@latest"`` — highest published version (revalidated)
        * ``environment="production"`` — version live in that environment
          (revalidated)

        With no qualifier the server returns ``@latest``.

        Raises :class:`PromptNotFoundError`, :class:`AuthenticationError`,
        :class:`RateLimitError`, or — only when the fetch fails *and* nothing is
        cached — :class:`ServiceUnavailableError`.
        """
        if version is not None and environment is not None:
            raise ValueError("specify either version or environment, not both")

        params = self._build_params(version, environment)
        cache_key = self._cache_key(slug, params)

        cached = self._cache.get(cache_key)

        # An immutable (pinned-version) entry can never change content; serve it
        # without touching the network.
        if cached is not None and cached.immutable:
            return Prompt.from_payload(cached.payload, from_cache=True)

        return self._fetch(slug, params, cache_key, cached)

    def render(
        self,
        slug: str,
        variables: Optional[Mapping[str, Any]] = None,
        *,
        version: Optional[Union[int, str]] = None,
        environment: Optional[str] = None,
        strict: bool = True,
    ) -> str:
        """Convenience: fetch a prompt and render it in one call."""
        prompt = self.get_prompt(slug, version=version, environment=environment)
        return prompt.render(variables, strict=strict)

    def close(self) -> None:
        self._session.close()

    def __enter__(self) -> "Client":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    # ── fetch + retry + fallback ──────────────────────────────────────────────

    def _fetch(
        self,
        slug: str,
        params: dict,
        cache_key: str,
        cached: Optional[CacheEntry],
    ) -> Prompt:
        url = f"{self._base_url}/api/v1/prompts/{slug}"
        headers = {}
        if cached is not None and cached.etag:
            headers["If-None-Match"] = cached.etag

        last_error: Optional[Exception] = None

        for attempt in range(self._max_retries + 1):
            try:
                resp = self._session.get(
                    url, params=params, headers=headers, timeout=self._timeout
                )
            except requests.RequestException as exc:
                # Connection-level failure: retry, then fall back to cache.
                last_error = exc
                if self._sleep_before_retry(attempt):
                    continue
                break

            if resp.status_code == 200:
                return self._store_and_return(cache_key, resp)

            if resp.status_code == 304:
                # Not modified — the cached body is current.
                if cached is not None:
                    return Prompt.from_payload(cached.payload, from_cache=True)
                # 304 with a cold cache shouldn't happen (we only send
                # If-None-Match when we have an entry); treat as a miss.
                last_error = APIError(304, "not modified but no cached entry")
                break

            if resp.status_code in (401, 403):
                raise AuthenticationError(resp.status_code, _error_message(resp))

            if resp.status_code == 404:
                raise PromptNotFoundError(404, _error_message(resp))

            if resp.status_code == 429:
                retry_after = _retry_after(resp)
                # Honor retry-after if we still have attempts left.
                if attempt < self._max_retries:
                    time.sleep(retry_after if retry_after is not None else self._backoff_for(attempt))
                    continue
                raise RateLimitError(_error_message(resp), retry_after=retry_after)

            if 500 <= resp.status_code < 600:
                last_error = APIError(resp.status_code, _error_message(resp))
                if self._sleep_before_retry(attempt):
                    continue
                break

            # Any other status is unexpected and not retryable.
            raise APIError(resp.status_code, _error_message(resp))

        # Every attempt failed. Serve last-known-good if we have it.
        if cached is not None:
            return Prompt.from_payload(cached.payload, from_cache=True)

        raise ServiceUnavailableError(
            f"failed to fetch prompt '{slug}' and no cached copy is available"
        ) from last_error

    def _store_and_return(self, cache_key: str, resp: requests.Response) -> Prompt:
        try:
            payload = resp.json()
        except ValueError as exc:
            raise APIError(200, "response was not valid JSON") from exc

        entry = CacheEntry(
            payload=payload,
            etag=resp.headers.get("ETag"),
            immutable=_is_immutable(resp),
            stored_at=time.time(),
        )
        self._cache.set(cache_key, entry)
        return Prompt.from_payload(payload, from_cache=False)

    def _sleep_before_retry(self, attempt: int) -> bool:
        """Sleep and return ``True`` if another attempt remains."""
        if attempt < self._max_retries:
            time.sleep(self._backoff_for(attempt))
            return True
        return False

    def _backoff_for(self, attempt: int) -> float:
        return self._backoff * (2 ** attempt)

    # ── helpers ───────────────────────────────────────────────────────────────

    @staticmethod
    def _build_params(version: Optional[Union[int, str]], environment: Optional[str]) -> dict:
        if environment is not None:
            return {"environment": environment}
        if version is not None:
            return {"version": str(version)}
        return {}

    @staticmethod
    def _cache_key(slug: str, params: dict) -> str:
        if "environment" in params:
            return f"{slug}@env:{params['environment']}"
        if "version" in params:
            return f"{slug}@version:{params['version']}"
        return f"{slug}@latest"


def _is_immutable(resp: requests.Response) -> bool:
    return "immutable" in resp.headers.get("Cache-Control", "").lower()


def _retry_after(resp: requests.Response) -> Optional[int]:
    raw = resp.headers.get("Retry-After")
    if raw is None:
        return None
    try:
        return int(raw)
    except ValueError:
        return None


def _error_message(resp: requests.Response) -> str:
    try:
        body = resp.json()
    except ValueError:
        return resp.text or f"HTTP {resp.status_code}"
    if isinstance(body, dict) and "error" in body:
        return str(body["error"])
    return f"HTTP {resp.status_code}"
