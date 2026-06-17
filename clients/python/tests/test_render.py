"""Variable validation + substitution (no network)."""

import pytest

from nspark import MissingVariablesError, Prompt, UnknownVariablesError


def make_prompt(text, variables):
    return Prompt.from_payload(
        {
            "slug": "demo",
            "version": 1,
            "resolved_via": "version:1",
            "prompt": text,
            "input_schema": {"variables": variables, "outputs": [], "provider": "anthropic"},
            "metadata": {},
            "stats": {},
        }
    )


def test_render_substitutes_declared_variables():
    p = make_prompt(
        "Hello {name}, your task is {task}.",
        {"name": {"required": True, "refs": ["n1"]}, "task": {"required": True, "refs": ["n1"]}},
    )
    assert p.render({"name": "Ada", "task": "refund"}) == "Hello Ada, your task is refund."


def test_render_coerces_non_string_values():
    p = make_prompt("Count: {n}", {"n": {"required": True, "refs": ["n1"]}})
    assert p.render({"n": 42}) == "Count: 42"


def test_render_raises_on_missing_required_variable():
    p = make_prompt(
        "Hi {name} re {task}",
        {"name": {"required": True, "refs": ["n1"]}, "task": {"required": True, "refs": ["n1"]}},
    )
    with pytest.raises(MissingVariablesError) as exc:
        p.render({"name": "Ada"})
    assert exc.value.missing == ["task"]


def test_strict_render_rejects_unknown_variables():
    p = make_prompt("Hi {name}", {"name": {"required": True, "refs": ["n1"]}})
    with pytest.raises(UnknownVariablesError) as exc:
        p.render({"name": "Ada", "typo": "x"})
    assert exc.value.unknown == ["typo"]


def test_lenient_render_ignores_unknown_variables():
    p = make_prompt("Hi {name}", {"name": {"required": True, "refs": ["n1"]}})
    assert p.render({"name": "Ada", "extra": "x"}, strict=False) == "Hi Ada"


def test_required_variables_property():
    p = make_prompt(
        "{a}{b}",
        {"a": {"required": True, "refs": ["n1"]}, "b": {"required": True, "refs": ["n1"]}},
    )
    assert p.required_variables == {"a", "b"}
