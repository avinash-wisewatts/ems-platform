from contextlib import asynccontextmanager
import secrets
from typing import AsyncIterator
from uuid import UUID

from fastapi import FastAPI, Request, WebSocket, WebSocketDisconnect
from fastapi.encoders import jsonable_encoder
from fastapi.responses import JSONResponse
from psycopg.rows import dict_row
from psycopg_pool import AsyncConnectionPool
from starlette.middleware.sessions import SessionMiddleware

from src.auth.session import SESSION_IDENTITY_KEY, deserialize_authenticated_user
from src.live_config import get_live_settings
from src.live_telemetry.broker import LiveTelemetryBroker
from src.live_telemetry.hub import AssetLiveHub, GrafanaAssetLiveHub

settings = get_live_settings()
pool: AsyncConnectionPool | None = None
broker: LiveTelemetryBroker | None = None
hub = AssetLiveHub()
grafana_hub = GrafanaAssetLiveHub()

# Status subscribers are deliberately isolated from the existing
# numeric telemetry stream. A status-stream failure must never affect
# Voltage / Current / PF / THD / Power live subscribers.
grafana_status_hub = GrafanaAssetLiveHub()


async def fetch_asset_state(actor_id: int, asset_id: UUID) -> list[dict]:
    assert pool is not None
    async with pool.connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                """
                SELECT *
                FROM admin.get_portal_asset_live_state(%s, %s, statement_timestamp())
                """,
                (actor_id, asset_id),
            )
            return [dict(row) for row in await cursor.fetchall()]




async def fetch_grafana_asset_state(grafana_org_id: int, asset_id: UUID) -> list[dict]:
    """Tenant-safe live state for the Grafana adapter.

    Tenant enforcement remains in analytics.get_grafana_asset_live_state; the
    service token only authenticates the adapter itself.
    """
    assert pool is not None
    async with pool.connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                """
                SELECT *
                FROM analytics.get_grafana_asset_live_state(%s, %s, statement_timestamp())
                """,
                (grafana_org_id, asset_id),
            )
            return [dict(row) for row in await cursor.fetchall()]


async def fetch_grafana_asset_connectivity(
    grafana_org_id: int,
    asset_id: UUID,
) -> dict | None:
    """Tenant-safe status context for the isolated Grafana status stream."""
    assert pool is not None

    async with pool.connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                """
                SELECT *
                FROM analytics.get_grafana_asset_connectivity_context(
                    %s,
                    %s,
                    statement_timestamp()
                )
                """,
                (grafana_org_id, asset_id),
            )

            row = await cursor.fetchone()
            return dict(row) if row else None


def grafana_stream_authorized(websocket: WebSocket) -> bool:
    authorization = websocket.headers.get("authorization", "")
    scheme, _, presented = authorization.partition(" ")
    if scheme.lower() != "bearer" or not presented:
        return False
    return secrets.compare_digest(presented, settings.grafana_stream_token)


async def actor_can_access_asset(actor_id: int, asset_id: UUID) -> bool:
    assert pool is not None
    async with pool.connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                "SELECT admin.portal_user_can_access_asset(%s, %s) AS allowed",
                (actor_id, asset_id),
            )
            row = await cursor.fetchone()
            return bool(row and row["allowed"])


async def asset_ids_for_device(device_id: str) -> list[UUID]:
    assert pool is not None
    async with pool.connection() as connection:
        async with connection.cursor() as cursor:
            await cursor.execute(
                "SELECT asset_id FROM admin.list_live_asset_ids_for_device(%s::uuid)",
                (device_id,),
            )
            return [row["asset_id"] for row in await cursor.fetchall()]


async def publish_device_update(device_id: str) -> None:
    for asset_id in await asset_ids_for_device(device_id):
        for websocket in await hub.subscribers_for(asset_id):
            identity = deserialize_authenticated_user(
                websocket.scope.get("session", {}).get(SESSION_IDENTITY_KEY)
            )
            if identity is None:
                await hub.remove(asset_id, websocket)
                continue
            rows = await fetch_asset_state(identity.portal_user_id, asset_id)
            if not rows:
                continue
            try:
                await websocket.send_json(
                    jsonable_encoder(
                        {"type": "telemetry", "asset_id": str(asset_id), "points": rows}
                    )
                )
            except Exception:
                await hub.remove(asset_id, websocket)

        for subscriber in await grafana_hub.subscribers_for(asset_id):
            rows = await fetch_grafana_asset_state(subscriber.grafana_org_id, asset_id)
            if not rows:
                continue
            try:
                await subscriber.websocket.send_json(
                    jsonable_encoder(
                        {"type": "telemetry", "asset_id": str(asset_id), "points": rows}
                    )
                )
            except Exception:
                await grafana_hub.remove(
                    asset_id, subscriber.websocket, subscriber.grafana_org_id
                )


        # Publish isolated Grafana asset status updates.
        # This does not interact with the existing grafana_hub.
        for subscriber in await grafana_status_hub.subscribers_for(asset_id):
            connectivity = await fetch_grafana_asset_connectivity(
                subscriber.grafana_org_id,
                asset_id,
            )

            if connectivity is None:
                continue

            try:
                await subscriber.websocket.send_json(
                    jsonable_encoder(
                        {
                            "type": "status",
                            "asset_id": str(asset_id),
                            "latest_received_timestamp":
                                connectivity.get(
                                    "latest_raw_received_timestamp"
                                ),
                            "connectivity_state":
                                connectivity.get("connectivity_state"),
                        }
                    )
                )
            except Exception:
                await grafana_status_hub.remove(
                    asset_id,
                    subscriber.websocket,
                    subscriber.grafana_org_id,
                )


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    global pool, broker
    pool = AsyncConnectionPool(
        conninfo=settings.database_dsn,
        min_size=1,
        max_size=10,
        open=False,
        kwargs={"autocommit": False, "row_factory": dict_row},
    )
    await pool.open()
    await pool.wait()
    broker = LiveTelemetryBroker(
        pool=pool,
        host=settings.mqtt_host,
        port=settings.mqtt_port,
        username=settings.mqtt_username,
        password=settings.mqtt_password,
        client_id=settings.mqtt_client_id,
        use_tls=settings.mqtt_tls,
        on_device_update=publish_device_update,
    )
    await broker.start()
    try:
        yield
    finally:
        await broker.stop()
        await pool.close()
        broker = None
        pool = None


app = FastAPI(title="EMS Live Telemetry", lifespan=lifespan)
app.add_middleware(
    SessionMiddleware,
    secret_key=settings.session_secret,
    session_cookie=settings.session_cookie_name,
    max_age=settings.session_max_age_seconds,
    https_only=settings.session_https_only,
    same_site="lax",
)


async def database_health() -> bool:
    if pool is None:
        return False
    try:
        async with pool.connection() as connection:
            async with connection.cursor() as cursor:
                await cursor.execute("SELECT 1")
                row = await cursor.fetchone()
                return bool(row)
    except Exception:
        return False


@app.get("/health")
async def health() -> JSONResponse:
    db_ok = await database_health()
    broker_state = broker.health_snapshot() if broker is not None else {
        "mqtt_connected": False,
        "subscriptions_confirmed": 0,
        "subscriptions_expected": 0,
        "last_connect_at": None,
        "last_disconnect_at": None,
        "last_message_at": None,
        "last_ingest_success_at": None,
        "last_ingest_error_at": None,
        "last_ingest_error": None,
        "message_count": 0,
        "ingest_success_count": 0,
        "ingest_failure_count": 0,
    }
    subscriptions_ready = (
        broker_state["subscriptions_expected"] > 0
        and broker_state["subscriptions_confirmed"]
        >= broker_state["subscriptions_expected"]
    )
    ready = bool(db_ok and broker_state["mqtt_connected"] and subscriptions_ready)
    body = {
        "status": "ok" if ready else "degraded",
        "service": "live-telemetry",
        "database": {"connected": db_ok},
        "broker": broker_state,
    }
    return JSONResponse(body, status_code=200 if ready else 503)


@app.get("/api/live/assets/{asset_id}")
async def live_snapshot(request: Request, asset_id: UUID) -> JSONResponse:
    identity = deserialize_authenticated_user(
        request.session.get(SESSION_IDENTITY_KEY)
    )
    if identity is None:
        return JSONResponse({"detail": "Authentication required"}, status_code=401)
    if not await actor_can_access_asset(identity.portal_user_id, asset_id):
        return JSONResponse({"detail": "Asset not found or not accessible"}, status_code=404)
    rows = await fetch_asset_state(identity.portal_user_id, asset_id)
    return JSONResponse(jsonable_encoder({"type": "snapshot", "asset_id": str(asset_id), "points": rows}))


@app.websocket("/api/live/assets/{asset_id}/ws")
async def live_asset_websocket(websocket: WebSocket, asset_id: UUID) -> None:
    identity = deserialize_authenticated_user(
        websocket.scope.get("session", {}).get(SESSION_IDENTITY_KEY)
    )
    if identity is None:
        await websocket.close(code=4401)
        return
    if not await actor_can_access_asset(identity.portal_user_id, asset_id):
        await websocket.close(code=4404)
        return
    rows = await fetch_asset_state(identity.portal_user_id, asset_id)
    await websocket.accept()
    await hub.add(asset_id, websocket)
    try:
        await websocket.send_json(jsonable_encoder({"type": "snapshot", "asset_id": str(asset_id), "points": rows}))
        while True:
            await websocket.receive_text()
    except WebSocketDisconnect:
        pass
    finally:
        await hub.remove(asset_id, websocket)


@app.websocket("/api/live/grafana/{grafana_org_id}/assets/{asset_id}/ws")
async def grafana_live_asset_websocket(
    websocket: WebSocket, grafana_org_id: int, asset_id: UUID
) -> None:
    """Service-authenticated stream for the thin Grafana datasource adapter.

    The adapter identity is authenticated here. Tenant/asset scope is enforced
    by analytics.get_grafana_asset_live_state(grafana_org_id, asset_id, ...).
    """
    if not grafana_stream_authorized(websocket):
        await websocket.close(code=4401)
        return

    rows = await fetch_grafana_asset_state(grafana_org_id, asset_id)
    await websocket.accept()
    await grafana_hub.add(asset_id, websocket, grafana_org_id)
    try:
        await websocket.send_json(
            jsonable_encoder(
                {"type": "snapshot", "asset_id": str(asset_id), "points": rows}
            )
        )
        while True:
            await websocket.receive_text()
    except WebSocketDisconnect:
        pass
    finally:
        await grafana_hub.remove(asset_id, websocket, grafana_org_id)


@app.websocket(
    "/api/live/grafana/{grafana_org_id}/assets/{asset_id}/status/ws"
)
async def grafana_asset_status_websocket(
    websocket: WebSocket,
    grafana_org_id: int,
    asset_id: UUID,
) -> None:
    """Isolated Grafana asset-status stream.

    This endpoint is intentionally separate from the canonical numeric
    telemetry WebSocket. It supplies status timestamps only.
    """
    if not grafana_stream_authorized(websocket):
        await websocket.close(code=4401)
        return

    connectivity = await fetch_grafana_asset_connectivity(
        grafana_org_id,
        asset_id,
    )

    if connectivity is None:
        await websocket.close(code=4404)
        return

    await websocket.accept()

    await grafana_status_hub.add(
        asset_id,
        websocket,
        grafana_org_id,
    )

    try:
        await websocket.send_json(
            jsonable_encoder(
                {
                    "type": "status",
                    "asset_id": str(asset_id),
                    "latest_received_timestamp":
                        connectivity.get(
                            "latest_raw_received_timestamp"
                        ),
                    "connectivity_state":
                        connectivity.get("connectivity_state"),
                }
            )
        )

        while True:
            await websocket.receive_text()

    except WebSocketDisconnect:
        pass

    finally:
        await grafana_status_hub.remove(
            asset_id,
            websocket,
            grafana_org_id,
        )
