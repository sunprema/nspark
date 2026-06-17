"""Caches backing the client's two delivery guarantees.

The client uses one cache for two jobs at once:

1. **Conditional revalidation.** A cached entry remembers its ``ETag`` and
   whether the server marked it ``immutable``. Immutable (pinned ``?version=N``)
   entries are served without a network call; moving aliases (``@latest`` /
   environment) are revalidated with ``If-None-Match`` and a ``304`` re-serves
   the cached body.
2. **Last-known-good fallback.** If a fetch fails (network error / 5xx) the
   client serves the most recent cached entry instead of raising — so the
   caller's critical path survives our outage.

:class:`InMemoryCache` is the default (fast, per-process). Wrap a
:class:`FileCache` around a directory for last-known-good that survives process
restarts.
"""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
import threading
import time
from dataclasses import dataclass
from typing import Any, Dict, Optional


@dataclass
class CacheEntry:
    """A stored response plus the metadata needed to revalidate it."""

    payload: Dict[str, Any]
    etag: Optional[str]
    #: ``True`` when the server marked this response immutable (pinned version).
    immutable: bool
    stored_at: float

    def to_json(self) -> Dict[str, Any]:
        return {
            "payload": self.payload,
            "etag": self.etag,
            "immutable": self.immutable,
            "stored_at": self.stored_at,
        }

    @classmethod
    def from_json(cls, data: Dict[str, Any]) -> "CacheEntry":
        return cls(
            payload=data["payload"],
            etag=data.get("etag"),
            immutable=bool(data.get("immutable", False)),
            stored_at=float(data.get("stored_at", time.time())),
        )


class Cache:
    """Cache interface. Implementations must be safe for concurrent use."""

    def get(self, key: str) -> Optional[CacheEntry]:  # pragma: no cover - interface
        raise NotImplementedError

    def set(self, key: str, entry: CacheEntry) -> None:  # pragma: no cover - interface
        raise NotImplementedError


class InMemoryCache(Cache):
    """Thread-safe in-process cache. Lost on restart."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._store: Dict[str, CacheEntry] = {}

    def get(self, key: str) -> Optional[CacheEntry]:
        with self._lock:
            return self._store.get(key)

    def set(self, key: str, entry: CacheEntry) -> None:
        with self._lock:
            self._store[key] = entry


class FileCache(Cache):
    """Durable last-known-good cache backed by a directory of JSON files.

    Each key is hashed to a filename and written atomically (write-temp-then-
    rename) so a crashed write can't leave a half-written entry. Use this when
    last-known-good must survive process restarts (the common production case
    for a critical-path dependency).
    """

    def __init__(self, directory: str) -> None:
        self._dir = directory
        self._lock = threading.Lock()
        os.makedirs(self._dir, exist_ok=True)

    def _path(self, key: str) -> str:
        digest = hashlib.sha256(key.encode("utf-8")).hexdigest()
        return os.path.join(self._dir, f"{digest}.json")

    def get(self, key: str) -> Optional[CacheEntry]:
        path = self._path(key)
        with self._lock:
            try:
                with open(path, "r", encoding="utf-8") as fh:
                    return CacheEntry.from_json(json.load(fh))
            except FileNotFoundError:
                return None
            except (json.JSONDecodeError, KeyError, ValueError):
                # A corrupt entry is treated as a cache miss, never an error.
                return None

    def set(self, key: str, entry: CacheEntry) -> None:
        path = self._path(key)
        with self._lock:
            fd, tmp = tempfile.mkstemp(dir=self._dir, suffix=".tmp")
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as fh:
                    json.dump(entry.to_json(), fh)
                os.replace(tmp, path)
            except BaseException:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
                raise
