"""Exception hierarchy for the Newtonian Spark client.

All errors raised by the SDK derive from :class:`NsparkError`, so callers can
catch the whole family with one ``except``. The split below mirrors the failure
modes of the runtime delivery API:

* auth / not-found / rate-limit / generic API errors map to HTTP responses
* :class:`ServiceUnavailableError` is raised only when the service is
  unreachable **and** there is no last-known-good copy to fall back to
* the :class:`ValidationError` family is raised locally, before substitution,
  when supplied variables don't satisfy a version's published input contract
"""

from __future__ import annotations

from typing import List, Optional, Sequence


class NsparkError(Exception):
    """Base class for every error raised by the SDK."""


class APIError(NsparkError):
    """An unexpected, non-success HTTP response from the API."""

    def __init__(self, status_code: int, message: str) -> None:
        self.status_code = status_code
        self.message = message
        super().__init__(f"[{status_code}] {message}")


class AuthenticationError(APIError):
    """The API key was missing, invalid, revoked, or expired (HTTP 401/403)."""


class PromptNotFoundError(APIError):
    """No prompt matched the slug, or no version matched the qualifier (HTTP 404)."""


class RateLimitError(APIError):
    """The per-principal rate limit was exceeded (HTTP 429).

    ``retry_after`` carries the server's ``retry-after`` hint in seconds when
    present.
    """

    def __init__(self, message: str, retry_after: Optional[int] = None) -> None:
        self.retry_after = retry_after
        super().__init__(429, message)


class ServiceUnavailableError(NsparkError):
    """The service could not be reached and no cached fallback was available.

    This is the error a critical-path caller must guard against. When a
    last-known-good copy exists in the cache the SDK returns it instead of
    raising, so seeing this means *both* the live fetch failed and the cache
    was cold.
    """


class ValidationError(NsparkError):
    """Supplied variables do not satisfy the version's published input contract."""


class MissingVariablesError(ValidationError):
    """One or more required variables were not supplied for substitution."""

    def __init__(self, missing: Sequence[str]) -> None:
        self.missing: List[str] = list(missing)
        names = ", ".join(sorted(self.missing))
        super().__init__(f"missing required variable(s): {names}")


class UnknownVariablesError(ValidationError):
    """Variables were supplied that the prompt does not declare (likely a typo).

    Raised only in ``strict`` rendering; lenient rendering ignores extras.
    """

    def __init__(self, unknown: Sequence[str]) -> None:
        self.unknown: List[str] = list(unknown)
        names = ", ".join(sorted(self.unknown))
        super().__init__(f"unknown variable(s) not in prompt contract: {names}")
