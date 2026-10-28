"""Customer sign-in / sign-out for the customer API (ADR-023).

JSON endpoints for the EMS frontend's own sign-in page, replacing the
redirect to the Administration App's server-rendered /login on the customer
host. Credentials are verified exactly as the Administration App verifies
them (src.auth.service.authenticate_portal_user: Argon2, lockout, the
admin.* SECURITY DEFINER functions); only the audience differs. Every failure
-- unknown user, wrong password, disabled, locked, or an identity outside the
customer audience -- is the same generic 401.

Sign-in also records a server-side session (migration 314,
src.auth.server_session) whose random token is kept in the signed cookie;
sign-out revokes it, so a copy of the cookie taken before sign-out is
refused everywhere afterwards (customer API and live-telemetry).

Same-origin (CSRF) and session handling are enforced by
CustomerAuthenticationMiddleware / SessionMiddleware in src.customer_main.
"""

from __future__ import annotations

import logging

from fastapi import APIRouter, Request, Response, status
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from src.auth import server_session
from src.auth.audience import customer_audience
from src.auth.customer_session import SESSION_TOKEN_KEY, new_session_token, session_token
from src.auth.dependencies import clear_authenticated_portal_user, set_authenticated_portal_user
from src.auth.service import authenticate_portal_user
from src.config import get_core_settings
from src.routers.analytics_api import CurrentUserResponse, get_current_user

router = APIRouter(prefix="/auth", tags=["customer-auth"])

NO_STORE = {"Cache-Control": "no-store"}
INVALID_CREDENTIALS = {"error": "invalid_credentials", "detail": "Invalid username or password."}

logger = logging.getLogger(__name__)


def _service_unavailable() -> JSONResponse:
    return JSONResponse(
        {"error": "service_unavailable", "detail": "Sign-in is temporarily unavailable. Try again shortly."},
        status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
        headers=NO_STORE,
    )


class LoginRequest(BaseModel):
    username: str = Field(min_length=1, max_length=320)
    password: str = Field(min_length=1, max_length=1024)


@router.get("/session")
async def sign_in_mode() -> Response:
    """Tell the EMS frontend that it may use its own sign-in page here.

    Public and identity-free. Only the customer API serves it, so the
    frontend can distinguish the customer host (sign in with POST
    /auth/login) from the Administration App path during the transition,
    where /auth/* does not exist and the server-rendered /login is used.
    """

    return JSONResponse({"sign_in": "customer"}, headers=NO_STORE)


@router.post("/login", response_model=CurrentUserResponse)
async def login(request: Request, body: LoginRequest) -> Response:
    """Verify credentials and establish the customer session."""

    settings = get_core_settings()
    result = await authenticate_portal_user(
        body.username,
        body.password,
        audience=customer_audience(allow_staff=getattr(settings, "customer_allow_staff", False)),
    )

    # Always start from an empty session: a failed attempt signs out, and a
    # successful one never inherits pre-authentication state (fixation).
    clear_authenticated_portal_user(request)

    if not result.authenticated or result.user is None:
        return JSONResponse(INVALID_CREDENTIALS, status_code=status.HTTP_401_UNAUTHORIZED, headers=NO_STORE)

    token = new_session_token()
    try:
        created = await server_session.create_server_session(
            result.user.portal_user_id,
            token,
            idle_seconds=settings.session_max_age_seconds,
            absolute_seconds=getattr(
                settings, "session_absolute_max_age_seconds", settings.session_max_age_seconds
            ),
        )
    except Exception:
        logger.exception("Customer session could not be created")
        return _service_unavailable()
    if not created:
        # Deactivated between the credential check and here.
        return JSONResponse(INVALID_CREDENTIALS, status_code=status.HTTP_401_UNAUTHORIZED, headers=NO_STORE)

    set_authenticated_portal_user(request, result.user)
    request.session[SESSION_TOKEN_KEY] = token
    me = await get_current_user(request)
    return JSONResponse(me.model_dump(mode="json"), headers=NO_STORE)


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
async def logout(request: Request) -> Response:
    """End the customer session, server-side as well as in the browser."""

    token = session_token(request.session)
    # The browser's copy is cleared whatever happens next.
    clear_authenticated_portal_user(request)
    if token is not None:
        try:
            await server_session.revoke_server_session(token, reason="LOGOUT")
        except Exception:
            logger.exception("Customer session could not be revoked")
            return JSONResponse(
                {"error": "service_unavailable", "detail": "Sign-out could not be completed. Try again shortly."},
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                headers=NO_STORE,
            )
    return Response(status_code=status.HTTP_204_NO_CONTENT, headers=NO_STORE)
