"""Translate database failures into safe, actionable portal messages."""

from __future__ import annotations

from typing import Any


_OWNERSHIP_MESSAGES: tuple[tuple[str, str], ...] = (
    (
        "building organization",
        "The selected building and site belong to different organizations.",
    ),
    (
        "floor organization",
        "The selected floor and building belong to different organizations.",
    ),
    (
        "space organization",
        "The selected space and floor belong to different organizations.",
    ),
    (
        "asset organization",
        "The selected asset and site belong to different organizations.",
    ),
    (
        "asset location",
        "The selected asset location does not belong to the asset's organization and site.",
    ),
    (
        "parent asset",
        "The selected parent asset must belong to the same organization and site.",
    ),
    (
        "gateway organization",
        "The selected gateway and site belong to different organizations.",
    ),
    (
        "gateway location",
        "The selected gateway location does not belong to the gateway's organization and site.",
    ),
    (
        "device organization",
        "The selected device and gateway belong to different organizations.",
    ),
    (
        "must belong to the same organization and site",
        "The selected asset and device must belong to the same organization and site.",
    ),
)


def _primary_message(exc: BaseException) -> str | None:
    """Return PostgreSQL's primary message without depending on a concrete driver type."""

    diag: Any = getattr(exc, "diag", None)
    message = getattr(diag, "message_primary", None)
    if isinstance(message, str) and message.strip():
        return message.strip()
    return None


def user_facing_database_error(
    exc: BaseException,
    *,
    fallback: str,
) -> str:
    """Return a safe portal message for a database exception.

    Known tenant/site ownership failures are normalized into stable, actionable
    wording. Unknown database failures use the supplied workflow-specific
    fallback so SQL details, identifiers, and implementation internals are not
    exposed to portal users.
    """

    primary_message = _primary_message(exc)
    if primary_message is None:
        return fallback

    normalized = primary_message.casefold()
    for fragment, user_message in _OWNERSHIP_MESSAGES:
        if fragment in normalized:
            return user_message

    return fallback
