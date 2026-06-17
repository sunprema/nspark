"""Typed views over the prompt-retrieval response.

The runtime endpoint returns JSON shaped like::

    {
      "slug": "support-agent",
      "version": 5,
      "resolved_via": "version:5",
      "prompt": "You are a support agent.\\nTask: {task}\\n",
      "input_schema": {
        "variables": {"task": {"required": true, "refs": ["node-1"]}},
        "outputs": ["resolution"],
        "provider": "anthropic"
      },
      "metadata": {...},
      "stats": {...}
    }

:class:`Prompt` wraps that payload and adds the one operation a calling app
actually performs: validate its variables against the contract, then substitute
them into the template (:meth:`Prompt.render`).
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any, Dict, List, Mapping, Optional, Set

from .exceptions import MissingVariablesError, UnknownVariablesError

# Mirrors the server-side var regex (Nspark.VersionDiff): a single-brace
# placeholder whose name starts with a letter/underscore. Keeping these in sync
# is what guarantees the SDK substitutes exactly what the compiler emitted.
_VAR_RE = re.compile(r"\{([a-zA-Z_]\w*)\}")


@dataclass(frozen=True)
class InputSchema:
    """The published input contract for a version.

    Every variable the compiled prompt references is listed in ``variables``
    and marked ``required`` by the server, so :attr:`required` is simply the
    full key set. ``outputs`` and ``provider`` are carried for introspection.
    """

    variables: Dict[str, Dict[str, Any]] = field(default_factory=dict)
    outputs: List[str] = field(default_factory=list)
    provider: Optional[str] = None

    @classmethod
    def from_dict(cls, data: Optional[Mapping[str, Any]]) -> "InputSchema":
        data = data or {}
        return cls(
            variables=dict(data.get("variables") or {}),
            outputs=list(data.get("outputs") or []),
            provider=data.get("provider"),
        )

    @property
    def required(self) -> Set[str]:
        """Names of variables that must be supplied before substitution."""
        return {
            name
            for name, spec in self.variables.items()
            if not isinstance(spec, Mapping) or spec.get("required", True)
        }

    @property
    def names(self) -> Set[str]:
        """All variable names the prompt declares."""
        return set(self.variables.keys())


@dataclass(frozen=True)
class Prompt:
    """A resolved, immutable prompt artifact for one slug + qualifier."""

    slug: str
    version: int
    resolved_via: str
    text: str
    input_schema: InputSchema
    metadata: Dict[str, Any] = field(default_factory=dict)
    stats: Dict[str, Any] = field(default_factory=dict)
    #: ``True`` when this copy was served from cache rather than a fresh fetch.
    #: A stale last-known-good copy returned during an outage also sets this.
    from_cache: bool = False

    @classmethod
    def from_payload(cls, payload: Mapping[str, Any], *, from_cache: bool = False) -> "Prompt":
        return cls(
            slug=payload["slug"],
            version=payload["version"],
            resolved_via=payload.get("resolved_via", ""),
            text=payload.get("prompt", ""),
            input_schema=InputSchema.from_dict(payload.get("input_schema")),
            metadata=dict(payload.get("metadata") or {}),
            stats=dict(payload.get("stats") or {}),
            from_cache=from_cache,
        )

    @property
    def required_variables(self) -> Set[str]:
        return self.input_schema.required

    def validate(self, variables: Mapping[str, Any], *, strict: bool = True) -> None:
        """Check ``variables`` against the contract without rendering.

        Raises :class:`MissingVariablesError` if a required variable is absent,
        and (when ``strict``) :class:`UnknownVariablesError` if a supplied
        variable is not declared by the prompt.
        """
        supplied = set(variables.keys())

        missing = self.required_variables - supplied
        if missing:
            raise MissingVariablesError(missing)

        if strict:
            unknown = supplied - self.input_schema.names
            if unknown:
                raise UnknownVariablesError(unknown)

    def render(self, variables: Optional[Mapping[str, Any]] = None, *, strict: bool = True) -> str:
        """Validate then substitute ``variables`` into the prompt template.

        Returns the final prompt string with every ``{name}`` placeholder
        replaced by ``str(value)``. Validation runs first, so a missing
        variable raises rather than leaking an unsubstituted ``{placeholder}``
        into a model call.
        """
        variables = dict(variables or {})
        self.validate(variables, strict=strict)

        def _sub(match: "re.Match[str]") -> str:
            name = match.group(1)
            if name in variables:
                return str(variables[name])
            # A declared-but-unsupplied name only reaches here when it wasn't
            # required (validate() already guarded the required set); leave the
            # literal placeholder intact rather than guessing.
            return match.group(0)

        return _VAR_RE.sub(_sub, self.text)
