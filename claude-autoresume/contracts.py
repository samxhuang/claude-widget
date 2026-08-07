"""Machine-checkable validation of the five cross-language on-disk formats.

The widget (Swift) and the daemon (Python) exchange five files under
``~/.claude-autoresume``.  Until now their schemas existed only as prose in
CLAUDE.md plus matching hand-written readers and writers, so nothing detected
drift — you found out when a field silently read as ``nil`` in the UI.  The
JSON Schemas in ``docs/contracts/*.schema.json`` are the machine-readable
version of that prose; this module validates against them.

Usage
-----
    import contracts
    errors = contracts.validate("state", json.loads(text))
    if errors:
        ...

``validate`` returns a list of human-readable strings (empty == valid), never
raises for a malformed *instance*.  It DOES raise for an unknown schema name
or an unusable schema file — those are programming errors, not data errors.

Registered names::

    state              ~/.claude-autoresume/state.json
    state.entry        one entry out of it
    config             ~/.claude-autoresume/config.json
    plan_fit           ~/.claude-autoresume/usage/plan_fit.json
    snapshots          one line of any usage/snapshots*.jsonl
    snapshots.raw      one line of snapshots.jsonl specifically
    snapshots.bucket   one line of snapshots_15m.jsonl / snapshots_1h.jsonl
    scoped_limits      ~/.claude-autoresume/usage/scoped_limits.json

Why a hand-rolled validator
---------------------------
The daemon is hard-constrained to pure stdlib (it runs under the system
``python3`` via launchd, and the same payload is deployed to remote SSH boxes
that only have system python3).  ``jsonschema`` is not available and adding it
would break that constraint.  So this implements the SUBSET of JSON Schema
draft 2020-12 the schemas in ``docs/contracts`` actually use:

    type (incl. type unions), enum, const,
    properties, required, additionalProperties (bool or schema),
    propertyNames, dependentRequired,
    items, minItems,
    oneOf, anyOf, allOf, not,
    $ref (local ``#/$defs/...`` pointers only),
    minimum, maximum, exclusiveMinimum, exclusiveMaximum,
    minLength, maxLength, pattern

Anything else in a schema is IGNORED rather than silently mis-enforced, and
``schema_keywords_used`` exists so a test can assert no schema has quietly
started relying on a keyword this validator does not implement.

This module is deliberately NOT wired into the daemon's poll loop — validating
a 2 MB plan_fit.json every hour buys nothing at runtime.  It is a test-time
and diagnostic tool.  It is also not imported by anything the daemon imports,
so it never has to be part of the deploy payload.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Schema registry
# ---------------------------------------------------------------------------

CONTRACTS_DIR = Path(__file__).resolve().parent.parent / "docs" / "contracts"

# name -> (schema filename, JSON pointer into that file; "" = document root)
_REGISTRY: dict[str, tuple[str, str]] = {
    "state": ("state.schema.json", ""),
    "state.entry": ("state.schema.json", "/$defs/entry"),
    "config": ("config.schema.json", ""),
    "config.remote_host": ("config.schema.json", "/$defs/remoteHost"),
    "plan_fit": ("plan_fit.schema.json", ""),
    "snapshots": ("snapshots.schema.json", ""),
    "snapshots.raw": ("snapshots.schema.json", "/$defs/rawRow"),
    "snapshots.bucket": ("snapshots.schema.json", "/$defs/bucketRow"),
    "scoped_limits": ("scoped_limits.schema.json", ""),
}

# Every keyword this validator actually enforces.  `schema_keywords_used`
# compares real schemas against this so an unimplemented keyword can't be
# added to a schema and silently do nothing.
SUPPORTED_KEYWORDS = frozenset({
    "type", "enum", "const",
    "properties", "required", "additionalProperties",
    "propertyNames", "dependentRequired",
    "items", "minItems", "maxItems",
    "oneOf", "anyOf", "allOf", "not",
    "$ref",
    "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum",
    "minLength", "maxLength", "pattern",
})

# Keywords that carry no validation meaning; present for documentation or for
# JSON Schema plumbing.  Ignored without complaint.
ANNOTATION_KEYWORDS = frozenset({
    "$schema", "$id", "$defs", "$comment",
    "title", "description", "default", "examples", "deprecated",
})

_schema_cache: dict[str, dict] = {}


def _load_schema_file(filename: str) -> dict:
    cached = _schema_cache.get(filename)
    if cached is not None:
        return cached
    path = CONTRACTS_DIR / filename
    try:
        doc = json.loads(path.read_text())
    except OSError as e:
        raise RuntimeError(f"contract schema {path} is unreadable: {e}") from e
    except ValueError as e:
        raise RuntimeError(f"contract schema {path} is not valid JSON: {e}") from e
    if not isinstance(doc, dict):
        raise RuntimeError(f"contract schema {path} is not a JSON object")
    _schema_cache[filename] = doc
    return doc


def _resolve_pointer(doc: dict, pointer: str) -> dict:
    """Minimal RFC 6901 JSON pointer resolution (the subset our $refs use)."""
    node: Any = doc
    if not pointer:
        return node
    for token in pointer.lstrip("/").split("/"):
        token = token.replace("~1", "/").replace("~0", "~")
        if not isinstance(node, dict) or token not in node:
            raise RuntimeError(f"contract schema pointer {pointer!r} does not resolve")
        node = node[token]
    if not isinstance(node, dict):
        raise RuntimeError(f"contract schema pointer {pointer!r} is not an object")
    return node


def schema_names() -> list[str]:
    """Every name `validate` accepts, sorted."""
    return sorted(_REGISTRY)


def load(name: str) -> tuple[dict, dict]:
    """(subschema, root document) for a registered contract name."""
    try:
        filename, pointer = _REGISTRY[name]
    except KeyError:
        raise KeyError(
            f"unknown contract {name!r}; known: {', '.join(schema_names())}"
        ) from None
    doc = _load_schema_file(filename)
    return _resolve_pointer(doc, pointer), doc


def schema_keywords_used(name: str) -> set[str]:
    """Every JSON Schema keyword appearing anywhere in `name`'s schema DOCUMENT
    (not just the pointed-at subschema), excluding pure annotations and the
    project's own ``x-`` metadata.  A test asserts this stays inside
    SUPPORTED_KEYWORDS, so a schema can never quietly depend on a keyword this
    validator ignores."""
    _, doc = load(name)
    found: set[str] = set()

    def walk(node: Any, in_schema: bool) -> None:
        if isinstance(node, dict):
            for key, val in node.items():
                if not in_schema:
                    # A value position (e.g. inside "properties"): the keys are
                    # property names, not keywords; their values are schemas.
                    walk(val, True)
                    continue
                if key.startswith("x-") or key in ANNOTATION_KEYWORDS:
                    if key == "$defs":
                        walk(val, False)
                    continue
                found.add(key)
                if key in ("properties", "patternProperties", "dependentRequired"):
                    walk(val, False)
                elif key in ("oneOf", "anyOf", "allOf"):
                    for item in val if isinstance(val, list) else []:
                        walk(item, True)
                elif key in ("required", "enum", "const", "type", "pattern"):
                    pass
                else:
                    walk(val, True)
        elif isinstance(node, list):
            for item in node:
                walk(item, True)

    walk(doc, True)
    # "dependentRequired" values are arrays of property names, not schemas;
    # walking them as value positions above is harmless but can't add keywords.
    return found


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

_TYPE_CHECKS = {
    "object": lambda v: isinstance(v, dict),
    "array": lambda v: isinstance(v, list),
    "string": lambda v: isinstance(v, str),
    "boolean": lambda v: isinstance(v, bool),
    "null": lambda v: v is None,
    # JSON has one number type; bools are ints in Python and must NOT count.
    "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
    "integer": lambda v: (
        (isinstance(v, int) and not isinstance(v, bool))
        or (isinstance(v, float) and v.is_integer())
    ),
}


def _type_name(value: Any) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, str):
        return "string"
    if isinstance(value, (int, float)):
        return "number"
    if isinstance(value, list):
        return "array"
    if isinstance(value, dict):
        return "object"
    return type(value).__name__


def _brief(value: Any, limit: int = 60) -> str:
    """A short, non-leaking rendering of an offending value for an error
    message.  Long strings are truncated and containers are summarised rather
    than dumped — these files carry the owner's real session titles and project
    paths, and error text can end up in logs."""
    if isinstance(value, dict):
        return f"object with {len(value)} key(s)"
    if isinstance(value, list):
        return f"array of {len(value)}"
    if isinstance(value, str):
        return repr(value if len(value) <= limit else value[:limit] + "...")
    return repr(value)


class _Ctx:
    """Carries the schema document (for $ref resolution) and the error list."""

    __slots__ = ("doc", "errors")

    def __init__(self, doc: dict):
        self.doc = doc
        self.errors: list[str] = []

    def add(self, path: str, message: str) -> None:
        self.errors.append(f"{path or '<root>'}: {message}")


def _child(path: str, token: Any) -> str:
    if isinstance(token, int):
        return f"{path}[{token}]"
    return f"{path}.{token}" if path else str(token)


def _check(ctx: _Ctx, schema: Any, value: Any, path: str) -> None:
    # A boolean schema: true accepts anything, false rejects everything.
    if schema is True:
        return
    if schema is False:
        ctx.add(path, "schema forbids any value here")
        return
    if not isinstance(schema, dict):
        return

    if "$ref" in schema:
        ref = schema["$ref"]
        if not isinstance(ref, str) or not ref.startswith("#"):
            raise RuntimeError(f"unsupported $ref {ref!r} (local pointers only)")
        target = _resolve_pointer(ctx.doc, ref[1:])
        _check(ctx, target, value, path)
        # draft 2020-12 lets $ref sit alongside other keywords; fall through.

    # -- type --------------------------------------------------------------
    if "type" in schema:
        expected = schema["type"]
        names = expected if isinstance(expected, list) else [expected]
        if not any(_TYPE_CHECKS.get(n, lambda _v: True)(value) for n in names):
            ctx.add(path, f"expected type {'|'.join(names)}, got {_type_name(value)}")
            # Type is wrong; further keyword checks would only add noise.
            return

    # -- enum / const ------------------------------------------------------
    if "enum" in schema:
        options = schema["enum"]
        # `1 == True` in Python; compare type-exactly so a bool can't satisfy
        # a numeric enum (or vice versa).
        if not any(_same_json_value(value, o) for o in options):
            ctx.add(path, f"value {_brief(value)} is not one of the allowed values")
    if "const" in schema and not _same_json_value(value, schema["const"]):
        ctx.add(path, f"value {_brief(value)} does not equal the required constant")

    # -- combinators -------------------------------------------------------
    if "allOf" in schema:
        for sub in schema["allOf"]:
            _check(ctx, sub, value, path)
    if "anyOf" in schema:
        if not any(_matches(ctx.doc, sub, value) for sub in schema["anyOf"]):
            ctx.add(path, "value does not match any of the permitted shapes (anyOf)")
    if "oneOf" in schema:
        matched = [i for i, sub in enumerate(schema["oneOf"])
                   if _matches(ctx.doc, sub, value)]
        if len(matched) == 0:
            ctx.add(path, "value does not match any of the permitted shapes (oneOf)")
        elif len(matched) > 1:
            ctx.add(path, f"value ambiguously matches {len(matched)} oneOf shapes")
    if "not" in schema and _matches(ctx.doc, schema["not"], value):
        ctx.add(path, "value matches a forbidden shape (not)")

    # -- numbers -----------------------------------------------------------
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            ctx.add(path, f"{value!r} is below the minimum {schema['minimum']!r}")
        if "maximum" in schema and value > schema["maximum"]:
            ctx.add(path, f"{value!r} is above the maximum {schema['maximum']!r}")
        if "exclusiveMinimum" in schema and value <= schema["exclusiveMinimum"]:
            ctx.add(path, f"{value!r} must be greater than {schema['exclusiveMinimum']!r}")
        if "exclusiveMaximum" in schema and value >= schema["exclusiveMaximum"]:
            ctx.add(path, f"{value!r} must be less than {schema['exclusiveMaximum']!r}")

    # -- strings -----------------------------------------------------------
    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            ctx.add(path, f"string is shorter than minLength {schema['minLength']}")
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            ctx.add(path, f"string is longer than maxLength {schema['maxLength']}")
        pattern = schema.get("pattern")
        if isinstance(pattern, str) and re.search(pattern, value) is None:
            ctx.add(path, f"string does not match pattern {pattern!r}")

    # -- arrays ------------------------------------------------------------
    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            ctx.add(path, f"array has {len(value)} item(s), minimum {schema['minItems']}")
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            ctx.add(path, f"array has {len(value)} item(s), maximum {schema['maxItems']}")
        if "items" in schema:
            for i, item in enumerate(value):
                _check(ctx, schema["items"], item, _child(path, i))

    # -- objects -----------------------------------------------------------
    if isinstance(value, dict):
        props = schema.get("properties") or {}
        for key in schema.get("required") or []:
            if key not in value:
                ctx.add(path, f"missing required property {key!r}")
        prop_names_schema = schema.get("propertyNames")
        additional = schema.get("additionalProperties", True)
        for key, sub_value in value.items():
            if prop_names_schema is not None:
                _check(ctx, prop_names_schema, key, _child(path, key) + " (name)")
            if key in props:
                _check(ctx, props[key], sub_value, _child(path, key))
            elif additional is False:
                ctx.add(path, f"unexpected property {key!r} (additionalProperties is false)")
            elif additional is not True:
                _check(ctx, additional, sub_value, _child(path, key))
        for trigger, needed in (schema.get("dependentRequired") or {}).items():
            if trigger in value:
                for key in needed:
                    if key not in value:
                        ctx.add(path, f"property {key!r} is required when {trigger!r} is present")


def _same_json_value(a: Any, b: Any) -> bool:
    """Equality that does not let Python's ``True == 1`` blur a boolean into a
    number (JSON Schema treats them as distinct types)."""
    if isinstance(a, bool) != isinstance(b, bool):
        return False
    return a == b


def _matches(doc: dict, schema: Any, value: Any) -> bool:
    probe = _Ctx(doc)
    _check(probe, schema, value, "")
    return not probe.errors


def validate(name: str, obj: Any) -> list[str]:
    """Validate `obj` against the registered contract `name`.

    Returns a list of human-readable error strings; empty means valid.  Never
    raises on bad *data* — only on an unknown contract name or an unusable
    schema file, both of which are bugs rather than drift.
    """
    schema, doc = load(name)
    ctx = _Ctx(doc)
    _check(ctx, schema, obj, "")
    return ctx.errors


def validate_jsonl(name: str, text: str) -> list[str]:
    """Validate every non-blank line of a JSON Lines blob against `name`.

    Errors are prefixed with the 1-based line number.  A line that is not
    parseable JSON is reported rather than skipped — the compactor tolerates
    and counts malformed lines at runtime, but a writer producing them is
    drift.
    """
    errors: list[str] = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except ValueError as e:
            errors.append(f"line {lineno}: not valid JSON ({e})")
            continue
        errors.extend(f"line {lineno}: {err}" for err in validate(name, row))
    return errors


# ---------------------------------------------------------------------------
# CLI — `python3 contracts.py <name> <file>`, or --list
# ---------------------------------------------------------------------------

def main(argv: list[str]) -> int:
    if len(argv) == 1 or argv[1] in ("-h", "--help"):
        print(__doc__)
        return 0
    if argv[1] == "--list":
        for name in schema_names():
            print(name)
        return 0
    if len(argv) != 3:
        print("usage: contracts.py <contract-name> <path>   (or --list)")
        return 2
    name, path = argv[1], Path(argv[2])
    try:
        text = path.read_text()
    except OSError as e:
        print(f"cannot read {path}: {e}")
        return 2
    if name.startswith("snapshots") and path.suffix == ".jsonl":
        errors = validate_jsonl(name, text)
    else:
        try:
            errors = validate(name, json.loads(text))
        except ValueError as e:
            print(f"{path} is not valid JSON: {e}")
            return 1
    if errors:
        print(f"{path}: {len(errors)} contract violation(s) against {name!r}")
        for err in errors[:200]:
            print(f"  {err}")
        if len(errors) > 200:
            print(f"  ... and {len(errors) - 200} more")
        return 1
    print(f"{path}: OK against {name!r}")
    return 0


if __name__ == "__main__":  # pragma: no cover
    import sys
    raise SystemExit(main(sys.argv))
