"""Validation for the Asset Data Point Assignment Save flow (ADR-018 Amendments 5-8).

Mirrors src/relationship_management.py's shape: a thin, framework-free
validation layer that normalizes/sanity-checks the submitted form into the
shape admin.save_asset_point_assignments() expects, without duplicating any
business rule the database function itself already enforces (device
association, enabled/configured points, measurement-group conflicts,
lifecycle gating). Those remain the database's sole responsibility.
"""

from uuid import UUID


class AssetPointAssignmentValidationError(ValueError):
    """Invalid asset point assignment submission (structural only)."""


def _uuid(value: str, label: str) -> str:
    try:
        return str(UUID(value.strip()))
    except (ValueError, AttributeError) as exc:
        raise AssetPointAssignmentValidationError(f"{label} is required.") from exc


def validate_asset_point_assignment_submission(
    *,
    asset_id: str,
    device_id: str,
    checked_logical_point_ids: list[str],
    friendly_names: dict[str, str],
) -> dict[str, object]:
    """Normalize a submitted checkbox+friendly-name form into the Save payload.

    ``checked_logical_point_ids`` is the raw ``logical_point_id`` checkbox
    values (``form.getlist(...)``, same convention as the existing device
    telemetry-point checkbox list). ``friendly_names`` maps a raw
    logical_point_id string to its submitted friendly-name text field.
    A malformed identifier raises; a duplicate checked value (not possible
    from the rendered form, only from a tampered request) is silently
    deduplicated rather than treated as an error -- the database's own
    duplicate check remains the authoritative guard.
    """
    confirmed_points: list[dict[str, str | None]] = []
    seen: set[str] = set()
    for raw_id in checked_logical_point_ids:
        point_id = _uuid(raw_id, "Data point")
        if point_id in seen:
            continue
        seen.add(point_id)
        friendly_name = (friendly_names.get(raw_id) or "").strip()
        confirmed_points.append(
            {"logical_point_id": point_id, "friendly_name": friendly_name or None}
        )

    return {
        "asset_id": _uuid(asset_id, "Asset"),
        "device_id": _uuid(device_id, "Device"),
        "confirmed_points": confirmed_points,
    }
