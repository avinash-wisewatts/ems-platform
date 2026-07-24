import pytest

from src.auth.access_scope import (
    PortalAccessScope,
    PortalAccessScopeMode,
    can_access_site,
    validate_portal_access_scope,
)


ORGANIZATION_ID = "11111111-1111-1111-1111-111111111111"
OTHER_ORGANIZATION_ID = "22222222-2222-2222-2222-222222222222"
SITE_ONE_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
SITE_TWO_ID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"


def test_organization_scope_allows_every_site_in_organization() -> None:
    scope = PortalAccessScope(
        mode=PortalAccessScopeMode.ORGANIZATION,
        organization_id=ORGANIZATION_ID,
        site_ids=frozenset(),
    )

    assert can_access_site(
        scope=scope,
        site_id=SITE_ONE_ID,
        site_organization_id=ORGANIZATION_ID,
    )
    assert can_access_site(
        scope=scope,
        site_id=SITE_TWO_ID,
        site_organization_id=ORGANIZATION_ID,
    )


def test_organization_scope_rejects_another_organization() -> None:
    scope = PortalAccessScope(
        mode=PortalAccessScopeMode.ORGANIZATION,
        organization_id=ORGANIZATION_ID,
        site_ids=frozenset(),
    )

    assert not can_access_site(
        scope=scope,
        site_id=SITE_ONE_ID,
        site_organization_id=OTHER_ORGANIZATION_ID,
    )


def test_selected_sites_scope_allows_only_assigned_sites() -> None:
    scope = PortalAccessScope(
        mode=PortalAccessScopeMode.SELECTED_SITES,
        organization_id=ORGANIZATION_ID,
        site_ids=frozenset({SITE_ONE_ID}),
    )

    assert can_access_site(
        scope=scope,
        site_id=SITE_ONE_ID,
        site_organization_id=ORGANIZATION_ID,
    )
    assert not can_access_site(
        scope=scope,
        site_id=SITE_TWO_ID,
        site_organization_id=ORGANIZATION_ID,
    )


def test_selected_sites_scope_rejects_cross_organization_site() -> None:
    scope = PortalAccessScope(
        mode=PortalAccessScopeMode.SELECTED_SITES,
        organization_id=ORGANIZATION_ID,
        site_ids=frozenset({SITE_ONE_ID}),
    )

    assert not can_access_site(
        scope=scope,
        site_id=SITE_ONE_ID,
        site_organization_id=OTHER_ORGANIZATION_ID,
    )


def test_selected_sites_scope_requires_at_least_one_site() -> None:
    scope = PortalAccessScope(
        mode=PortalAccessScopeMode.SELECTED_SITES,
        organization_id=ORGANIZATION_ID,
        site_ids=frozenset(),
    )

    with pytest.raises(
        ValueError,
        match="at least one site",
    ):
        validate_portal_access_scope(scope)


def test_organization_scope_must_not_store_site_ids() -> None:
    scope = PortalAccessScope(
        mode=PortalAccessScopeMode.ORGANIZATION,
        organization_id=ORGANIZATION_ID,
        site_ids=frozenset({SITE_ONE_ID}),
    )

    with pytest.raises(
        ValueError,
        match="must not include site assignments",
    ):
        validate_portal_access_scope(scope)


def test_tenant_scope_requires_organization() -> None:
    scope = PortalAccessScope(
        mode=PortalAccessScopeMode.ORGANIZATION,
        organization_id=None,
        site_ids=frozenset(),
    )

    with pytest.raises(
        ValueError,
        match="organization",
    ):
        validate_portal_access_scope(scope)


def test_normalize_organization_scope_submission() -> None:
    from src.auth.access_scope import (
        normalize_portal_access_scope_submission,
    )

    mode, site_ids = normalize_portal_access_scope_submission(
        access_scope_mode=" organization ",
        site_ids=[],
    )

    assert mode == PortalAccessScopeMode.ORGANIZATION
    assert site_ids == ()


def test_normalize_selected_sites_submission() -> None:
    from src.auth.access_scope import (
        normalize_portal_access_scope_submission,
    )

    mode, site_ids = normalize_portal_access_scope_submission(
        access_scope_mode="SELECTED_SITES",
        site_ids=[
            "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        ],
    )

    assert mode == PortalAccessScopeMode.SELECTED_SITES
    assert site_ids == (
        "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
    )


@pytest.mark.parametrize(
    ("access_scope_mode", "site_ids"),
    [
        ("UNKNOWN", []),
        ("ORGANIZATION", [
            "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        ]),
        ("SELECTED_SITES", []),
        ("SELECTED_SITES", ["not-a-uuid"]),
    ],
)
def test_invalid_scope_submission_fails_closed(
    access_scope_mode: str,
    site_ids: list[str],
) -> None:
    from src.auth.access_scope import (
        normalize_portal_access_scope_submission,
    )

    with pytest.raises(ValueError):
        normalize_portal_access_scope_submission(
            access_scope_mode=access_scope_mode,
            site_ids=site_ids,
        )
