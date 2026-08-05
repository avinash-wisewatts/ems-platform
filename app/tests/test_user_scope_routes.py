from types import SimpleNamespace

import pytest

from src.main import change_user_scope_administration


@pytest.mark.asyncio
async def test_scope_route_calls_controlled_service(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    request = object()
    actor = SimpleNamespace(portal_user_id=10, access_scope_mode="GLOBAL", organization_id=None)
    captured: dict = {}

    monkeypatch.setattr(
        "src.main.require_authenticated_portal_user",
        lambda supplied_request: actor,
    )

    async def fake_set_scope(
        *,
        actor_portal_user_id: int,
        target_portal_user_id: int,
        access_scope_mode: str,
        organization_id: str | None,
        site_ids: tuple[str, ...],
    ) -> None:
        captured.update(
            {
                "actor_portal_user_id": actor_portal_user_id,
                "target_portal_user_id": target_portal_user_id,
                "access_scope_mode": access_scope_mode,
                "organization_id": organization_id,
                "site_ids": site_ids,
            }
        )

    async def fake_render(
        supplied_request,
        *,
        result=None,
        error=None,
        status_code=200,
        **kwargs,
    ):
        return {
            "request": supplied_request,
            "result": result,
            "error": error,
            "status_code": status_code,
        }

    monkeypatch.setattr(
        "src.main.set_managed_user_access_scope",
        fake_set_scope,
    )
    monkeypatch.setattr(
        "src.main.render_user_administration",
        fake_render,
    )

    response = await change_user_scope_administration(
        request=request,
        portal_user_id=42,
        access_scope_mode=" selected_sites ",
        organization_id="11111111-1111-1111-1111-111111111111",
        site_ids=[
            "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        ],
    )

    assert captured == {
        "actor_portal_user_id": 10,
        "target_portal_user_id": 42,
        "access_scope_mode": "SELECTED_SITES",
        "organization_id": "11111111-1111-1111-1111-111111111111",
        "site_ids": (
            "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
        ),
    }
    assert response["status_code"] == 200
    assert response["result"] == {
        "portal_user_id": 42,
        "access_scope_mode": "SELECTED_SITES",
        "action": "scope_changed",
    }


@pytest.mark.asyncio
async def test_scope_route_rejects_invalid_submission(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    request = object()
    actor = SimpleNamespace(portal_user_id=10, access_scope_mode="GLOBAL", organization_id=None)

    monkeypatch.setattr(
        "src.main.require_authenticated_portal_user",
        lambda supplied_request: actor,
    )

    async def unexpected_set_scope(**kwargs) -> None:
        raise AssertionError(
            "Invalid scope must not reach the database service."
        )

    async def fake_render(
        supplied_request,
        *,
        result=None,
        error=None,
        status_code=200,
        **kwargs,
    ):
        return {
            "error": error,
            "status_code": status_code,
        }

    monkeypatch.setattr(
        "src.main.set_managed_user_access_scope",
        unexpected_set_scope,
    )
    monkeypatch.setattr(
        "src.main.render_user_administration",
        fake_render,
    )

    response = await change_user_scope_administration(
        request=request,
        portal_user_id=42,
        access_scope_mode="SELECTED_SITES",
        site_ids=[],
    )

    assert response["status_code"] == 400
    assert "at least one site" in response["error"].lower()


@pytest.mark.asyncio
async def test_user_renderer_includes_accessible_site_catalog(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from src.main import render_user_administration

    request = object()
    actor = SimpleNamespace(
        portal_user_id=10,
        role_code="ADMIN",
        access_scope_mode="ORGANIZATION",
        organization_id=(
            "11111111-1111-1111-1111-111111111111"
        ),
    )

    users = [
        {
            "portal_user_id": 42,
            "role_code": "OPERATOR",
            "organization_id": actor.organization_id,
            "access_scope_mode": "SELECTED_SITES",
            "site_ids": [
                "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
            ],
        }
    ]

    sites = [
        {
            "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "organization_id": actor.organization_id,
            "site_name": "Site One",
            "site_code": "SITE_ONE",
        }
    ]

    monkeypatch.setattr(
        "src.main.require_authenticated_portal_user",
        lambda supplied_request: actor,
    )

    async def fake_list_manageable_users(
        *,
        actor_portal_user_id: int,
    ):
        assert actor_portal_user_id == 10
        return users

    async def fake_list_sites_for_request(supplied_request):
        assert supplied_request is request
        return sites

    monkeypatch.setattr(
        "src.main.list_manageable_users",
        fake_list_manageable_users,
    )
    monkeypatch.setattr(
        "src.main.list_sites_for_request",
        fake_list_sites_for_request,
    )

    def fake_template_response(
        *,
        request,
        name,
        context,
        status_code,
    ):
        return {
            "name": name,
            "context": context,
            "status_code": status_code,
        }

    monkeypatch.setattr(
        "src.main.templates.TemplateResponse",
        fake_template_response,
    )

    response = await render_user_administration(request)

    assert response["name"] == "users.html"
    assert response["context"]["users"] == users
    assert response["context"]["sites"] == sites
    assert response["status_code"] == 200
