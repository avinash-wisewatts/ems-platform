"""Signed-session serialization for active administration context."""

from typing import Any
from uuid import UUID

from src.context.models import (
    ALLOWED_ENTITY_TYPES,
    CONTEXT_VERSION,
    AdministrationContext,
)


SESSION_CONTEXT_KEY = "portal_admin_context"


def _normalize_optional_text(value: object, *, max_length: int = 200) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValueError("Context label must be a string.")
    normalized = value.strip()
    if not normalized or len(normalized) > max_length:
        raise ValueError("Context label is invalid.")
    return normalized


def _normalize_optional_uuid(value: object) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValueError("Context identifier must be a string.")
    return str(UUID(value))


def serialize_administration_context(
    context: AdministrationContext,
) -> dict[str, Any]:
    """Convert context into session-safe primitives."""

    return {
        "active_organization_id": context.active_organization_id,
        "active_organization_name": context.active_organization_name,
        "active_organization_code": context.active_organization_code,
        "active_site_id": context.active_site_id,
        "active_site_name": context.active_site_name,
        "active_site_code": context.active_site_code,
        "active_location_id": context.active_location_id,
        "active_location_name": context.active_location_name,
        "active_location_code": context.active_location_code,
        "active_location_type": context.active_location_type,
        "active_entity_type": context.active_entity_type,
        "active_entity_id": context.active_entity_id,
        "context_version": context.context_version,
    }


def deserialize_administration_context(
    payload: object,
) -> AdministrationContext | None:
    """Rebuild a valid context payload or fail closed."""

    if not isinstance(payload, dict):
        return None

    context_version = payload.get("context_version")
    if type(context_version) is not int or context_version != CONTEXT_VERSION:
        return None

    try:
        organization_id = _normalize_optional_uuid(
            payload.get("active_organization_id")
        )
        organization_name = _normalize_optional_text(
            payload.get("active_organization_name")
        )
        organization_code = _normalize_optional_text(
            payload.get("active_organization_code"),
            max_length=100,
        )
        site_id = _normalize_optional_uuid(payload.get("active_site_id"))
        site_name = _normalize_optional_text(
            payload.get("active_site_name")
        )
        site_code = _normalize_optional_text(
            payload.get("active_site_code"),
            max_length=100,
        )
        location_id = _normalize_optional_uuid(
            payload.get("active_location_id")
        )
        location_name = _normalize_optional_text(payload.get("active_location_name"))
        location_code = _normalize_optional_text(payload.get("active_location_code"), max_length=100)
        location_type = _normalize_optional_text(payload.get("active_location_type"), max_length=20)
        entity_id = _normalize_optional_uuid(
            payload.get("active_entity_id")
        )
    except ValueError:
        return None

    entity_type = payload.get("active_entity_type")
    if entity_type is not None:
        if not isinstance(entity_type, str):
            return None
        entity_type = entity_type.strip().upper()
        if entity_type not in ALLOWED_ENTITY_TYPES:
            return None

    if (entity_type is None) != (entity_id is None):
        return None

    # Child context is invalid without its required parent.
    if site_id is not None and organization_id is None:
        return None
    if location_id is not None and site_id is None:
        return None
    if entity_id is not None and organization_id is None:
        return None

    return AdministrationContext(
        active_organization_id=organization_id,
        active_organization_name=organization_name,
        active_organization_code=organization_code,
        active_site_id=site_id,
        active_site_name=site_name,
        active_site_code=site_code,
        active_location_id=location_id,
        active_location_name=location_name,
        active_location_code=location_code,
        active_location_type=location_type,
        active_entity_type=entity_type,
        active_entity_id=entity_id,
        context_version=context_version,
    )
