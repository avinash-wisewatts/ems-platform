"""EMS_REPORTS_ENABLED gates the Reports export (routes and worker).

The Reports export's database objects (migrations 309 / 312) are staging-only
(postgres/migration_environment_scope.csv). Production never sets the flag,
so with the default (off) the app must expose no report-export route and must
not start the export worker. Settings are read once at import, so each case
imports the app in a fresh interpreter.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

APP_DIR = Path(__file__).resolve().parents[1]

PROBE = r"""
import asyncio, json
import src.main as main
from src.routers.report_exports import router as reports_router

report_paths = {route.path for route in reports_router.routes}
app_paths = {getattr(route, "path", None) for route in main.app.routes}

started = []
class FakeWorker:
    def __init__(self, **_):
        pass
    def start(self):
        started.append(True)
    async def stop(self):
        pass

async def _noop():
    return None

main.ReportExportWorker = FakeWorker
main.open_database_pool = _noop
main.close_database_pool = _noop

async def run_lifespan():
    async with main.lifespan(main.app):
        pass

asyncio.run(run_lifespan())
print(json.dumps({
    "report_paths": sorted(report_paths),
    "mounted": sorted(report_paths & app_paths),
    "worker_started": bool(started),
}))
"""


def _probe(**overrides: str) -> dict:
    env = dict(os.environ)
    env.pop("EMS_REPORTS_ENABLED", None)
    env.update(overrides)
    env["PYTHONPATH"] = str(APP_DIR)
    result = subprocess.run(
        [sys.executable, "-c", PROBE], cwd=APP_DIR, env=env, capture_output=True, text=True, timeout=120
    )
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout.strip().splitlines()[-1])


def test_default_is_off_no_routes_and_no_worker():
    state = _probe()                                   # production: the flag is never set
    assert state["report_paths"], "the Reports router defines routes"
    assert state["mounted"] == []
    assert state["worker_started"] is False


@pytest.mark.parametrize("value", ["false", "0"])
def test_explicitly_off(value):
    state = _probe(EMS_REPORTS_ENABLED=value)
    assert state["mounted"] == [] and state["worker_started"] is False


def test_on_mounts_every_route_and_starts_the_worker():
    state = _probe(EMS_REPORTS_ENABLED="true")
    assert state["mounted"] == state["report_paths"]
    assert state["worker_started"] is True


def test_on_with_the_worker_flag_off_mounts_routes_without_the_worker():
    state = _probe(EMS_REPORTS_ENABLED="true", EMS_REPORT_EXPORT_WORKER_ENABLED="false")
    assert state["mounted"] == state["report_paths"]
    assert state["worker_started"] is False
