import pytest

from src.grafana_client import GrafanaApiError
from src.onboarding.grafana_provisioning_service import (
    provision_grafana_for_organization,
)


@pytest.mark.asyncio
async def test_provision_grafana_completes_successfully(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[tuple[str, object]] = []

    async def fake_get_state(organization_id: str):
        calls.append(("get_state", organization_id))
        return None

    async def fake_mark_pending(organization_id: str):
        calls.append(("mark_pending", organization_id))
        return {
            "provisioning_status": "PENDING",
        }

    class FakeGrafanaClient:
        async def provision_organization(
            self,
            *,
            organization_name: str,
            existing_org_id: int | None = None,
        ) -> int:
            calls.append(
                (
                    "provision",
                    (
                        organization_name,
                        existing_org_id,
                    ),
                )
            )
            return {
                "grafana_org_id": 7,
                "datasource_action": "created",
                "datasource_uid": "ems-timescaledb",
                "datasource_name": "EMS TimescaleDB",
                "datasource_version": 1,
            }

    async def fake_mark_complete(
        organization_id: str,
        grafana_org_id: int,
    ):
        calls.append(
            (
                "mark_complete",
                (
                    organization_id,
                    grafana_org_id,
                ),
            )
        )
        return {
            "organization_id": organization_id,
            "provisioning_status": "PROVISIONED",
            "grafana_org_id": grafana_org_id,
            "attempt_count": 1,
            "last_error": None,
        }

    async def unexpected_mark_failed(*args, **kwargs):
        raise AssertionError(
            "Successful provisioning must not record failure."
        )

    monkeypatch.setattr(
        "src.onboarding.grafana_provisioning_service."
        "get_grafana_provisioning",
        fake_get_state,
    )
    monkeypatch.setattr(
        "src.onboarding.grafana_provisioning_service."
        "mark_grafana_provisioning_pending",
        fake_mark_pending,
    )
    monkeypatch.setattr(
        "src.onboarding.grafana_provisioning_service."
        "GrafanaClient",
        FakeGrafanaClient,
    )
    monkeypatch.setattr(
        "src.onboarding.grafana_provisioning_service."
        "mark_grafana_provisioning_complete",
        fake_mark_complete,
    )
    monkeypatch.setattr(
        "src.onboarding.grafana_provisioning_service."
        "mark_grafana_provisioning_failed",
        unexpected_mark_failed,
    )

    result = await provision_grafana_for_organization(
        organization_id="org-1",
        organization_name="Organization One",
    )

    assert result["provisioning_status"] == "PROVISIONED"
    assert result["grafana_org_id"] == 7
    assert calls == [
        ("get_state", "org-1"),
        ("mark_pending", "org-1"),
        (
            "provision",
            (
                "Organization One",
                None,
            ),
        ),
        (
            "mark_complete",
            (
                "org-1",
                7,
            ),
        ),
    ]


@pytest.mark.asyncio
async def test_provision_grafana_reuses_existing_mapping(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    captured: dict = {}

    async def fake_get_state(organization_id: str):
        return {
            "organization_id": organization_id,
            "provisioning_status": "FAILED",
            "grafana_org_id": 9,
            "attempt_count": 2,
            "last_error": "Previous failure",
        }

    async def fake_mark_pending(organization_id: str):
        return {
            "organization_id": organization_id,
            "provisioning_status": "PENDING",
        }

    class FakeGrafanaClient:
        async def provision_organization(
            self,
            *,
            organization_name: str,
            existing_org_id: int | None = None,
        ) -> int:
            captured.update(
                {
                    "organization_name": organization_name,
                    "existing_org_id": existing_org_id,
                }
            )
            return {
                "grafana_org_id": 9,
                "datasource_action": "updated",
                "datasource_uid": "ems-timescaledb",
                "datasource_name": "EMS TimescaleDB",
                "datasource_version": 2,
            }

    async def fake_mark_complete(
        organization_id: str,
        grafana_org_id: int,
    ):
        return {
            "organization_id": organization_id,
            "provisioning_status": "PROVISIONED",
            "grafana_org_id": grafana_org_id,
        }

    monkeypatch.setattr(
        "src.onboarding.grafana_provisioning_service."
        "get_grafana_provisioning",
        fake_get_state,
    )
    monkeypatch.setattr(
        "src.onboarding.grafana_provisioning_service."
        "mark_grafana_provisioning_pending",
        fake_mark_pending,
    )
    monkeypatch.setattr(
        "src.onboarding.grafana_provisioning_service."
        "GrafanaClient",
        FakeGrafanaClient,
    )
    monkeypatch.setattr(
        "src.onboarding.grafana_provisioning_service."
        "mark_grafana_provisioning_complete",
        fake_mark_complete,
    )

    result = await provision_grafana_for_organization(
        organization_id="org-1",
        organization_name="Organization One",
    )

    assert captured == {
        "organization_name": "Organization One",
        "existing_org_id": 9,
    }
    assert result["grafana_org_id"] == 9


@pytest.mark.asyncio
async def test_provision_grafana_records_failure(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[tuple[str, object]] = []

    async def fake_get_state(organization_id: str):
        return None

    async def fake_mark_pending(organization_id: str):
        calls.append(("mark_pending", organization_id))
        return {
            "provisioning_status": "PENDING",
        }

    class FailingGrafanaClient:
        async def provision_organization(
            self,
            *,
            organization_name: str,
            existing_org_id: int | None = None,
        ) -> int:
            raise GrafanaApiError(
                "Grafana returned HTTP 503: unavailable"
            )

    async def fake_mark_failed(
        organization_id: str,
        error_message: str,
    ):
        calls.append(
            (
                "mark_failed",
                (
                    organization_id,
                    error_message,
                ),
            )
        )
        return {
            "organization_id": organization_id,
            "provisioning_status": "FAILED",
            "grafana_org_id": None,
            "attempt_count": 1,
            "last_error": error_message,
        }

    async def unexpected_mark_complete(*args, **kwargs):
        raise AssertionError(
            "Failed provisioning must not record completion."
        )

    monkeypatch.setattr(
        "src.onboarding.grafana_provisioning_service."
        "get_grafana_provisioning",
        fake_get_state,
    )
    monkeypatch.setattr(
        "src.onboarding.grafana_provisioning_service."
        "mark_grafana_provisioning_pending",
        fake_mark_pending,
    )
    monkeypatch.setattr(
        "src.onboarding.grafana_provisioning_service."
        "GrafanaClient",
        FailingGrafanaClient,
    )
    monkeypatch.setattr(
        "src.onboarding.grafana_provisioning_service."
        "mark_grafana_provisioning_failed",
        fake_mark_failed,
    )
    monkeypatch.setattr(
        "src.onboarding.grafana_provisioning_service."
        "mark_grafana_provisioning_complete",
        unexpected_mark_complete,
    )

    result = await provision_grafana_for_organization(
        organization_id="org-1",
        organization_name="Organization One",
    )

    assert result["provisioning_status"] == "FAILED"
    assert "HTTP 503" in result["last_error"]
    assert calls == [
        ("mark_pending", "org-1"),
        (
            "mark_failed",
            (
                "org-1",
                "Grafana returned HTTP 503: unavailable",
            ),
        ),
    ]
