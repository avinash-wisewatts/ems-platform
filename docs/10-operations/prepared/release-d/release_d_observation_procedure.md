# Release D — fixed 24-hour production observation window (PREPARED, not started)

Status: prepared 2026-10-25. **Not started; starting it needs explicit
approval**, and so does every production access below. Everything here is
read-only: catalog / statistics queries and bounded reads, with
`default_transaction_read_only=on`, short statement and lock timeouts.

## Tools (all on `docs/prod-release-plan-266-301`)

| Tool | Role | Validated |
|---|---|---|
| `release_d_window_baseline.sql` | Snapshot at w0: jobs by name, `total_runs`, failure total; prints the `-v` line | staging 2026-10-25 (9 roles, one job each) |
| `scripts/diagnostics/run_readonly_job_sampler.sh` + `prod_job_duration_sampler.sql` (P11) | 30-second samples of job stats and `pipeline_state` lag for the window; local output only | staging 2026-10-25 (120 s run; 227-sample run 09:56–11:49 UTC, 100 % coverage) |
| `release_d_acceptance_window.sql` | Criteria A–F over exactly [w0, w1) | staging 2026-10-25 (clean window PASS; known-error window B FAIL (3)) |
| `p11_lag_acceptance.py` | Lag criteria from P11 samples (PROPOSED definition, not yet formal) | staging samples PASS; injected faults detected |

## Preconditions (decide before w0)

1. Approval to start the window and to access production read-only for it.
2. Order with the 311 release: if 311 is released first, start w0 at least
   30 minutes after its postcheck, so the window covers the final state and
   not the container restarts.
3. Job 1061 state for the window (paused, or resumed after 311): record it. A
   paused job keeps `last_run_status = Failed`; that is reported, not counted
   as a new error.
4. No operator write session on production during the window (the 2026-10-24
   window was disturbed by the AirSense backfill and the bulk assignment).
5. Lag criteria: the formal "lag ≤ 330 / 450 / 540 s", or the PROPOSED L0–L4
   definition (plan section 6; ceilings absolute, excursions within them, per
   the user's 2026-10-25 decision) once approved as formal. Decided before
   evaluation. Source gaps go in `gaps.csv` as `start,end,stages,reason`.

## Steps

| Step | When | Action |
|---|---|---|
| 1 | w0 | `release_d_window_baseline.sql` on production (read-only). Save the printed `-v w0=… -v baseline=… -v failures0=…` line with the evidence |
| 2 | w0 (same minute) | Start P11: `run_readonly_job_sampler.sh ems-production <dir> 86400` from a machine that stays up for 24 h. Confirm `segments/…` first line is `on` (read-only) |
| 3 | during | Hands off. Record any event (deploy, gateway outage, host incident) with UTC times; source gaps go in a `gaps.csv` (`start,end,stages,reason`, one row per gap, with its section D / F evidence) |
| 4 | w1 = w0 + 24 h, within 30 min after | `release_d_acceptance_window.sql` with the saved variables (read-only, 60 s timeout; ~2 s on staging). Must also be within 48 h of w0 (raw-message retention for section D) |
| 5 | after w1 | P11 ends by itself at w1. `python -I p11_lag_acceptance.py --w0 '<w0>' --gaps gaps.csv <dir>/segments/*.txt` (exit 0 = PASS, 1 = FAIL / incomplete, 2 = input error) |
| 6 | after | Results and the decision recorded in the release plan; the formal acceptance needs the user's sign-off |

**Stopping P11 early** (lesson from 2026-10-25 on staging): create
`<dir>/STOP`, then end the runner and its `ssh` child. The remote `psql` can
survive a dropped connection (its `docker exec` pipe stays open) and keeps
sampling read-only until its sample count. Check
`pg_stat_activity WHERE application_name = 'ems_p11_job_sampler'`; ending that
session (`pg_terminate_backend`) on production needs its own approval.

## Criteria evaluated

| Source | Criterion | Tool |
|---|---|---|
| §6 All | No new job failures (no job errors in [w0, w1)) | acceptance SQL B |
| D record | +288 ± 1 runs per five-minute job, demand +96 ± 1 | acceptance SQL A (exact counts at w1 also in P11) |
| D record | Demand finalization p99 ≤ end + 8 min, max ≤ + 23 min, no missing bucket (strict window) | acceptance SQL C |
| D record | Non-VALID demand rows explained by gateways with no raw messages | acceptance SQL D (listings) |
| D record | 1-minute tier publication delay 4–8 min | acceptance SQL E |
| D record / §6 D | Lag (formal snapshot figures, or PROPOSED L0–L4 per-cycle definition); routing durations | P11 + `p11_lag_acceptance.py`; durations from P11 `duration_s` |
| D record | No 5-minute energy window missing devices outside source gaps | acceptance SQL F (listing) |
| §6 D | No 40P01 | acceptance SQL B |

## Cost on production

P11: one catalog query every 30 s (job stats + `pipeline_state`), 10 s
statement timeout. Acceptance SQL: bounded scans of the window on
`demand_intervals`, `raw_messages`, `energy_measurements`,
`energy_consumption_1min` (2 s total on staging; the 2026-10-25 production run
of the older script took a few seconds). Baseline: catalog only.
