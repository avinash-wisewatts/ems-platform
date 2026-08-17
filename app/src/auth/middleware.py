from urllib.parse import quote

from starlette.datastructures import MutableHeaders
from starlette.types import ASGIApp, Receive, Scope, Send

from src.auth.authorization import (
    has_permission,
    required_permission_for_request,
)
from src.auth.session import (
    SESSION_IDENTITY_KEY,
    deserialize_authenticated_user,
)


class PortalAuthenticationMiddleware:
    """
    Enforce both authentication and role-based authorization.

    SessionMiddleware must wrap this middleware so scope["session"] contains
    verified signed-session data before this middleware executes.
    """

    PUBLIC_EXACT_PATHS = {
        "/login",
        "/health",
    }

    PUBLIC_PATH_PREFIXES = (
        "/static/",
    )

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    @classmethod
    def is_public_path(cls, path: str) -> bool:
        """Return True for deliberately unauthenticated paths."""

        return (
            path in cls.PUBLIC_EXACT_PATHS
            or any(
                path.startswith(prefix)
                for prefix in cls.PUBLIC_PATH_PREFIXES
            )
        )

    async def redirect(
        self,
        send: Send,
        *,
        location: str,
        status_code: int = 303,
    ) -> None:
        """Send a minimal no-store redirect response."""

        headers = MutableHeaders()
        headers["location"] = location
        headers["cache-control"] = "no-store"

        await send(
            {
                "type": "http.response.start",
                "status": status_code,
                "headers": headers.raw,
            }
        )

        await send(
            {
                "type": "http.response.body",
                "body": b"",
            }
        )

    async def __call__(
        self,
        scope: Scope,
        receive: Receive,
        send: Send,
    ) -> None:
        """Authenticate and authorize one protected HTTP request."""

        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        path = scope.get("path", "/")

        if self.is_public_path(path):
            await self.app(scope, receive, send)
            return

        session = scope.get("session")
        identity = None

        if isinstance(session, dict):
            identity = deserialize_authenticated_user(
                session.get(SESSION_IDENTITY_KEY)
            )

        if identity is None:
            query_string = scope.get(
                "query_string",
                b"",
            ).decode("latin-1")

            next_path = path

            if query_string:
                next_path = f"{path}?{query_string}"

            await self.redirect(
                send,
                location=(
                    "/login?next_path="
                    + quote(next_path, safe="")
                ),
            )
            return

        # The forbidden page itself must remain reachable by any authenticated
        # identity, including users with an unknown or revoked role.
        if path == "/forbidden":
            await self.app(scope, receive, send)
            return

        required_permission = required_permission_for_request(
            scope.get("method", "GET"),
            path,
        )

        if (
            required_permission is None
            or not has_permission(
                identity,
                required_permission,
            )
        ):
            await self.redirect(
                send,
                location="/forbidden",
            )
            return

        await self.app(scope, receive, send)
