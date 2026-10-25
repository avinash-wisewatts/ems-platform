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
| `p11_lag_acceptance.py` | Formal Release D lag criteria (L0–L5) from P11 samples; only a complete 24-hour window can pass | 26 fault-injection tests (CI job "Release D lag evaluator tests"); staging samples per stage within all limits |

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
5. Lag criteria: the formal "Release D lag criteria" (plan section 6, adopted
   2026-10-25; they supersede "lag ≤ 330 / 450 / 540 s"): per-cycle targets
   330 / 540 / 540 s, absolute ceilings 600 / 600 / 620 s, excursions of at
   most 10 consecutive samples and at most three per stage, documented source
   gaps only, ≥ 99 % coverage, a complete 24-hour window.

## Steps

| Step | When | Action |
|---|---|---|
| 1 | w0 − 2 min | Start P11 first, so it covers the whole window: `run_readonly_job_sampler.sh ems-production <dir> 87000` (24 h 10 min) from a machine that stays up for the window. Confirm `segments/…` first line is `on` (read-only) |
| 2 | w0 | `release_d_window_baseline.sql` on production (read-only). Save the printed `-v w0=… -v baseline=… -v failures0=…` line with the evidence. The lag evaluator uses the same w0 (to the second) |
| 3 | during | Hands off. Record any event (deploy, gateway outage, host incident) with UTC times; source gaps go in a `gaps.csv` (`start,end,stages,reason`, one row per gap, with its section D / F evidence) |
| 4 | w1 = w0 + 24 h, within 30 min after | `release_d_acceptance_window.sql` with the saved variables (read-only, 60 s timeout; ~2 s on staging). Must also be within 48 h of w0 (raw-message retention for section D) |
| 5 | after w1 | P11 ends by itself about 8 minutes after w1. `python -I p11_lag_acceptance.py --w0 '<w0>' --gaps gaps.csv <dir>/segments/*.txt` (no `--w1`: the window is w0 + 24 h). Exit 0 = PASS; 1 = FAIL, incomplete, or not a 24-hour window; 2 = input error (fix `gaps.csv`) |
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
| §6 "Release D lag criteria" / §6 D | Lag L0–L5 (formal since 2026-10-25); routing durations | P11 + `p11_lag_acceptance.py` (exit 0 required); durations from P11 `duration_s`. The acceptance SQL's lag snapshot is information only |
| D record | No 5-minute energy window missing devices outside source gaps | acceptance SQL F (listing) |
| §6 D | No 40P01 | acceptance SQL B |

## Cost on production

P11: one catalog query every 30 s (job stats + `pipeline_state`), 10 s
statement timeout. Acceptance SQL: bounded scans of the window on
`demand_intervals`, `raw_messages`, `energy_measurements`,
`energy_consumption_1min` (2 s total on staging; the 2026-10-25 production run
of the older script took a few seconds). Baseline: catalog only.
