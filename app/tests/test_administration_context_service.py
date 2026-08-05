from types import SimpleNamespace

import pytest

from src.auth.models import AuthenticatedPortalUser
from src.context.models import AdministrationContext
from src.context.service import (
    AdministrationContextError,
    bootstrap_context_for_identity,
    clear_active_location,
    clear_active_organization,
    clear_active_site,
    get_administration_context,
    set_active_location,
    set_active_organization,
    set_active_site,
    store_administration_context,
)


ORG_ID = "11111111-1111-4111-8111-111111111111"
OTHER_ORG_ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
SITE_ID = "22222222-2222-4222-8222-222222222222"
OTHER_SITE_ID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
LOCATION_ID = "33333333-3333-4333-8333-333333333333"


def request_with_session() -> SimpleNamespace:
    return SimpleNamespace(session={})


def user(
    *,
    role_code: str = "ADMIN",
    organization_id: str | None = None,
    access_scope_mode: str | None = None,
    site_ids: tuple[str, ...] = (),
) -> AuthenticatedPortalUser:
    return AuthenticatedPortalUser(
        portal_user_id=1,
        username="admin@example.com",
        display_name="Administrator",
        role_code=role_code,
        organization_id=organization_id,
        access_scope_mode=access_scope_mode,
        site_ids=site_ids,
    )


def test_bootstrap_separates_platform_and_tenant_context() -> None:
    platform_request = request_with_session()
    tenant_request = request_with_session()

    platform_context = bootstrap_context_for_identity(
        platform_request,
        user(),
    )
    tenant_context = bootstrap_context_for_identity(
        tenant_request,
        user(
            role_code="ADMIN",
            organization_id=ORG_ID,
            access_scope_mode="ORGANIZATION",
        ),
    )

    assert platform_context.active_organization_id is None
    assert tenant_context.active_organization_id == ORG_ID


@pytest.mark.asyncio
async def test_platform_can_select_accessible_organization(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def fake_organizations(**kwargs):
        return [{"id": ORG_ID}]

    monkeypatch.setattr(
        "src.context.service._accessible_organizations",
        fake_organizations,
    )
    request = request_with_session()

    context = await set_active_organization(request, user(), ORG_ID)

    assert context.active_organization_id == ORG_ID
    assert get_administration_context(request) == context


@pytest.mark.asyncio
async def test_organization_selection_failure_preserves_context(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def fake_organizations(**kwargs):
        return [{"id": ORG_ID}]

    monkeypatch.setattr(
        "src.context.service._accessible_organizations",
        fake_organizations,
    )
    request = request_with_session()
    store_administration_context(
        request,
        AdministrationContext(active_organization_id=ORG_ID),
    )

    with pytest.raises(AdministrationContextError):
        await set_active_organization(request, user(), OTHER_ORG_ID)

    assert get_administration_context(
        request
    ).active_organization_id == ORG_ID


@pytest.mark.asyncio
async def test_site_selection_sets_parent_organization_context(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def fake_sites(**kwargs):
        return [
            {
                "id": SITE_ID,
                "organization_id": OTHER_ORG_ID,
                "organization_name": "Organization Two",
                "organization_code": "ORG_2",
                "site_name": "Site One",
                "site_code": "SITE_1",
            }
        ]

    monkeypatch.setattr(
        "src.context.service._accessible_sites",
        fake_sites,
    )
    request = request_with_session()
    store_administration_context(
        request,
        AdministrationContext(
            active_organization_id=ORG_ID,
            active_location_id=LOCATION_ID,
        ),
    )

    context = await set_active_site(request, user(), SITE_ID)

    assert context.active_organization_id == OTHER_ORG_ID
    assert context.active_organization_name == "Organization Two"
    assert context.active_organization_code == "ORG_2"
    assert context.active_site_id == SITE_ID
    assert context.active_location_id is None


@pytest.mark.asyncio
async def test_site_selection_stores_display_labels(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def fake_sites(**kwargs):
        return [
            {
                "id": SITE_ID,
                "organization_id": ORG_ID,
                "organization_name": "Organization One",
                "organization_code": "ORG_1",
                "site_name": "Site One",
                "site_code": "SITE_1",
            }
        ]

    monkeypatch.setattr(
        "src.context.service._accessible_sites",
        fake_sites,
    )
    request = request_with_session()
    store_administration_context(
        request,
        AdministrationContext(
            active_organization_id=ORG_ID,
            active_organization_name="Organization One",
            active_organization_code="ORG_1",
        ),
    )

    context = await set_active_site(request, user(), SITE_ID)

    assert context.active_organization_id == ORG_ID
    assert context.active_organization_name == "Organization One"
    assert context.active_organization_code == "ORG_1"
    assert context.active_site_id == SITE_ID
    assert context.active_site_name == "Site One"
    assert context.active_site_code == "SITE_1"



@pytest.mark.asyncio
async def test_parent_changes_clear_lower_context(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def fake_organizations(**kwargs):
        return [{"id": OTHER_ORG_ID}]

    monkeypatch.setattr(
        "src.context.service._accessible_organizations",
        fake_organizations,
    )
    request = request_with_session()
    store_administration_context(
        request,
        AdministrationContext(
            active_organization_id=ORG_ID,
            active_site_id=SITE_ID,
            active_location_id=LOCATION_ID,
        ),
    )

    context = await set_active_organization(
        request,
        user(),
        OTHER_ORG_ID,
    )

    assert context == AdministrationContext(
        active_organization_id=OTHER_ORG_ID
    )


@pytest.mark.asyncio
async def test_location_must_belong_to_active_site(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def fake_locations(**kwargs):
        return [
            {
                "organization_id": ORG_ID,
                "site_id": OTHER_SITE_ID,
                "building_id": LOCATION_ID,
                "floor_id": None,
                "space_id": None,
            }
        ]

    monkeypatch.setattr(
        "src.context.service._accessible_locations",
        fake_locations,
    )
    request = request_with_session()
    store_administration_context(
        request,
        AdministrationContext(
            active_organization_id=ORG_ID,
            active_site_id=SITE_ID,
        ),
    )

    with pytest.raises(AdministrationContextError):
        await set_active_location(request, user(), LOCATION_ID)


def test_clear_operations_keep_only_parent_context() -> None:
    request = request_with_session()
    store_administration_context(
        request,
        AdministrationContext(
            active_organization_id=ORG_ID,
            active_site_id=SITE_ID,
            active_location_id=LOCATION_ID,
        ),
    )

    assert clear_active_location(request) == AdministrationContext(
        active_organization_id=ORG_ID,
        active_site_id=SITE_ID,
    )
    assert clear_active_site(request) == AdministrationContext(
        active_organization_id=ORG_ID
    )
    assert clear_active_organization(request) == AdministrationContext()
