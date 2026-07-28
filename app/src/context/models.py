"""Immutable models for active administration context."""

from dataclasses import dataclass


CONTEXT_VERSION = 1
ALLOWED_ENTITY_TYPES = frozenset(
    {
        "ASSET",
        "GATEWAY",
        "DEVICE",
        "RELATIONSHIP",
    }
)


@dataclass(frozen=True, slots=True)
class AdministrationContext:
    """The tenant/location context selected for the current session."""

    active_organization_id: str | None = None
    active_organization_name: str | None = None
    active_organization_code: str | None = None
    active_site_id: str | None = None
    active_site_name: str | None = None
    active_site_code: str | None = None
    active_location_id: str | None = None
    active_location_name: str | None = None
    active_location_code: str | None = None
    active_location_type: str | None = None
    active_entity_type: str | None = None
    active_entity_id: str | None = None
    context_version: int = CONTEXT_VERSION
