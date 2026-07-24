"""Shared result contract for EMS administration write operations."""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Any
from uuid import UUID


@dataclass(frozen=True, slots=True)
class EntityResult:
    """Canonical result returned by controlled administration operations."""

    success: bool
    entity_type: str
    entity_id: str | None
    lifecycle_status: str | None
    commissioning_status: str | None
    validation_warnings: tuple[str, ...]
    blocking_conditions: tuple[str, ...]
    audit_transaction_id: str | None

    def as_dict(self) -> dict[str, Any]:
        return {
            "success": self.success,
            "entity_type": self.entity_type,
            "entity_id": self.entity_id,
            "lifecycle_status": self.lifecycle_status,
            "commissioning_status": self.commissioning_status,
            "validation_warnings": list(self.validation_warnings),
            "blocking_conditions": list(self.blocking_conditions),
            "audit_transaction_id": self.audit_transaction_id,
        }


def _optional_text(value: Any) -> str | None:
    if value is None:
        return None

    normalized = str(value).strip()
    return normalized or None


def _messages(value: Any) -> tuple[str, ...]:
    if value is None:
        return ()

    if isinstance(value, str):
        normalized = value.strip()
        return (normalized,) if normalized else ()

    if not isinstance(value, Sequence):
        raise ValueError("Result warnings and blockers must be sequences.")

    messages: list[str] = []

    for item in value:
        normalized = str(item).strip()
        if normalized:
            messages.append(normalized)

    return tuple(messages)


def build_entity_result(
    payload: Mapping[str, Any] | None,
    *,
    entity_type: str,
    entity_id: Any = None,
    lifecycle_status: Any = None,
    commissioning_status: Any = None,
    validation_warnings: Any = None,
    blocking_conditions: Any = None,
    audit_transaction_id: UUID | str | None = None,
    success: bool = True,
) -> dict[str, Any]:
    """
    Add the canonical result fields while preserving legacy operation details.

    Existing wizard templates may continue reading identifiers such as
    ``organization_id`` or ``asset_id``. New administration workflows can rely
    on the standard fields returned for every operation.
    """

    normalized_entity_type = str(entity_type).strip().upper()
    if not normalized_entity_type:
        raise ValueError("entity_type is required.")

    details = dict(payload or {})

    contract = EntityResult(
        success=bool(success),
        entity_type=normalized_entity_type,
        entity_id=_optional_text(
            entity_id if entity_id is not None else details.get("entity_id")
        ),
        lifecycle_status=_optional_text(
            lifecycle_status
            if lifecycle_status is not None
            else details.get("lifecycle_status")
        ),
        commissioning_status=_optional_text(
            commissioning_status
            if commissioning_status is not None
            else details.get("commissioning_status")
        ),
        validation_warnings=_messages(
            validation_warnings
            if validation_warnings is not None
            else details.get("validation_warnings")
        ),
        blocking_conditions=_messages(
            blocking_conditions
            if blocking_conditions is not None
            else details.get("blocking_conditions")
        ),
        audit_transaction_id=_optional_text(
            audit_transaction_id
            if audit_transaction_id is not None
            else details.get("audit_transaction_id")
        ),
    )

    # Canonical fields intentionally override same-named legacy values.
    details.update(contract.as_dict())
    return details


def build_onboarding_result(
    payload: Mapping[str, Any],
    *,
    audit_transaction_id: UUID | str | None = None,
) -> dict[str, Any]:
    """Adapt the existing onboarding response to the shared entity contract."""

    return build_entity_result(
        payload,
        entity_type="ONBOARDING",
        entity_id=payload.get("asset_id"),
        lifecycle_status=payload.get("asset_lifecycle_status"),
        commissioning_status=payload.get("commissioning_status"),
        audit_transaction_id=audit_transaction_id,
    )

def build_organization_result(
    payload: Mapping[str, Any],
) -> dict[str, Any]:
    """Normalize an independent organization-creation response."""

    return build_entity_result(
        payload,
        entity_type="ORGANIZATION",
        entity_id=payload.get("organization_id"),
        lifecycle_status=payload.get("lifecycle_status"),
        audit_transaction_id=payload.get("audit_transaction_id"),
    )
