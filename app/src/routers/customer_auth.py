"""Customer sign-in / sign-out for the customer API (ADR-023).

JSON endpoints for the EMS frontend's own sign-in page, replacing the
redirect to the Administration App's server-rendered /login on the customer
host. Credentials are verified exactly as the Administration App verifies
them (src.auth.service.authenticate_portal_user: Argon2, lockout, the
admin.* SECURITY DEFINER functions); only the audience differs. Every failure
-- unknown user, wrong password, disabled, locked, or an identity outside the
customer audience -- is the same generic 401.

Same-origin (CSRF) and session handling are enforced by
CustomerAuthenticationMiddleware / SessionMiddleware in src.customer_main.
"""

from __future__ import annotations

from fastapi import APIRouter, Request, Response, status
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from src.auth.audience import customer_audience
from src.auth.dependencies import clear_authenticated_portal_user, set_authenticated_portal_user
from src.auth.service import authenticate_portal_user
from src.config import get_core_settings
from src.routers.analytics_api import CurrentUserResponse, get_current_user

router = APIRouter(prefix="/auth", tags=["customer-auth"])

NO_STORE = {"Cache-Control": "no-store"}


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
        return JSONResponse(
            {"error": "invalid_credentials", "detail": "Invalid username or password."},
            status_code=status.HTTP_401_UNAUTHORIZED,
            headers=NO_STORE,
        )

    set_authenticated_portal_user(request, result.user)
    me = await get_current_user(request)
    return JSONResponse(me.model_dump(mode="json"), headers=NO_STORE)


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
async def logout(request: Request) -> Response:
    """End the customer session."""

    clear_authenticated_portal_user(request)
    return Response(status_code=status.HTTP_204_NO_CONTENT, headers=NO_STORE)
