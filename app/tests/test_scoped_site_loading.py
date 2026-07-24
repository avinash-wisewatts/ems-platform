from types import SimpleNamespace

import pytest

from src.main import list_sites_for_request


@pytest.mark.asyncio
async def test_list_sites_for_request_uses_authenticated_actor(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    request = object()
    user = SimpleNamespace(portal_user_id=42)

    monkeypatch.setattr(
        "src.main.require_authenticated_portal_user",
        lambda supplied_request: (
            user
            if supplied_request is request
            else None
        ),
    )

    calls: list[int] = []

    async def fake_list_accessible_sites(
        *,
        portal_user_id: int,
    ):
        calls.append(portal_user_id)
        return [
            {
                "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                "site_name": "Scoped Site",
            }
        ]

    monkeypatch.setattr(
        "src.main.list_accessible_sites",
        fake_list_accessible_sites,
    )

    result = await list_sites_for_request(request)

    assert calls == [42]
    assert result == [
        {
            "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "site_name": "Scoped Site",
        }
    ]


@pytest.mark.asyncio
async def test_list_sites_for_request_does_not_use_global_site_list(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    request = object()
    user = SimpleNamespace(portal_user_id=77)

    monkeypatch.setattr(
        "src.main.require_authenticated_portal_user",
        lambda supplied_request: user,
    )

    async def fake_list_accessible_sites(
        *,
        portal_user_id: int,
    ):
        return []

    async def fail_global_list_sites():
        raise AssertionError(
            "Global list_sites must not be used for portal reads."
        )

    monkeypatch.setattr(
        "src.main.list_accessible_sites",
        fake_list_accessible_sites,
    )
    monkeypatch.setattr(
        "src.main.list_sites",
        fail_global_list_sites,
    )

    assert await list_sites_for_request(request) == []
