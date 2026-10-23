"""Reports tab -- background export job execution (report_export_worker.py):
a claimed job is built with its OWNER's portal-scoped reads and completed
with the ZIP; an inaccessible site, an export over the limit, an invalid
stored request and an unexpected error each FAIL the job with a useful
message; losing the lease never overwrites the new holder's work.
"""

from __future__ import annotations

import asyncio
import io
import zipfile
from datetime import timedelta
from uuid import UUID

import src.report_export_worker as worker
from tests.report_export_fixtures import SITE_ID, T0, FakeAnalytics


JOB_ID = "99999999-9999-4999-8999-999999999999"


def _job(**overrides) -> dict:
    job = {
        "id": UUID(JOB_ID), "portal_user_id": 777, "site_id": UUID(SITE_ID),
        "range_from": T0, "range_to": T0 + timedelta(hours=3),
        "requested_resolution": "1h", "resolution": "1h",
    }
    job.update(overrides)
    return job


class Recorder:
    def __init__(self, *, lease_ok: bool = True) -> None:
        self.completed: list[tuple] = []
        self.failed: list[tuple] = []
        self.leases = 0
        self.lease_ok = lease_ok

    def install(self, monkeypatch) -> None:
        async def complete(job_id, worker_id, file_name, content, asset_count, row_count, retention):
            self.completed.append((job_id, worker_id, file_name, content, asset_count, row_count, retention))
            return True

        async def fail(job_id, worker_id, code, message):
            self.failed.append((job_id, worker_id, code, message))
            return True

        async def extend(job_id, worker_id):
            self.leases += 1
            return self.lease_ok

        monkeypatch.setattr(worker, "complete_job", complete)
        monkeypatch.setattr(worker, "fail_job", fail)
        monkeypatch.setattr(worker, "extend_lease", extend)


async def _run(monkeypatch, fake: FakeAnalytics, recorder: Recorder, job: dict | None = None, max_cells: int = 10_000):
    fake.install(monkeypatch)
    recorder.install(monkeypatch)
    await worker.run_job(job or _job(), "w1", max_cells=max_cells, retention=timedelta(hours=24))


async def test_job_completes_with_the_zip_built_for_its_owner(monkeypatch) -> None:
    fake, recorder = FakeAnalytics(), Recorder()
    await _run(monkeypatch, fake, recorder)
    assert recorder.failed == []
    (job_id, worker_id, file_name, content, asset_count, row_count, retention) = recorder.completed[0]
    assert (job_id, worker_id, asset_count, row_count, retention) == (UUID(JOB_ID), "w1", 3, 6, timedelta(hours=24))
    assert file_name.endswith("_1h.zip")
    with zipfile.ZipFile(io.BytesIO(content)) as archive:
        assert len(archive.namelist()) == 3
    assert {args[0] for kind, args in fake.calls if kind in ("site", "catalog", "site_assets", "energy", "points")} == {777}
    assert recorder.leases == 3   # extended after every asset


async def test_inaccessible_site_fails_the_job(monkeypatch) -> None:
    recorder = Recorder()
    await _run(monkeypatch, FakeAnalytics(accessible=False), recorder)
    assert recorder.completed == []
    assert recorder.failed[0][2:] == ("site_not_accessible", "The site is no longer accessible to you.")


async def test_export_over_the_limit_fails_with_guidance(monkeypatch) -> None:
    recorder = Recorder()
    await _run(monkeypatch, FakeAnalytics(), recorder, max_cells=5)
    assert recorder.failed[0][2] == "export_too_large"
    assert "shorter time range" in recorder.failed[0][3]


async def test_unexpected_error_fails_the_job_without_leaking_details(monkeypatch) -> None:
    fake, recorder = FakeAnalytics(), Recorder()

    async def broken(*args, **kwargs):
        raise RuntimeError("connection to server at 10.0.0.5 failed: password authentication failed")

    fake.point_series = broken
    await _run(monkeypatch, fake, recorder)
    code, message = recorder.failed[0][2:]
    assert code == "export_failed"
    assert "10.0.0.5" not in message and "password" not in message
    assert "Retry" in message


async def test_losing_the_lease_stops_without_failing_or_completing(monkeypatch) -> None:
    recorder = Recorder(lease_ok=False)
    await _run(monkeypatch, FakeAnalytics(), recorder)
    assert recorder.completed == [] and recorder.failed == []


async def test_worker_runs_one_claimed_job_and_purges(monkeypatch) -> None:
    calls: list[str] = []

    async def claim(worker_id):
        calls.append("claim")
        return _job() if calls.count("claim") == 1 else None

    async def purge():
        calls.append("purge")

    async def run(job, worker_id, *, max_cells, retention):
        calls.append(f"run:{job['id']}")

    monkeypatch.setattr(worker, "claim_job", claim)
    monkeypatch.setattr(worker, "purge_expired", purge)
    monkeypatch.setattr(worker, "run_job", run)
    w = worker.ReportExportWorker(poll_seconds=1, max_cells=10, retention=timedelta(hours=1))
    assert await w.run_once() is True
    assert await w.run_once() is False
    # Purges on the first iteration whatever the loop clock reads, then only
    # every PURGE_EVERY_SECONDS.
    assert calls == ["purge", "claim", f"run:{JOB_ID}", "claim"]


async def test_first_purge_does_not_depend_on_the_monotonic_clock(monkeypatch) -> None:
    calls: list[str] = []

    async def claim(worker_id):
        return None

    async def purge():
        calls.append("purge")

    monkeypatch.setattr(worker, "claim_job", claim)
    monkeypatch.setattr(worker, "purge_expired", purge)
    loop = asyncio.get_running_loop()
    monkeypatch.setattr(loop, "time", lambda: 5.0)   # a freshly booted host
    w = worker.ReportExportWorker(poll_seconds=1, max_cells=10, retention=timedelta(hours=1))
    await w.run_once()
    await w.run_once()
    assert calls == ["purge"]


async def test_worker_start_and_stop_are_idempotent(monkeypatch) -> None:
    async def claim(worker_id):
        return None

    async def purge():
        return None

    monkeypatch.setattr(worker, "claim_job", claim)
    monkeypatch.setattr(worker, "purge_expired", purge)
    w = worker.ReportExportWorker(poll_seconds=1, max_cells=10, retention=timedelta(hours=1))
    w.start()
    w.start()
    await w.stop()
    await w.stop()
