"""Flat JSON error contract for the machine-facing API surface.

The /api/v1 JSON surface uses a flat top-level error contract
({"error": "<code>", "detail": "<message>"}) consistent with the
authentication middlewares' 401/403. FastAPI's default HTTPException /
RequestValidationError handlers wrap the payload as {"detail": ...}; these
handlers render the flat shape for the given path prefixes only and delegate
to the framework defaults everywhere else, so no other route's error contract
changes. Shared by the admin portal (src.main) and the customer API
(src.customer_main) so both serve identical /api/v1 error bodies.
"""

from __future__ import annotations

from fastapi import FastAPI, Request
from fastapi.exception_handlers import (
    http_exception_handler as default_http_exception_handler,
    request_validation_exception_handler as default_request_validation_handler,
)
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, Response
from starlette.exceptions import HTTPException as StarletteHTTPException


def register_flat_error_handlers(app: FastAPI, prefixes: tuple[str, ...]) -> None:
    """Render the flat error contract for request paths under prefixes."""

    async def handle_http_exception(
        request: Request,
        exc: StarletteHTTPException,
    ) -> Response:
        if (
            request.url.path.startswith(prefixes)
            and isinstance(exc.detail, dict)
            and "error" in exc.detail
        ):
            return JSONResponse(
                exc.detail,
                status_code=exc.status_code,
                headers=getattr(exc, "headers", None),
            )
        return await default_http_exception_handler(request, exc)

    async def handle_request_validation_error(
        request: Request,
        exc: RequestValidationError,
    ) -> Response:
        if request.url.path.startswith(prefixes):
            return JSONResponse(
                {
                    "error": "invalid_request",
                    "detail": "One or more request parameters are missing or malformed.",
                },
                status_code=422,
            )
        return await default_request_validation_handler(request, exc)

    app.add_exception_handler(StarletteHTTPException, handle_http_exception)
    app.add_exception_handler(RequestValidationError, handle_request_validation_error)
