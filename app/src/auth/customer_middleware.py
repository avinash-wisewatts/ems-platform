"""Authentication gate of the customer API (ADR-023).

The customer API is a JSON-only surface, so every rejection is a flat JSON
status ({"error": ..., "detail": ...}) -- never a redirect to an HTML page.

- /health, POST /auth/login and GET /auth/session are the only
  unauthenticated paths.
- Every state-changing request (anything but GET/HEAD/OPTIONS) must carry an
  Origin header naming the very host it was sent to (same-origin; the edge
  proxy passes the original Host through). This is the CSRF defence for the
  cookie-authenticated JSON writes (/auth/login, /auth/logout, Reports).
- A session identity outside the customer audience (src.auth.audience,
  per EMS_CUSTOMER_ALLOW_STAFF) is signed out and treated as unauthenticated.
- /api/v1/* requires the same permission the admin portal requires
  (src.auth.authorization.required_permission_for_request); /auth/* needs
  only an authenticated identity.

SessionMiddleware must wrap this middleware so scope["session"] holds the
verified signed-session data before it runs.
"""

from __future__ import annotations

import json
from urllib.parse import urlsplit

from starlette.datastructures import Headers, MutableHeaders
from starlette.types import ASGIApp, Receive, Scope, Send

from src.auth.audience import customer_audience
from src.auth.authorization import has_permission, required_permission_for_request
from src.auth.session import SESSION_IDENTITY_KEY, deserialize_authenticated_user
from src.config import CoreSettings

PUBLIC_PATHS = frozenset({"/health", "/auth/login", "/auth/session"})
SAFE_METHODS = frozenset({"GET", "HEAD", "OPTIONS"})


class CustomerAuthenticationMiddleware:
    def __init__(self, app: ASGIApp, settings: CoreSettings) -> None:
        self.app = app
        # Read per request (customer_allow_staff), so the gate and
        # POST /auth/login always apply the same audience.
        self.settings = settings

    async def _json_error(self, send: Send, status_code: int, code: str, detail: str) -> None:
        body = json.dumps({"error": code, "detail": detail}).encode("utf-8")
        headers = MutableHeaders()
        headers["content-type"] = "application/json"
        headers["cache-control"] = "no-store"
        headers["content-length"] = str(len(body))
        await send({"type": "http.response.start", "status": status_code, "headers": headers.raw})
        await send({"type": "http.response.body", "body": body})

    @staticmethod
    def _same_origin(headers: Headers) -> bool:
        origin = headers.get("origin")
        host = headers.get("host")
        if not origin or not host or origin == "null":
            return False
        return urlsplit(origin).netloc.lower() == host.lower()

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        path = scope.get("path", "/")
        method = scope.get("method", "GET").upper()

        if method not in SAFE_METHODS and not self._same_origin(Headers(scope=scope)):
            await self._json_error(send, 403, "forbidden", "Cross-origin request refused.")
            return

        if path in PUBLIC_PATHS:
            await self.app(scope, receive, send)
            return

        session = scope.get("session")
        identity = None
        if isinstance(session, dict):
            identity = deserialize_authenticated_user(session.get(SESSION_IDENTITY_KEY))
            audience = customer_audience(
                allow_staff=getattr(self.settings, "customer_allow_staff", False)
            )
            if identity is not None and not audience(identity):
                session.clear()
                identity = None

        if identity is None:
            await self._json_error(send, 401, "unauthenticated", "Authentication is required.")
            return

        if path.startswith("/api/v1/"):
            required = required_permission_for_request(method, path)
            if required is None or not has_permission(identity, required):
                await self._json_error(
                    send, 403, "forbidden", "You do not have permission to access this resource."
                )
                return

        await self.app(scope, receive, send)
