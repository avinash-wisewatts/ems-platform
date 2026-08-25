"""Regression tests for live-tile pool-acquisition resilience (live_main.py).

Root cause under test: grafana_live_asset_websocket() called
fetch_grafana_asset_state() with no error handling. A transient
psycopg_pool.PoolTimeout (every pooled connection busy for the whole
acquisition window) propagated uncaught out of the WebSocket route handler
instead of being retried or closed cleanly, so every live-tile subscriber
observed a broken WebSocket handshake whenever the pool was saturated.

fetch_grafana_asset_state_with_retry() now retries a bounded, finite number
of times, and grafana_live_asset_websocket() closes the stream cleanly
(code 1013, "Try Again Later") if every attempt is exhausted, rather than
letting the exception escape uncaught.
"""

from pathlib import Path
from uuid import uuid4

import pytest
from psycopg_pool import PoolTimeout

from src import live_main

ROOT = Path(__file__).resolve().parents[2]
LIVE_MAIN_SOURCE = (ROOT / "app/src/live_main.py").read_text()


class _AttemptCountingFetch:
    """Stand-in for live_main.fetch_grafana_asset_state with a scripted
    sequence of outcomes, one per call."""

    def __init__(self, outcomes: list[Exception | list[dict]]) -> None:
        self._outcomes = list(outcomes)
        self.call_count = 0

    async def __call__(self, grafana_org_id: int, asset_id) -> list[dict]:
        self.call_count += 1
        outcome = self._outcomes.pop(0)
        if isinstance(outcome, Exception):
            raise outcome
        return outcome


@pytest.mark.asyncio
async def test_retry_succeeds_after_transient_pool_timeouts(monkeypatch: pytest.MonkeyPatch) -> None:
    """7 (bounded retry) + eventual success: PoolTimeout on the first two
    attempts, success on the third -- still within the configured bound."""
    expected_rows = [{"logical_point": "ACTIVE_POWER_TOTAL", "numeric_value": 12.5}]
    fetch = _AttemptCountingFetch([PoolTimeout("busy"), PoolTimeout("busy"), expected_rows])
    monkeypatch.setattr(live_main, "fetch_grafana_asset_state", fetch)
    monkeypatch.setattr(live_main.settings, "live_pool_acquire_max_attempts", 3)
    monkeypatch.setattr(live_main.settings, "live_pool_acquire_retry_backoff_seconds", 0.0)

    rows = await live_main.fetch_grafana_asset_state_with_retry(1, uuid4())

    assert rows == expected_rows
    assert fetch.call_count == 3


@pytest.mark.asyncio
async def test_retry_raises_pooltimeout_after_bound_exhausted(monkeypatch: pytest.MonkeyPatch) -> None:
    """5. LIVE TILE POOL TIMEOUT -- when every attempt fails, the wrapper
    raises a clean, expected PoolTimeout (not an unrelated/uncaught crash)
    after exactly the configured number of attempts -- proving the retry is
    finite, not infinite."""
    fetch = _AttemptCountingFetch([PoolTimeout("busy")] * 3)
    monkeypatch.setattr(live_main, "fetch_grafana_asset_state", fetch)
    monkeypatch.setattr(live_main.settings, "live_pool_acquire_max_attempts", 3)
    monkeypatch.setattr(live_main.settings, "live_pool_acquire_retry_backoff_seconds", 0.0)

    with pytest.raises(PoolTimeout):
        await live_main.fetch_grafana_asset_state_with_retry(1, uuid4())

    assert fetch.call_count == 3  # bounded: not 4, not unbounded


@pytest.mark.asyncio
async def test_retry_does_not_retry_on_success_first_try(monkeypatch: pytest.MonkeyPatch) -> None:
    """6. LIVE TILE SUCCESS -- normal pool acquisition is unchanged: exactly
    one call, no retry overhead, identical return value."""
    expected_rows = [{"logical_point": "VOLTAGE_L1", "numeric_value": 231.0}]
    fetch = _AttemptCountingFetch([expected_rows])
    monkeypatch.setattr(live_main, "fetch_grafana_asset_state", fetch)

    rows = await live_main.fetch_grafana_asset_state_with_retry(1, uuid4())

    assert rows == expected_rows
    assert fetch.call_count == 1


def test_retry_bound_is_finite_by_construction() -> None:
    """7. BOUNDED RETRY -- the loop is `for attempt in range(1, attempts + 1)`
    with no while-True/unbounded-retry construct, so it structurally cannot
    loop forever regardless of configured value."""
    wrapper_source = LIVE_MAIN_SOURCE.split(
        "async def fetch_grafana_asset_state_with_retry", 1
    )[1].split("async def fetch_grafana_asset_connectivity", 1)[0]
    assert "for attempt in range(1, attempts + 1):" in wrapper_source
    assert "while True" not in wrapper_source


def test_websocket_handler_catches_pooltimeout_and_closes_cleanly() -> None:
    """5 (continued). The live-tile WebSocket entry point wraps the retry
    call in try/except PoolTimeout and closes the stream with the standard
    "try again later" code instead of letting the exception escape -- proven
    structurally, matching this repo's existing convention (see
    test_live_telemetry_production_path_contract.py) of asserting on the
    route handler's source for wiring that is awkward to exercise through a
    full ASGI WebSocket test double.
    """
    handler_source = LIVE_MAIN_SOURCE.split(
        "async def grafana_live_asset_websocket", 1
    )[1].split("async def grafana_asset_status_websocket", 1)[0]

    assert "fetch_grafana_asset_state_with_retry(grafana_org_id, asset_id)" in handler_source
    assert "except PoolTimeout:" in handler_source
    assert "await websocket.close(code=1013)" in handler_source
    # The pool-timeout close happens before accept(), matching the existing
    # auth/not-found close-before-accept pattern already used in this file.
    assert handler_source.index("except PoolTimeout:") < handler_source.index("await websocket.accept()")
