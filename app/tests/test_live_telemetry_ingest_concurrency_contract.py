"""Regression tests for the MQTT ingest concurrency bound (broker.py).

Root cause under test: telemetry.ingest_live_rtdata() calls used to be
scheduled with no concurrency limit, so a burst of MQTT messages could
occupy every connection in the live-telemetry DB pool at once, starving the
live-tile read path that shares the same pool. LiveTelemetryBroker now
gates DB-connection acquisition inside _ingest() with an asyncio.Semaphore
sized below the pool's max_size.

These tests use a fake pool/connection/cursor -- no real database or MQTT
broker is involved, matching this repo's existing convention of exercising
async collaborators via lightweight fakes (see test_grafana_client.py)
rather than a live network dependency.
"""

import asyncio

import pytest

from src.live_telemetry.broker import LiveTelemetryBroker


class FakeCursor:
    def __init__(self, rows: list[dict], *, fail: bool = False) -> None:
        self._rows = rows
        self._fail = fail

    async def __aenter__(self) -> "FakeCursor":
        return self

    async def __aexit__(self, exc_type, exc, tb) -> None:
        return None

    async def execute(self, sql: str, params) -> None:
        if self._fail:
            raise RuntimeError("simulated ingest_live_rtdata failure")

    async def fetchall(self) -> list[dict]:
        return self._rows


class FakeConnection:
    def __init__(self, tracker: "ConcurrencyTracker", rows: list[dict], *, fail: bool, hold_seconds: float) -> None:
        self._tracker = tracker
        self._rows = rows
        self._fail = fail
        self._hold_seconds = hold_seconds
        self.committed = False

    def cursor(self) -> FakeCursor:
        return FakeCursor(self._rows, fail=self._fail)

    async def commit(self) -> None:
        self.committed = True


class ConcurrencyTracker:
    """Counts how many fake connections are held at once, and the peak."""

    def __init__(self) -> None:
        self.current = 0
        self.peak = 0


class FakePool:
    """Duck-typed stand-in for psycopg_pool.AsyncConnectionPool.

    _ingest() only ever calls `self.pool.connection()`, so a fake exposing
    just that async context manager is sufficient.
    """

    def __init__(
        self,
        tracker: ConcurrencyTracker,
        *,
        rows: list[dict] | None = None,
        fail: bool = False,
        hold_seconds: float = 0.02,
    ) -> None:
        self._tracker = tracker
        self._rows = rows if rows is not None else [{"device_id": "device-1"}]
        self._fail = fail
        self._hold_seconds = hold_seconds

    def connection(self):
        return self._ConnectionCtx(self)

    class _ConnectionCtx:
        def __init__(self, pool: "FakePool") -> None:
            self._pool = pool
            self._connection: FakeConnection | None = None

        async def __aenter__(self) -> FakeConnection:
            tracker = self._pool._tracker
            tracker.current += 1
            tracker.peak = max(tracker.peak, tracker.current)
            # Hold the "connection" briefly so bursts genuinely overlap,
            # the same way a slow/lock-contended query would in production.
            await asyncio.sleep(self._pool._hold_seconds)
            self._connection = FakeConnection(
                tracker, self._pool._rows, fail=self._pool._fail, hold_seconds=self._pool._hold_seconds
            )
            return self._connection

        async def __aexit__(self, exc_type, exc, tb) -> None:
            self._pool._tracker.current -= 1
            return None


def make_broker(pool: FakePool, *, ingest_max_concurrency: int, updates: list[str] | None = None) -> LiveTelemetryBroker:
    async def on_device_update(device_id: str) -> None:
        if updates is not None:
            updates.append(device_id)

    return LiveTelemetryBroker(
        pool=pool,  # type: ignore[arg-type]
        host="localhost",
        port=1883,
        username="u",
        password="p",
        client_id="test-client",
        use_tls=False,
        on_device_update=on_device_update,
        ingest_max_concurrency=ingest_max_concurrency,
    )


@pytest.mark.asyncio
async def test_burst_never_exceeds_configured_concurrency() -> None:
    """1. CONCURRENCY BOUND -- a burst cannot exceed ingest_max_concurrency
    concurrent DB-connection holders, regardless of burst size."""
    tracker = ConcurrencyTracker()
    pool = FakePool(tracker, hold_seconds=0.03)
    broker = make_broker(pool, ingest_max_concurrency=3)
    broker.loop = asyncio.get_running_loop()
    broker._ingest_semaphore = asyncio.Semaphore(broker._ingest_max_concurrency)

    burst_size = 20
    await asyncio.gather(
        *[broker._ingest(f"topic/{i}", {"rtdata": []}, None) for i in range(burst_size)]
    )

    assert tracker.peak <= 3
    assert tracker.peak == 3  # burst_size and hold_seconds are large enough to saturate the bound
    assert tracker.current == 0  # every semaphore slot and connection was released


@pytest.mark.asyncio
async def test_ingest_concurrency_leaves_pool_capacity_for_reads() -> None:
    """2. POOL PRESERVATION -- the configured ingest bound is deliberately
    below the live-telemetry pool's max_size=10, so at least some slots are
    always available to the read path even under maximum ingest load."""
    pool_max_size = 10
    tracker = ConcurrencyTracker()
    pool = FakePool(tracker, hold_seconds=0.03)
    broker = make_broker(pool, ingest_max_concurrency=6)
    broker.loop = asyncio.get_running_loop()
    broker._ingest_semaphore = asyncio.Semaphore(broker._ingest_max_concurrency)

    await asyncio.gather(*[broker._ingest(f"topic/{i}", {"rtdata": []}, None) for i in range(20)])

    assert broker._ingest_max_concurrency < pool_max_size
    assert tracker.peak <= broker._ingest_max_concurrency
    assert pool_max_size - tracker.peak >= 4  # slots structurally guaranteed free for reads


@pytest.mark.asyncio
async def test_normal_ingest_reaches_existing_ingest_path() -> None:
    """3. NORMAL INGEST -- a single message still reaches ingest_live_rtdata
    and publishes device updates exactly as before."""
    tracker = ConcurrencyTracker()
    pool = FakePool(tracker, rows=[{"device_id": "device-42"}], hold_seconds=0.0)
    updates: list[str] = []
    broker = make_broker(pool, ingest_max_concurrency=6, updates=updates)
    broker.loop = asyncio.get_running_loop()
    broker._ingest_semaphore = asyncio.Semaphore(broker._ingest_max_concurrency)

    await broker._ingest("wwems/v1/org/site/gw/telemetry", {"rtdata": [{"uid": "x"}]}, None)

    assert updates == ["device-42"]
    snapshot = broker.health_snapshot()
    assert snapshot["ingest_success_count"] == 1
    assert snapshot["ingest_failure_count"] == 0
    assert snapshot["last_ingest_error"] is None


@pytest.mark.asyncio
async def test_ingest_error_preserves_failure_semantics_and_releases_semaphore() -> None:
    """4. INGEST ERROR -- a failure is classified exactly as before (re-raised,
    counted, recorded) and does not leave the semaphore permanently held."""
    tracker = ConcurrencyTracker()
    pool = FakePool(tracker, fail=True, hold_seconds=0.0)
    broker = make_broker(pool, ingest_max_concurrency=2)
    broker.loop = asyncio.get_running_loop()
    broker._ingest_semaphore = asyncio.Semaphore(broker._ingest_max_concurrency)

    with pytest.raises(RuntimeError):
        await broker._ingest("topic", {"rtdata": []}, None)

    snapshot = broker.health_snapshot()
    assert snapshot["ingest_failure_count"] == 1
    assert snapshot["last_ingest_error"] is not None
    assert "simulated ingest_live_rtdata failure" in snapshot["last_ingest_error"]

    # The semaphore must not be stuck held after an exception: a second,
    # successful ingest must be able to proceed without deadlocking.
    pool._fail = False
    pool._rows = [{"device_id": "device-recovered"}]
    await asyncio.wait_for(
        broker._ingest("topic", {"rtdata": []}, None), timeout=1.0
    )
    assert broker.health_snapshot()["ingest_success_count"] == 1


@pytest.mark.asyncio
async def test_ingest_semaphore_created_on_start_and_scoped_to_configured_value() -> None:
    """Semaphore lifecycle: absent before start(), present with the
    configured bound after start(), without touching real MQTT I/O."""
    tracker = ConcurrencyTracker()
    pool = FakePool(tracker)
    broker = make_broker(pool, ingest_max_concurrency=4)
    assert broker._ingest_semaphore is None

    # Avoid any real network activity: start() also opens the MQTT client's
    # background reconnect loop, which this test does not need to exercise.
    broker.client.connect_async = lambda *a, **k: None  # type: ignore[assignment]
    broker.client.loop_start = lambda: None  # type: ignore[assignment]
    broker.client.loop_stop = lambda: None  # type: ignore[assignment]
    broker.client.disconnect = lambda: None  # type: ignore[assignment]

    try:
        await broker.start()
        assert isinstance(broker._ingest_semaphore, asyncio.Semaphore)
        assert broker._ingest_semaphore._value == 4  # unacquired capacity equals the configured bound
    finally:
        await broker.stop()
