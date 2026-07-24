"""Tests for the shared administration entity result contract."""

from uuid import UUID

import pytest

from src.onboarding.result_contract import (
    build_entity_result,
    build_onboarding_result,
    build_organization_result,
)


def test_standard_fields_are_always_present() -> None:
    result = build_entity_result(
        {},
        entity_type="asset",
        entity_id="asset-1",
    )

    assert result == {
        "success": True,
        "entity_type": "ASSET",
        "entity_id": "asset-1",
        "lifecycle_status": None,
        "commissioning_status": None,
        "validation_warnings": [],
        "blocking_conditions": [],
        "audit_transaction_id": None,
    }


def test_legacy_operation_details_are_preserved() -> None:
    result = build_entity_result(
        {
            "organization_id": "org-1",
            "site_id": "site-1",
            "asset_id": "asset-1",
        },
        entity_type="ASSET",
        entity_id="asset-1",
    )

    assert result["organization_id"] == "org-1"
    assert result["site_id"] == "site-1"
    assert result["asset_id"] == "asset-1"
    assert result["entity_id"] == "asset-1"


def test_onboarding_result_uses_asset_as_primary_entity() -> None:
    transaction_id = UUID("11111111-1111-1111-1111-111111111111")

    result = build_onboarding_result(
        {
            "organization_id": "org-1",
            "site_id": "site-1",
            "asset_id": "asset-1",
            "relationship_type": "PRIMARY_METER",
        },
        audit_transaction_id=transaction_id,
    )

    assert result["success"] is True
    assert result["entity_type"] == "ONBOARDING"
    assert result["entity_id"] == "asset-1"
    assert result["audit_transaction_id"] == str(transaction_id)
    assert result["relationship_type"] == "PRIMARY_METER"

def test_organization_result_uses_organization_as_primary_entity() -> None:
    result = build_organization_result(
        {
            "organization_id": "org-1",
            "organization_code": "ORG_1",
            "organization_name": "Organization One",
            "lifecycle_status": "ACTIVE",
            "audit_transaction_id": (
                "22222222-2222-4222-8222-222222222222"
            ),
        }
    )

    assert result["success"] is True
    assert result["entity_type"] == "ORGANIZATION"
    assert result["entity_id"] == "org-1"
    assert result["lifecycle_status"] == "ACTIVE"
    assert result["organization_code"] == "ORG_1"
    assert result["organization_name"] == "Organization One"
    assert result["audit_transaction_id"] == (
        "22222222-2222-4222-8222-222222222222"
    )

def test_warnings_and_blockers_are_normalized() -> None:
    result = build_entity_result(
        {},
        entity_type="DEVICE",
        validation_warnings=[" Missing location ", "", "Review profile"],
        blocking_conditions="Missing gateway",
    )

    assert result["validation_warnings"] == [
        "Missing location",
        "Review profile",
    ]
    assert result["blocking_conditions"] == ["Missing gateway"]


def test_contract_fields_override_legacy_values() -> None:
    result = build_entity_result(
        {
            "success": False,
            "entity_type": "WRONG",
            "entity_id": "wrong-id",
        },
        entity_type="SITE",
        entity_id="site-1",
        success=True,
    )

    assert result["success"] is True
    assert result["entity_type"] == "SITE"
    assert result["entity_id"] == "site-1"


def test_blank_entity_type_is_rejected() -> None:
    with pytest.raises(ValueError, match="entity_type is required"):
        build_entity_result({}, entity_type="   ")
