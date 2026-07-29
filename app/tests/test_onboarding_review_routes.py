"""Route tests for Review, final submission, and immutable result pages.

Repository reads, atomic submission, and audit writes are replaced with
deterministic test doubles. No production database pool is opened.
"""

from uuid import UUID

import pytest
from psycopg.errors import DatabaseError

from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult


DRAFT_TOKEN = UUID("13571357-2468-4246-8246-135713571357")

ORGANIZATION_ID = UUID("11111111-aaaa-4111-8111-111111111111")
SITE_ID = UUID("22222222-bbbb-4222-8222-222222222222")
SPACE_ID = UUID("33333333-cccc-4333-8333-333333333333")
GATEWAY_ID = UUID("44444444-dddd-4444-8444-444444444444")
DEVICE_ID = UUID("55555555-eeee-4555-8555-555555555555")
CATEGORY_ID = UUID("66666666-ffff-4666-8666-666666666666")
ASSET_ID = UUID("77777777-aaaa-4777-8777-777777777777")
ASSET_TYPE_ID = UUID("88888888-bbbb-4888-8888-888888888888")


def successful_result() -> AuthenticationResult:
    return AuthenticationResult(
        authenticated=True,
        user=AuthenticatedPortalUser(
            portal_user_id=306,
            username="review.operator@example.com",
            display_name="Review Test Operator",
            role_code="OPERATOR",
            organization_id=(
                "11111111-1111-1111-1111-111111111111"
            ),
            access_scope_mode="ORGANIZATION",
            site_ids=(),
        ),
        status=AuthenticationStatus.AUTHENTICATED,
    )


def login_operator(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def fake_authenticate(
        username: str,
        password: str,
    ) -> AuthenticationResult:
        return successful_result()

    monkeypatch.setattr(
        "src.main.authenticate_portal_user",
        fake_authenticate,
    )

    response = portal_client.post(
        "/login",
        data={
            "username": "review.operator@example.com",
            "password": "valid-password",
            "next_path": "/onboarding/review",
        },
    )

    assert response.status_code == 303


def new_records_draft(
    *,
    location_mode: str = "SITE_ONLY",
) -> dict:
    location = {
        "mode": "SITE_ONLY",
        "existing_space_id": None,
    }

    if location_mode == "CREATE_LOCATION":
        location = {
            "mode": "CREATE_LOCATION",
            "existing_space_id": None,
            "building_name": "Main Building",
            "building_code": "MAIN_BUILDING",
            "floor_name": "Basement",
            "floor_code": "BASEMENT",
            "space_name": "Chiller Plant Room",
            "space_code": "CHILLER_PLANT_ROOM",
        }

    return {
        "draft_token": DRAFT_TOKEN,
        "payload": {
            "organization": {
                "mode": "CREATE_NEW",
                "name": "WiseWatts Demo Organization",
                "code": "WISEWATTS_DEMO",
                "description": "Review route test",
            },
            "site": {
                "mode": "CREATE_NEW",
                "name": "Demo Hotel",
                "code": "DEMO_HOTEL",
                "timezone": "Asia/Kolkata",
                "address": {},
            },
            "location": location,
            "gateway": {
                "mode": "CREATE_NEW",
                "name": "Chiller Gateway",
                "external_id": "CHILLER_GATEWAY",
                "vendor": "Eniscope",
                "model": "Eniscope Gateway",
                "protocol": "MQTT",
            },
            "device": {
                "mode": "CREATE_NEW",
                "name": "Chiller Energy Meter",
                "external_id": "CHILLER_ENERGY_METER",
                "device_category_id": str(CATEGORY_ID),
                "model_vendor": "Eniscope",
                "model": "Eniscope Energy Meter",
                "protocol": "MQTT",
                "profile_code": "ENISCOPE_V4",
                "firmware_version": "4.2",
                "identifier": {
                    "type": "MQTT_UID",
                    "value": "80:34:28:16:09:eb:00:01",
                },
            },
            "asset": {
                "mode": "CREATE_NEW",
                "name": "Chiller 1",
                "asset_type_id": str(ASSET_TYPE_ID),
                "metering_requirement": "DIRECT_METER_REQUIRED",
                "relationship_type": "PRIMARY_METER",
                "metadata": {},
            },
        },
    }


def existing_records_draft() -> dict:
    return {
        "draft_token": DRAFT_TOKEN,
        "payload": {
            "organization": {
                "mode": "USE_EXISTING",
                "existing_organization_id": str(ORGANIZATION_ID),
            },
            "site": {
                "mode": "USE_EXISTING",
                "existing_site_id": str(SITE_ID),
            },
            "location": {
                "mode": "USE_EXISTING_SPACE",
                "existing_space_id": str(SPACE_ID),
            },
            "gateway": {
                "mode": "USE_EXISTING",
                "existing_gateway_id": str(GATEWAY_ID),
            },
            "device": {
                "mode": "USE_EXISTING",
                "existing_device_id": str(DEVICE_ID),
            },
            "asset": {
                "mode": "USE_EXISTING",
                "existing_asset_id": str(ASSET_ID),
                "relationship_type": "SECONDARY_METER",
                "metadata": {},
            },
        },
    }


def install_visible_draft(
    monkeypatch: pytest.MonkeyPatch,
    draft_record: dict | None,
) -> None:
    async def fake_get_visible_draft(
        request,
        draft_token: UUID,
    ) -> dict | None:
        assert draft_token == DRAFT_TOKEN
        return draft_record

    monkeypatch.setattr(
        "src.main.get_visible_onboarding_draft",
        fake_get_visible_draft,
    )


def install_submitted_result(
    monkeypatch: pytest.MonkeyPatch,
    record: dict | None,
) -> None:
    async def fake_get_visible_result(
        request,
        draft_token: UUID,
    ) -> dict | None:
        assert draft_token == DRAFT_TOKEN
        return record

    monkeypatch.setattr(
        "src.main.get_visible_submitted_onboarding_result",
        fake_get_visible_result,
    )


def install_review_catalogs(
    monkeypatch: pytest.MonkeyPatch,
    *,
    include_existing: bool = True,
) -> None:
    async def fake_list_organizations() -> list[dict]:
        if not include_existing:
            return []

        return [
            {
                "id": ORGANIZATION_ID,
                "organization_code": "EXISTING_ORG",
                "organization_name": "Existing Organization",
                "description": None,
                "is_active": True,
            }
        ]

    async def fake_list_sites(request) -> list[dict]:
        if not include_existing:
            return []

        return [
            {
                "id": SITE_ID,
                "organization_id": ORGANIZATION_ID,
                "organization_code": "EXISTING_ORG",
                "organization_name": "Existing Organization",
                "site_code": "EXISTING_SITE",
                "site_name": "Existing Site",
                "timezone": "Asia/Kolkata",
                "address": {},
                "is_active": True,
            }
        ]

    async def fake_list_spaces() -> list[dict]:
        if not include_existing:
            return []

        return [
            {
                "id": SPACE_ID,
                "organization_id": ORGANIZATION_ID,
                "organization_code": "EXISTING_ORG",
                "site_id": SITE_ID,
                "site_code": "EXISTING_SITE",
                "building_id": UUID(
                    "99999999-cccc-4999-8999-999999999999"
                ),
                "building_code": "MAIN_BUILDING",
                "building_name": "Main Building",
                "floor_id": UUID(
                    "aaaaaaaa-dddd-4aaa-8aaa-aaaaaaaaaaaa"
                ),
                "floor_code": "BASEMENT",
                "floor_name": "Basement",
                "space_code": "CHILLER_ROOM",
                "space_name": "Chiller Room",
            }
        ]

    async def fake_list_gateways() -> list[dict]:
        if not include_existing:
            return []

        return [
            {
                "id": GATEWAY_ID,
                "organization_id": ORGANIZATION_ID,
                "site_id": SITE_ID,
                "gateway_name": "Existing Gateway",
                "external_id": "EXISTING_GATEWAY",
            }
        ]

    async def fake_list_devices() -> list[dict]:
        if not include_existing:
            return []

        return [
            {
                "id": DEVICE_ID,
                "organization_id": ORGANIZATION_ID,
                "gateway_id": GATEWAY_ID,
                "site_id": SITE_ID,
                "device_category_id": CATEGORY_ID,
                "device_category_name": "Energy Meter",
                "profile_id": UUID(
                    "bbbbbbbb-eeee-4bbb-8bbb-bbbbbbbbbbbb"
                ),
                "profile_code": "ENISCOPE_V4",
                "external_id": "EXISTING_DEVICE",
                "device_name": "Existing Energy Meter",
            }
        ]

    async def fake_list_assets() -> list[dict]:
        if not include_existing:
            return []

        return [
            {
                "id": ASSET_ID,
                "organization_id": ORGANIZATION_ID,
                "organization_code": "EXISTING_ORG",
                "site_id": SITE_ID,
                "site_code": "EXISTING_SITE",
                "space_id": SPACE_ID,
                "parent_asset_id": None,
                "asset_type_id": ASSET_TYPE_ID,
                "asset_type_name": "Chiller",
                "asset_name": "Existing Chiller",
                "status": "active",
                "metering_requirement": "DIRECT_METER_REQUIRED",
            }
        ]

    async def fake_list_asset_types() -> list[dict]:
        return [
            {
                "id": ASSET_TYPE_ID,
                "name": "Chiller",
                "description": "Water-cooled chiller",
            }
        ]

    async def fake_list_device_categories() -> list[dict]:
        return [
            {
                "id": CATEGORY_ID,
                "name": "Energy Meter",
                "description": "Electrical energy meter",
            }
        ]

    monkeypatch.setattr(
        "src.main.list_organizations",
        fake_list_organizations,
    )
    monkeypatch.setattr("src.main.list_sites_for_request", fake_list_sites)
    monkeypatch.setattr("src.main.list_spaces", fake_list_spaces)
    monkeypatch.setattr(
        "src.main.list_gateways",
        fake_list_gateways,
    )
    monkeypatch.setattr("src.main.list_devices", fake_list_devices)
    monkeypatch.setattr("src.main.list_assets", fake_list_assets)
    monkeypatch.setattr(
        "src.main.list_asset_types",
        fake_list_asset_types,
    )
    monkeypatch.setattr(
        "src.main.list_device_categories",
        fake_list_device_categories,
    )


def test_review_get_rejects_invalid_draft_token(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)

    async def fake_list_organizations() -> list[dict]:
        return []

    monkeypatch.setattr(
        "src.main.list_organizations",
        fake_list_organizations,
    )

    response = portal_client.get(
        "/onboarding/review?draft=not-a-uuid"
    )

    assert response.status_code == 400
    assert "The onboarding draft token is invalid." in response.text


def test_review_get_returns_not_found_when_draft_and_result_missing(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(monkeypatch, None)
    install_submitted_result(monkeypatch, None)

    async def fake_list_organizations() -> list[dict]:
        return []

    monkeypatch.setattr(
        "src.main.list_organizations",
        fake_list_organizations,
    )

    response = portal_client.get(
        f"/onboarding/review?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 404
    assert (
        "The onboarding draft was not found or has expired."
        in response.text
    )


def test_review_get_redirects_submitted_draft_to_result(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(monkeypatch, None)
    install_submitted_result(
        monkeypatch,
        {
            "draft_token": DRAFT_TOKEN,
            "status": "SUBMITTED",
            "result": {"asset_id": str(ASSET_ID)},
        },
    )

    response = portal_client.get(
        f"/onboarding/review?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 303
    assert response.headers["location"] == (
        f"/onboarding/result?draft={DRAFT_TOKEN}"
    )


@pytest.mark.parametrize(
    ("payload", "expected_path"),
    [
        ({}, "/onboarding/organization"),
        (
            {"organization": {"mode": "CREATE_NEW"}},
            "/onboarding/site",
        ),
        (
            {
                "organization": {"mode": "CREATE_NEW"},
                "site": {"mode": "CREATE_NEW"},
            },
            "/onboarding/location",
        ),
        (
            {
                "organization": {"mode": "CREATE_NEW"},
                "site": {"mode": "CREATE_NEW"},
                "location": {"mode": "SITE_ONLY"},
            },
            "/onboarding/gateway",
        ),
        (
            {
                "organization": {"mode": "CREATE_NEW"},
                "site": {"mode": "CREATE_NEW"},
                "location": {"mode": "SITE_ONLY"},
                "gateway": {"mode": "CREATE_NEW"},
            },
            "/onboarding/device",
        ),
        (
            {
                "organization": {"mode": "CREATE_NEW"},
                "site": {"mode": "CREATE_NEW"},
                "location": {"mode": "SITE_ONLY"},
                "gateway": {"mode": "CREATE_NEW"},
                "device": {"mode": "CREATE_NEW"},
            },
            "/onboarding/asset",
        ),
    ],
)
def test_review_get_redirects_to_first_missing_step(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
    payload: dict,
    expected_path: str,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        {
            "draft_token": DRAFT_TOKEN,
            "payload": payload,
        },
    )

    response = portal_client.get(
        f"/onboarding/review?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 303
    assert response.headers["location"] == (
        f"{expected_path}?draft={DRAFT_TOKEN}"
    )


def test_review_get_renders_new_records_and_site_level_location(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(monkeypatch, new_records_draft())
    install_review_catalogs(monkeypatch)

    response = portal_client.get(
        f"/onboarding/review?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 200
    assert "Review and submit" in response.text
    assert "WiseWatts Demo Organization" in response.text
    assert "WISEWATTS_DEMO" in response.text
    assert "Demo Hotel" in response.text
    assert "DEMO_HOTEL" in response.text
    assert "Site level" in response.text
    assert "Chiller Gateway" in response.text
    assert "CHILLER_GATEWAY" in response.text
    assert "Chiller Energy Meter" in response.text
    assert "ENISCOPE_V4" in response.text
    assert "Chiller 1" in response.text
    assert "Direct Meter Required" in response.text
    assert "Primary Meter" in response.text
    assert "Submit onboarding" in response.text


def test_review_get_renders_created_location_hierarchy(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        new_records_draft(location_mode="CREATE_LOCATION"),
    )
    install_review_catalogs(monkeypatch)

    response = portal_client.get(
        f"/onboarding/review?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 200
    assert "Main Building" in response.text
    assert "MAIN_BUILDING" in response.text
    assert "Basement" in response.text
    assert "BASEMENT" in response.text
    assert "Chiller Plant Room" in response.text
    assert "CHILLER_PLANT_ROOM" in response.text


def test_review_get_renders_existing_record_labels(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(monkeypatch, existing_records_draft())
    install_review_catalogs(monkeypatch)

    response = portal_client.get(
        f"/onboarding/review?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 200
    assert "Existing Organization" in response.text
    assert "EXISTING_ORG" in response.text
    assert "Existing Site" in response.text
    assert "EXISTING_SITE" in response.text
    assert "Main Building / Basement / Chiller Room" in response.text
    assert "Existing Gateway" in response.text
    assert "EXISTING_GATEWAY" in response.text
    assert "Existing Energy Meter" in response.text
    assert "EXISTING_DEVICE" in response.text
    assert "Existing Chiller" in response.text
    assert "Secondary Meter" in response.text


def test_review_get_uses_fallback_labels_for_missing_existing_metadata(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(monkeypatch, existing_records_draft())
    install_review_catalogs(monkeypatch, include_existing=False)

    async def fake_resolve_device_context(
        draft_record: dict,
    ) -> tuple[str, str]:
        return "Existing device", "Energy Meter"

    monkeypatch.setattr(
        "src.main.resolve_draft_device_context",
        fake_resolve_device_context,
    )

    response = portal_client.get(
        f"/onboarding/review?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 200
    assert "Existing organization" in response.text
    assert "Existing site" in response.text
    assert "Existing space" in response.text
    assert "Existing gateway" in response.text
    assert "Existing device" in response.text
    assert "Existing asset" in response.text


def test_review_post_rejects_invalid_draft_token(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)

    async def fake_list_organizations() -> list[dict]:
        return []

    monkeypatch.setattr(
        "src.main.list_organizations",
        fake_list_organizations,
    )

    response = portal_client.post(
        "/onboarding/review",
        data={"draft_token": "not-a-uuid"},
    )

    assert response.status_code == 400
    assert "The onboarding draft token is invalid." in response.text


def test_review_post_returns_not_found_for_consumed_or_missing_draft(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(monkeypatch, None)

    async def fake_list_organizations() -> list[dict]:
        return []

    monkeypatch.setattr(
        "src.main.list_organizations",
        fake_list_organizations,
    )

    response = portal_client.post(
        "/onboarding/review",
        data={"draft_token": str(DRAFT_TOKEN)},
    )

    assert response.status_code == 404
    assert (
        "The onboarding draft was not found, has expired, "
        "or was already submitted."
        in response.text
    )


def test_review_post_submits_atomically_and_redirects_to_result(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(monkeypatch, new_records_draft())

    captured: dict = {}

    async def fake_submit_owned_draft(
        request,
        *,
        draft_token: UUID,
    ) -> dict:
        captured["draft_token"] = draft_token
        return {
            "organization_id": str(ORGANIZATION_ID),
            "site_id": str(SITE_ID),
            "gateway_id": str(GATEWAY_ID),
            "device_id": str(DEVICE_ID),
            "asset_id": str(ASSET_ID),
            "relationship_type": "PRIMARY_METER",
        }

    async def fake_provision_grafana_for_organization(
        *,
        organization_id: str,
        organization_name: str,
    ) -> dict:
        return {
            "organization_id": organization_id,
            "provisioning_status": "PROVISIONED",
        }

    monkeypatch.setattr(
        "src.main.submit_owned_onboarding_draft",
        fake_submit_owned_draft,
    )
    monkeypatch.setattr(
        "src.main.provision_grafana_for_organization",
        fake_provision_grafana_for_organization,
    )

    response = portal_client.post(
        "/onboarding/review",
        data={"draft_token": str(DRAFT_TOKEN)},
    )

    assert response.status_code == 303
    assert response.headers["location"] == (
        f"/onboarding/result?draft={DRAFT_TOKEN}"
    )
    assert captured == {"draft_token": DRAFT_TOKEN}


def test_review_post_provisions_grafana_for_new_organization(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(monkeypatch, new_records_draft())

    async def fake_submit_owned_draft(
        request,
        *,
        draft_token: UUID,
    ) -> dict:
        return {
            "organization_id": str(ORGANIZATION_ID),
            "site_id": str(SITE_ID),
            "gateway_id": str(GATEWAY_ID),
            "device_id": str(DEVICE_ID),
            "asset_id": str(ASSET_ID),
            "relationship_type": "PRIMARY_METER",
        }

    captured: dict[str, str] = {}

    async def fake_provision_grafana_for_organization(
        *,
        organization_id: str,
        organization_name: str,
    ) -> dict:
        captured.update(
            {
                "organization_id": organization_id,
                "organization_name": organization_name,
            }
        )
        return {
            "organization_id": organization_id,
            "provisioning_status": "PROVISIONED",
        }

    monkeypatch.setattr(
        "src.main.submit_owned_onboarding_draft",
        fake_submit_owned_draft,
    )
    monkeypatch.setattr(
        "src.main.provision_grafana_for_organization",
        fake_provision_grafana_for_organization,
    )

    response = portal_client.post(
        "/onboarding/review",
        data={"draft_token": str(DRAFT_TOKEN)},
    )

    assert response.status_code == 303
    assert captured == {
        "organization_id": str(ORGANIZATION_ID),
        "organization_name": "WiseWatts Demo Organization",
    }


def test_review_post_skips_grafana_for_existing_organization(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)

    draft = new_records_draft()
    draft["payload"]["organization"] = {
        "mode": "USE_EXISTING",
        "existing_organization_id": str(ORGANIZATION_ID),
    }
    install_visible_draft(monkeypatch, draft)

    async def fake_submit_owned_draft(
        request,
        *,
        draft_token: UUID,
    ) -> dict:
        return {
            "organization_id": str(ORGANIZATION_ID),
            "site_id": str(SITE_ID),
            "gateway_id": str(GATEWAY_ID),
            "device_id": str(DEVICE_ID),
            "asset_id": str(ASSET_ID),
            "relationship_type": "PRIMARY_METER",
        }

    async def unexpected_provision(**kwargs):
        raise AssertionError(
            "Existing organization must not be automatically reprovisioned."
        )

    monkeypatch.setattr(
        "src.main.submit_owned_onboarding_draft",
        fake_submit_owned_draft,
    )
    monkeypatch.setattr(
        "src.main.provision_grafana_for_organization",
        unexpected_provision,
    )

    response = portal_client.post(
        "/onboarding/review",
        data={"draft_token": str(DRAFT_TOKEN)},
    )

    assert response.status_code == 303


def test_review_post_grafana_failure_does_not_undo_onboarding(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(monkeypatch, new_records_draft())

    async def fake_submit_owned_draft(
        request,
        *,
        draft_token: UUID,
    ) -> dict:
        return {
            "organization_id": str(ORGANIZATION_ID),
            "site_id": str(SITE_ID),
            "gateway_id": str(GATEWAY_ID),
            "device_id": str(DEVICE_ID),
            "asset_id": str(ASSET_ID),
            "relationship_type": "PRIMARY_METER",
        }

    async def failed_provision(**kwargs):
        raise DatabaseError("Grafana provisioning ledger unavailable")

    monkeypatch.setattr(
        "src.main.submit_owned_onboarding_draft",
        fake_submit_owned_draft,
    )
    monkeypatch.setattr(
        "src.main.provision_grafana_for_organization",
        failed_provision,
    )

    response = portal_client.post(
        "/onboarding/review",
        data={"draft_token": str(DRAFT_TOKEN)},
    )

    assert response.status_code == 303
    assert response.headers["location"] == (
        f"/onboarding/result?draft={DRAFT_TOKEN}"
    )


def test_review_post_validation_failure_is_audited_and_rendered(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    draft = new_records_draft()
    install_visible_draft(monkeypatch, draft)
    install_review_catalogs(monkeypatch)

    class TestValidationError(Exception):
        def __init__(self, message: str) -> None:
            super().__init__(message)
            self.message = message

    async def fake_submit_owned_draft(*args, **kwargs):
        raise TestValidationError(
            "Primary meter relationship already exists."
        )

    audit: dict = {}

    async def fake_log_failure(
        *,
        draft_token: UUID,
        requested_by: str,
        error_message: str,
        error_type: str,
    ) -> None:
        audit.update(
            {
                "draft_token": draft_token,
                "requested_by": requested_by,
                "error_message": error_message,
                "error_type": error_type,
            }
        )

    monkeypatch.setattr(
        "src.main.OnboardingValidationError",
        TestValidationError,
    )
    monkeypatch.setattr(
        "src.main.submit_owned_onboarding_draft",
        fake_submit_owned_draft,
    )
    monkeypatch.setattr(
        "src.main.log_onboarding_submission_failure",
        fake_log_failure,
    )

    response = portal_client.post(
        "/onboarding/review",
        data={"draft_token": str(DRAFT_TOKEN)},
    )

    assert response.status_code == 422
    assert (
        "Primary meter relationship already exists."
        in response.text
    )
    assert audit["draft_token"] == DRAFT_TOKEN
    assert audit["error_message"] == (
        "Primary meter relationship already exists."
    )
    assert audit["error_type"] == "TestValidationError"


def test_review_post_database_failure_is_audited_and_rendered(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(monkeypatch, new_records_draft())
    install_review_catalogs(monkeypatch)

    async def fake_submit_owned_draft(*args, **kwargs):
        raise DatabaseError("forced final submission failure")

    audit: dict = {}

    async def fake_log_failure(
        *,
        draft_token: UUID,
        requested_by: str,
        error_message: str,
        error_type: str,
    ) -> None:
        audit.update(
            {
                "draft_token": draft_token,
                "requested_by": requested_by,
                "error_message": error_message,
                "error_type": error_type,
            }
        )

    monkeypatch.setattr(
        "src.main.submit_owned_onboarding_draft",
        fake_submit_owned_draft,
    )
    monkeypatch.setattr(
        "src.main.log_onboarding_submission_failure",
        fake_log_failure,
    )

    response = portal_client.post(
        "/onboarding/review",
        data={"draft_token": str(DRAFT_TOKEN)},
    )

    assert response.status_code == 409
    assert (
        "The database rejected the final onboarding request."
        in response.text
    )
    assert audit["draft_token"] == DRAFT_TOKEN
    assert audit["error_message"] == (
        "The database rejected the final onboarding request."
    )
    assert audit["error_type"] == "DatabaseError"


def test_review_post_does_not_mask_original_error_when_audit_fails(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(monkeypatch, new_records_draft())
    install_review_catalogs(monkeypatch)

    class TestValidationError(Exception):
        def __init__(self, message: str) -> None:
            super().__init__(message)
            self.message = message

    async def fake_submit_owned_draft(*args, **kwargs):
        raise TestValidationError("Original validation failure.")

    async def fake_log_failure(*args, **kwargs):
        raise RuntimeError("audit storage unavailable")

    monkeypatch.setattr(
        "src.main.OnboardingValidationError",
        TestValidationError,
    )
    monkeypatch.setattr(
        "src.main.submit_owned_onboarding_draft",
        fake_submit_owned_draft,
    )
    monkeypatch.setattr(
        "src.main.log_onboarding_submission_failure",
        fake_log_failure,
    )

    response = portal_client.post(
        "/onboarding/review",
        data={"draft_token": str(DRAFT_TOKEN)},
    )

    assert response.status_code == 422
    assert "Original validation failure." in response.text
    assert "audit storage unavailable" not in response.text


def test_result_get_rejects_invalid_result_token(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)

    async def fake_list_organizations() -> list[dict]:
        return []

    monkeypatch.setattr(
        "src.main.list_organizations",
        fake_list_organizations,
    )

    response = portal_client.get(
        "/onboarding/result?draft=not-a-uuid"
    )

    assert response.status_code == 400
    assert "The onboarding result token is invalid." in response.text


def test_result_get_returns_not_found_for_invisible_result(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_submitted_result(monkeypatch, None)

    async def fake_list_organizations() -> list[dict]:
        return []

    monkeypatch.setattr(
        "src.main.list_organizations",
        fake_list_organizations,
    )

    response = portal_client.get(
        f"/onboarding/result?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 404
    assert (
        "The submitted onboarding result was not found."
        in response.text
    )


def test_result_get_renders_visible_immutable_result(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)

    install_submitted_result(
        monkeypatch,
        {
            "draft_token": DRAFT_TOKEN,
            "status": "SUBMITTED",
            "requested_by": "review.operator@example.com",
            "owner_portal_user_id": 306,
            "payload": new_records_draft()["payload"],
            "result": {
                "organization_id": str(ORGANIZATION_ID),
                "site_id": str(SITE_ID),
                "gateway_id": str(GATEWAY_ID),
                "device_id": str(DEVICE_ID),
                "asset_id": str(ASSET_ID),
                "location_mode": "SITE_ONLY",
                "metering_requirement": "DIRECT_METER_REQUIRED",
                "relationship_type": "PRIMARY_METER",
            },
        },
    )

    response = portal_client.get(
        f"/onboarding/result?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 200
    assert str(ORGANIZATION_ID) in response.text
    assert str(SITE_ID) in response.text
    assert str(GATEWAY_ID) in response.text
    assert str(DEVICE_ID) in response.text
    assert str(ASSET_ID) in response.text
    assert "Direct Meter Required" in response.text
    assert "Primary Meter" in response.text
