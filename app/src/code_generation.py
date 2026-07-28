"""Shared internal entity-code generation.

The browser may preview a code, but this module is authoritative for every
create route. Existing codes are intentionally never regenerated on edit.
"""
from __future__ import annotations

import re
import unicodedata

_MAX_CODE_LENGTH = 100
_NON_CODE = re.compile(r"[^A-Z0-9]+")
_REPEATED_SEPARATOR = re.compile(r"_+")


def generate_entity_code(name: str, *, max_length: int = _MAX_CODE_LENGTH) -> str:
    """Return the current EMS uppercase underscore code format for a name."""
    normalized = unicodedata.normalize("NFKD", name or "")
    ascii_value = normalized.encode("ascii", "ignore").decode("ascii")
    code = _NON_CODE.sub("_", ascii_value.strip().upper())
    code = _REPEATED_SEPARATOR.sub("_", code).strip("_")
    code = code[:max_length].rstrip("_")
    return code
