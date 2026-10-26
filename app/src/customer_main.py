"""WiseWatts EMS customer API (ADR-023).

The customer-facing backend, separate from the Administration App
(src.main): the customer host's /api/v1/* and /auth/* are served here, so
customer requests never pass through the Administration App process.

- Same /api/v1 routers, services and database functions as the admin portal
  (src.routers.analytics_api, src.routers.report_exports): one
  implementation, two processes, identical contracts. Tenant scope is
  re-derived in the database from portal_user_id on every read.
- Its own signed session cookie (default ems_session) and signing secret,
  host-only on the customer host; never the Administration App cookie.
- Its own database role (EMS_APP_DB_USER=ems_customer_api, migration 313):
  EXECUTE on the customer-facing SECURITY DEFINER functions only.
- No administration, onboarding, Grafana, MQTT or /app routes and no
  administration configuration (src.customer_config).

Run: uvicorn src.customer_main:app --host 0.0.0.0 --port 8070
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import timedelta

from fastapi import FastAPI
from fastapi.responses import JSONResponse
from psycopg import sql
from starlette.middleware.sessions import SessionMiddleware

from src.api_errors import register_flat_error_handlers
from src.auth.customer_middleware import CustomerAuthenticationMiddleware
from src.config import use_core_settings
from src.customer_config import get_customer_settings
from src.database import close_database_pool, database_connection, open_database_pool
from src.report_export_worker import ReportExportWorker
from src.routers.analytics_api import router as analytics_api_router
from src.routers.customer_auth import router as customer_auth_router
from src.routers.report_exports import router as report_exports_router

settings = get_customer_settings()
use_core_settings(settings)


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    await open_database_pool()

    report_export_worker: ReportExportWorker | None = None
    if settings.reports_enabled and settings.report_export_worker_enabled:
        report_export_worker = ReportExportWorker(
            poll_seconds=settings.report_export_poll_seconds,
            max_cells=settings.report_export_max_cells,
            retention=timedelta(hours=settings.report_export_retention_hours),
        )
        report_export_worker.start()

    try:
        yield
    finally:
        if report_export_worker is not None:
            await report_export_worker.stop()
        await close_database_pool()


app = FastAPI(
    title="WiseWatts EMS Customer API",
    version="0.1.0",
    lifespan=lifespan,
    # No public API documentation on the customer host.
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)

# Registered first so SessionMiddleware (registered after, so outside it)
# verifies and populates the session before this gate reads it.
app.add_middleware(
    CustomerAuthenticationMiddleware,
    settings=settings,
)

app.add_middleware(
    SessionMiddleware,
    secret_key=settings.session_secret,
    session_cookie=settings.session_cookie_name,
    max_age=settings.session_max_age_seconds,
    same_site="lax",
    https_only=settings.session_https_only,
)

register_flat_error_handlers(app, ("/api/v1/", "/auth/"))

app.include_router(customer_auth_router)
app.include_router(analytics_api_router)
# Reports export routes exist only where Reports is enabled (staging-only).
if settings.reports_enabled:
    app.include_router(report_exports_router)


@app.get("/health", include_in_schema=False)
async def health() -> JSONResponse:
    """Verify application and restricted database connectivity."""

    async with database_connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                sql.SQL(
                    """
                    SELECT
                        current_database() AS database_name,
                        current_user AS database_user,
                        TRUE AS database_ok
                    """
                )
            )
            result = await cursor.fetchone()

    return JSONResponse(
        {
            "status": "ok",
            "service": "customer-api",
            "environment": settings.app_env,
            "database": {
                "status": "ok" if result["database_ok"] else "error",
                "name": result["database_name"],
                "user": result["database_user"],
            },
        }
    )
