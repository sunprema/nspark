"""Newtonian Spark — Python client for runtime prompt delivery.

Fetch governed, versioned prompts from a Newtonian Spark service, with caching,
last-known-good fallback, and variable validation against the published input
contract.

    from nspark import Client

    client = Client("https://nspark.example.com", api_key="nsk_…")
    prompt = client.get_prompt("support-agent", version=5)
    text = prompt.render({"task": "Issue a refund"})
"""

from .cache import Cache, CacheEntry, FileCache, InMemoryCache
from .client import Client
from .exceptions import (
    APIError,
    AuthenticationError,
    MissingVariablesError,
    NsparkError,
    PromptNotFoundError,
    RateLimitError,
    ServiceUnavailableError,
    UnknownVariablesError,
    ValidationError,
)
from .models import InputSchema, Prompt

__version__ = "0.1.0"

__all__ = [
    "Client",
    "Prompt",
    "InputSchema",
    "Cache",
    "CacheEntry",
    "InMemoryCache",
    "FileCache",
    "NsparkError",
    "APIError",
    "AuthenticationError",
    "PromptNotFoundError",
    "RateLimitError",
    "ServiceUnavailableError",
    "ValidationError",
    "MissingVariablesError",
    "UnknownVariablesError",
    "__version__",
]
