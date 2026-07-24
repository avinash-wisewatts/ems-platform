import pytest

from src.main import validate_existing_site_access
from src.onboarding.forms import OnboardingValidationError


@pytest.mark.asyncio
async def test_existing_site_must_be_visible_to_signed_in_user(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    request = object()

    async def fake_list_sites_for_request(supplied_request):
        assert supplied_request is request
        return [
            {
                "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                "organization_id": (
                    "11111111-1111-1111-1111-111111111111"
                ),
            }
        ]

    monkeypatch.setattr(
        "src.main.list_sites_for_request",
        fake_list_sites_for_request,
    )

    payload = {
        "organization": {
            "mode": "USE_EXISTING",
            "existing_organization_id": (
                "11111111-1111-1111-1111-111111111111"
            ),
        },
        "site": {
            "mode": "USE_EXISTING",
            "existing_site_id": (
                "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
            ),
        },
    }

    with pytest.raises(OnboardingValidationError) as exc_info:
        await validate_existing_site_access(
            request=request,
            payload=payload,
        )

    assert exc_info.value.field_name == "existing_site_id"
    assert "not available" in exc_info.value.message.lower()


@pytest.mark.asyncio
async def test_accessible_existing_site_is_accepted(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    request = object()
    site_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    organization_id = "11111111-1111-1111-1111-111111111111"

    async def fake_list_sites_for_request(supplied_request):
        return [
            {
                "id": site_id,
                "organization_id": organization_id,
            }
        ]

    monkeypatch.setattr(
        "src.main.list_sites_for_request",
        fake_list_sites_for_request,
    )

    await validate_existing_site_access(
        request=request,
        payload={
            "organization": {
                "mode": "USE_EXISTING",
                "existing_organization_id": organization_id,
            },
            "site": {
                "mode": "USE_EXISTING",
                "existing_site_id": site_id,
            },
        },
    )
