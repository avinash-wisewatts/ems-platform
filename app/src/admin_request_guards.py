"""Request guards for the Administration App (admin-portal) that run before
authentication.

AdministrationRequestGuard does two things:

1. Cross-origin form posts to user management are refused (403). The session
   cookie is SameSite=Lax, which already keeps it off cross-site POSTs; this
   adds an explicit Origin check for the account-changing forms
   (/administration/users*, /administration/account*), as the JSON user-
   management API does. A browser always sends Origin on a form POST; a
   request without one (non-browser client) is left to SameSite and the
   permission checks.

2. When the dedicated ems-web container is in use (EMS_WEB_UPSTREAM set --
   staging, ADR-023), the EMS Web App is served ONLY on the customer host
   through the edge proxy. admin-portal then answers /app and /app/* with a
   plain 404 for everyone, signed in or not: it neither proxies to ems-web nor
   falls back to a bind-mounted bundle, and it no longer redirects to /login
   for those paths. Without EMS_WEB_UPSTREAM (production today) nothing
   changes: the bind-mounted bundle is served as before.
"""

from __future__ import annotations

from starlette.datastructures import Headers
from starlette.types import ASGIApp, Receive, Scope, Send

from src.auth.customer_session import same_origin

_STATE_CHANGING = frozenset({"POST", "PUT", "PATCH", "DELETE"})
_PROTECTED_FORM_PREFIXES = ("/administration/users", "/administration/account")

APP_REMOVED_MESSAGE = (
    b"Not found. The EMS Web App is served on the customer host, not by the "
    b"Administration App."
)


def is_app_path(path: str) -> bool:
    return path == "/app" or path.startswith("/app/")


def is_protected_form_path(path: str) -> bool:
    return any(path == prefix or path.startswith(prefix + "/") for prefix in _PROTECTED_FORM_PREFIXES)


class AdministrationRequestGuard:
    def __init__(self, app: ASGIApp, *, serve_app: bool) -> None:
        self.app = app
        self.serve_app = serve_app

    async def _respond(self, send: Send, status: int, body: bytes) -> None:
        await send(
            {
                "type": "http.response.start",
                "status": status,
                "headers": [
                    (b"content-type", b"text/plain; charset=utf-8"),
                    (b"cache-control", b"no-store"),
                    (b"content-length", str(len(body)).encode("ascii")),
                ],
            }
        )
        await send({"type": "http.response.body", "body": body})

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        path = scope.get("path", "/")

        if not self.serve_app and is_app_path(path):
            await self._respond(send, 404, APP_REMOVED_MESSAGE)
            return

        if scope.get("method", "GET").upper() in _STATE_CHANGING and is_protected_form_path(path):
            headers = Headers(scope=scope)
            origin = headers.get("origin")
            if origin is not None and not same_origin(origin, headers.get("host")):
                await self._respond(send, 403, b"Cross-origin request refused.")
                return

        await self.app(scope, receive, send)
