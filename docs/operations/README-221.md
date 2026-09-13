# Migration 221 — Staging Validation Gate

## Status

**A third real authorized `--execute` attempt (2026-08-30) completed with an
overall PASS verdict** (per the `.sql`'s own PHASE 9 logic) **and confirmed,
independently-verified restoration.** See "Third execute attempt: PASS" near
the end of this document for the full result, including the specific,
important limitation that this PASS covers non-corruption and the measured
bounded-window/EXPLAIN evidence, but did **not** exercise migration 221's
changed join against fresh driving rows in this particular window (zero
pre-existing `SELECTED`/`FAILED` samples going in). Two earlier attempts did
not pass: the first failed at PHASE 0, the second hit a genuine PHASE 7
equivalence FAIL and a separate restoration-path defect (both diagnosed and
fixed before the third attempt — see "PHASE 7 equivalence: confirmed root
cause" and "Gate restoration: confirmed root cause" below). This document,
`scripts/test/assert_normalization_221_staging_gate.sql`, and
`scripts/test/assert_normalization_221_staging_gate.sh` describe an
operational gate for **explicitly authorized** staging execution — originally
drafted for a future run, now also the record of the three real runs that
have since taken place (see "Third execute attempt: PASS" below for the
passing one). This document has now been through several passes on top of
the original draft:
a critical design/review pass (2026-08-30, second session — repository
inspection only, no database connection, no mutation); a read-only
staging-transport probe (2026-08-30, third session — one authorized SSH
connection running only `echo`/`id`/`docker compose version`/`docker
ps`/`ls`/`docker compose ps`, no PostgreSQL connection, no `psql`, no Job
1000 interaction, no gate execution, no mutation of any kind); a real,
authorized `--execute` attempt (2026-08-30, fourth session) that paused Job
1000, then failed at PHASE 0 with `ERROR: syntax error at or near ":"` before
any `CALL` or watermark move — see "Incident: first authorized `--execute`
attempt failed at PHASE 0" below for the full account, including the manual
Job 1000 restoration that followed; and a fifth session (this one) that
root-caused and fixed that failure, purely by inspecting and correcting these
three files, with no staging or production connection of any kind — see
"psql variable interpolation inside DO blocks (2026-08-30 fix)" below. No
session has staged, committed, pushed, or opened a PR for any of this; see
"Review history" for exactly what each pass changed. This gate is
deliberately **not** wired into `scripts/test/run_integration_environment.sh`
— that runner is the disposable, local, per-PR CI database; this gate
targets the persistent staging `ems` database and pauses a live TimescaleDB
background job, which `run_integration_environment.sh` must never do.

### Incident: first authorized `--execute` attempt failed at PHASE 0

On 2026-08-30 (fourth session), an operator ran the `.sh` with `--execute`
under full authorization. The `.sh`'s `capture_job_config()` and
`pause_job1000()` succeeded and Job 1000 was paused, but the main gate
invocation (the `.sql`, via `remote_psql -f -`) failed immediately at PHASE
0 with `psql: ERROR: syntax error at or near ":"`. No `CALL` was issued and
`telemetry.pipeline_state` was never touched — the failure occurred before
PHASE 2/6/7 could run. The `.sh`'s own `restore_state()` trap then attempted
to restore Job 1000, but **that restoration also failed**, for the identical
underlying reason (at the time, `restore_state()`'s `alter_job()` call also
depended on the belief that any `-v`-supplied value would substitute
correctly inside the SQL psql was given — see the root-cause explanation
below for why that belief was wrong specifically for DO blocks, though in
`restore_state()`'s actual case the SQL is a plain top-level `SELECT
alter_job(...)`, so it was not itself broken by this bug; the immediate
practical failure was that the gate connection had already aborted at PHASE
0, and the operator's first restoration attempt via the gate's own tooling
did not confirm success cleanly). Job 1000 was subsequently **restored
manually** by the operator, using the exact captured six-field configuration
already printed to the terminal/evidence file before the pause, and that
restoration was **independently verified** against the original
configuration. Production was never touched at any point. Job 1000 has
since resumed its normal schedule and `telemetry.pipeline_state` has
advanced naturally. This document does not, and must not, describe this
attempt as a pass — it was a failed PHASE 0 STOP, full stop.

### Confirmed environment (quick reference)

The values below are **confirmed for this operator's own environment** as
of the 2026-08-30 read-only probe (see "Staging transport (S-1)" further
down for the full detail and its explicit limits — in particular, this does
**not** establish anything about a different operator/machine, and does
**not** confirm any relationship to CI/CD's own `STAGING_*` identity):

| Variable | Confirmed value for this operator | Still required explicitly? |
|---|---|---|
| `EMS_STAGING_SSH_HOST` | this operator's `ems-staging` SSH alias | Yes — never hard-coded |
| `EMS_STAGING_SSH_USER` | `emsadmin` | Yes — never hard-coded |
| `EMS_STAGING_PROJECT_PATH` | `/opt/ems-platform` | Yes — never hard-coded (this value is a deployment-wide fact, not operator-specific, but the `.sh` still requires it to be set explicitly) |
| `EMS_STAGING_DB_CONTAINER` | `timescaledb` (Compose *service* name; matches the `.sh`'s existing default) | No — already the default |
| Remote login shell | `/bin/bash` | N/A — informational; makes `remote_psql()`'s `printf %q` quoting safe |
| Docker access | direct, via `docker` group, no `sudo` | N/A — informational |

**Still unresolved / not established by this probe** — all of the following
remain exactly as open as before and are detailed in their own sections
below: no numeric performance threshold exists; staging mutation still
requires explicit `--execute` + `--i-authorize-staging-mutation` +
authorization env vars; Job 1000 must still be paused for the controlled
measurement, with unconditional, verified restoration; the fixed historical
window still requires separate reconnaissance/selection; the ≥3-cycle
post-resume observation is still separate from this gate; the full
SSH→`docker compose exec`→`psql -v` chain with real values is still
unverified (the probe ran no database command).

**Distinguishing the three activities this document touches, since they are
easy to conflate:** (1) **review/design** — inspecting and correcting these
three files against the repository, as this document itself now records,
performed with no staging/production access at all; (2) **authorized
staging execution** — an actual `--execute` run of the `.sh`, gated by the
authorization checks described below, which is the only activity that
mutates staging; (3) **post-resume Job 1000 observation** — a separate,
later, explicitly authorized activity (see its own section near the end)
that watches Job 1000 run unattended on its normal schedule after this gate
and any resume decision, which this gate does not perform and does not
substitute for.

As of this draft, `docs/platform-manual/25-change-history.md`'s migration-221
entry records **"Outcome: Implemented; awaiting local + staging validation
and review."** — i.e. migration 221 has not yet been promoted to staging via
the normal CI/CD path (`staging`-branch push → `deploy-staging.yml` →
`scripts/apply_migrations.sh`). This gate's PHASE 0/1a *require* that
promotion to have already happened; it does not perform it.

## Purpose

Migration 221 (`postgres/migrations/221_normalization_selected_elements_pk_join.sql`)
changes one join inside `telemetry.load_normalized_points_incremental()`'s
`selected_elements` CTE: `telemetry.raw_messages` is now accessed on its full
primary key `(received_at, id)` plus the loader's own
`(v_window_start, v_window_end]` window, instead of on `id` alone. The
migration's own header documents staging `EXPLAIN (ANALYZE, BUFFERS)`
evidence of a ~20x plan-shape improvement (16,013 ms → 810 ms, Parallel Hash
Join over a full `Parallel Append` → Nested Loop with chunk exclusion) on a
sample 20-minute bucket window, and an argument for row-level equivalence.
That evidence predates this gate and was gathered ad hoc during incident
forensics. This gate exists to:

1. Confirm, mechanically and against the live catalog, that the *deployed*
   procedure body on staging actually carries the migration's join predicate
   and every invariant it claims not to have touched (advisory lock,
   `pipeline_state` handling, the migration-205 bound, the migration-212
   wrapper contract).
2. Produce **measured evidence** — not a single ad hoc `EXPLAIN` — for the
   four bounded windows the codebase actually supports (`p_max_window` =
   1m / 5m / 15m / 2h), including the 2h value that is Job 1000's live
   `config.max_window` (migration 212's provisional default).
3. Prove, over a fixed historical window, that a re-normalization run is
   idempotent/equivalent under the changed join — without creating any
   permanent "twin" probe function in the schema.
4. Do all of the above with a documented, reversible mutation footprint, and
   an explicit authorization gate in front of anything that touches staging
   state.

This gate does **not** decide a numeric performance acceptance threshold.
None exists in the repository today (the migration-212 2-hour default is
documented there as "provisional pending a staging job-1000 runtime
measurement"). This gate's first authorized run **establishes** that
measurement as evidence; any numeric production-promotion threshold is a
**separate, later review**, informed by but not decided by this gate.

## Files

| File | Scope |
|---|---|
| `scripts/test/assert_normalization_221_staging_gate.sql` | The gate itself: read-only preflight, capture-for-restoration, reconnaissance re-validation, `EXPLAIN` plan probe, bounded-window timing runs, fixed-window equivalence, restoration, verdict printout. Invoked only via the `.sh`. |
| `scripts/test/assert_normalization_221_staging_gate.sh` | The only script that resolves the staging target, enforces authorization, captures/pauses/resumes Job 1000, and holds the durable (non-temp-table) restoration state. |
| `docs/operations/README-221.md` | This document. |

## Staging-only safety model

Defense in depth, each layer independent of the others:

1. **This script never reads a `PRODUCTION_*` value.** The `.sh` reads only
   `EMS_STAGING_*` environment variables (see below) — there is no code path
   in either file that can resolve a production host, credential, or secret.
2. **Name-pattern refusal.** The `.sh` lower-cases and pattern-matches every
   resolved target value (host, user, project path, DB name) against
   `*prod*`/`*production*` and refuses to proceed on a match.
3. **In-database identity check.** PHASE 0 of the `.sql` refuses to run
   unless `current_database() = 'ems'` **and** the operator-supplied psql
   variable `:env_confirm = 'staging'` — both must be true, checked inside
   the actual database connection, not just by the wrapper.
4. **Explicit, layered authorization for mutation.** Preflight (no mutation)
   requires no special authorization beyond the staging-target checks above.
   The mutating path (`--execute`) additionally requires:
   - `--i-authorize-staging-mutation` (a second, explicit CLI confirmation,
     separate from `--execute` itself), and
   - `EMS_GATE_AUTHORIZED_BY` and `EMS_GATE_AUTHORIZATION_REF` set in the
     environment (operator identity and an approval reference — a ticket,
     PR, or review link). This script does not invent or default either
     value; it fails closed if either is unset.
5. **No credentials in either artifact.** Both files read connection/target
   details exclusively from environment variables the operator supplies at
   run time; nothing is hard-coded, and nothing is echoed to the evidence
   file except the target host/user/path/DB name and the authorization
   metadata above (never a password or key).
6. **`ON_ERROR_STOP` throughout.** Any unexpected condition — a STOP in
   preflight, a `SKIPPED_LOCKED` result, a failed assertion — aborts the
   `.sql` immediately rather than continuing into a mutating phase on a
   false assumption.

### Staging transport (S-1) — confirmed for this operator, 2026-08-30

**S-1 is resolved for this operator's own environment.** One explicitly
authorized, read-only SSH probe (no PostgreSQL connection, no `psql`, no
database inspection, no Job 1000 interaction, no gate execution, no
mutation of any kind) established:

| Fact | Confirmed value |
|---|---|
| SSH alias (this operator's local `~/.ssh/config`) | `ems-staging` |
| Remote user | `emsadmin` |
| Remote login shell | `/bin/bash` (from `$SHELL`) |
| Docker access | Direct, via `docker` group membership (`groups=...,988(docker)`) — **no `sudo` required** |
| Docker Compose version | `v5.5.0` |
| Staging project path | `/opt/ems-platform` — confirmed to contain this repository's checkout (`.git`, `compose.yaml`) and to be the live deployment |
| Database Compose *service* name | `timescaledb` (the running container is named `ems-timescaledb`; `docker compose exec` addresses it by service name, which matches this script's `EMS_STAGING_DB_CONTAINER` default) |
| Deployment identity | `docker compose ps` at that path listed all five expected services healthy, with `ems-admin-portal`/`ems-live-telemetry` running image tag `...:2c90645ae64abc48a0630722697e4660cff7a9da` — the exact commit this worktree is detached at |

This also resolves the `printf %q` remote-command-construction concern the
`.sh`'s `remote_psql()` comment used to flag: bash-flavored `%q` quoting is
safe here because the confirmed remote login shell is bash, not a POSIX
`sh`/dash variant that would misinterpret it.

**What this does NOT establish** (do not over-read the above):
- It does **not** prove anything about a **different operator**, a
  **different machine**, or a **different SSH key/account** — another
  person running this gate still needs their own working
  `EMS_STAGING_SSH_HOST` / `EMS_STAGING_SSH_USER`, and the `.sh` still
  refuses to run with either unset (no host/user is ever hard-coded).
- It does **not** establish that `emsadmin` is the same identity CI/CD's
  `STAGING_HOST` / `STAGING_USER` / `STAGING_SSH_KEY` / `STAGING_PROJECT_PATH`
  secrets (`.github/workflows/deploy-staging.yml`'s `appleboy/ssh-action`
  step, named in `docs/operations/CICD_PIPELINE.md`) resolve to. That
  remains genuinely unknown — a secondary local alias, `ems-staging-ubuntu`
  (same host, `User ubuntu`), also exists, and some files under
  `/opt/ems-platform` are owned by `ubuntu` rather than `emsadmin`,
  suggesting CI may deploy as a *different* account than this operator's
  interactive one. This is **irrelevant to this operator-run gate** (which
  never reads any CI secret), but it means "the transport works for
  `emsadmin`" must not be read as "this is how CI/CD accesses staging."
- It does **not** prove the full multi-hop chain all the way through a real
  `docker compose exec -T timescaledb psql -v ...` invocation — the probe
  deliberately ran no database command. **Before the first authorized
  `--execute` run, still smoke-test** with a trivial `SELECT 1;` and one
  interval-valued `-v` to confirm no value is mangled in transit through
  `psql` itself.
- It does not establish a numeric performance threshold, does not confirm
  the historical reconnaissance window, and does not change any of the
  authorization/restoration requirements below — see those sections.

**Update (2026-08-30, fifth session):** the multi-hop chain bullet above is
now **substantially de-risked**, though not by re-running against staging.
The fourth session's real `--execute` attempt independently confirmed that
`-v name=value` arguments **do** arrive at psql correctly through this exact
chain (the failure it hit was downstream of that, inside psql/PostgreSQL
itself — see the next section). This session additionally re-simulated the
full `ssh -> bash -c -> docker compose exec -> psql` chain locally (stand-in
`ssh`/`docker` executables that mimic real `bash -c "<remote_cmd>"` parsing
and `docker compose exec`'s plain-argv passthrough) and confirmed every `-v`
pair the `.sh` sends is delivered as the correct, separate `psql` argv
tokens, with no mangling. The one part of this bullet still genuinely
untested is a **live** run over a **real** SSH connection to the **real**
staging host — the local simulation and the fourth session's failed attempt
both used the real transport shape, but only the fourth session actually
went over the wire, and it never reached a point where non-`-v` behavior
(e.g. real network latency, real `docker compose` version quirks) could be
observed beyond PHASE 0.

## psql variable interpolation inside DO blocks (2026-08-30 fix)

**Root cause of the PHASE 0 failure above.** psql's own colon-substitution
scanner (the mechanism behind `-v name=value`, `\set`, and `:name`/`:'name'`
references) never looks inside a dollar-quoted string. Every
`DO $tag$ ... $tag$;` block in `assert_normalization_221_staging_gate.sql`
that referenced an operator-supplied value via `:'name'` did so **from
inside** that block's dollar-quoted body — so psql passed those references
through completely literally, and PostgreSQL's own parser then rejected them
with `ERROR: syntax error at or near ":"` the moment it tried to parse the
DO block's body as PL/pgSQL. PHASE 0 is entirely one such DO block
(`DO $phase0$ ... IF :'env_confirm' <> 'staging' ... $phase0$;`), so it
failed immediately, before doing anything else.

This is **not** a transport bug: the `-v env_confirm=staging` argument was
(and always was) received correctly by psql, confirmed independently by (a)
the fourth session's real staging failure, whose evidence showed the `-v`
flags present in the constructed remote command, and (b) this session's own
local reproduction below. The bug is specifically that **referencing a
`-v`-supplied value from *inside* a dollar-quoted PL/pgSQL body does not
work in psql**, regardless of how correctly that value reached psql's
command line.

**Local reproduction** (this session, no staging/production connection):
against a disposable local TimescaleDB container already running for other
test purposes (`ems-timescaledb-test`, matching the pattern
`scripts/test/run_integration_environment.sh` already uses),

```
docker exec -i ems-timescaledb-test psql -X -v ON_ERROR_STOP=1 -U ems_admin -d ems_test \
    -v env_confirm=staging -f - <<'SQL'
DO $probe$
BEGIN
    IF :'env_confirm' <> 'staging' THEN
        RAISE EXCEPTION 'nope %', :'env_confirm';
    END IF;
END;
$probe$;
SQL
```

reliably reproduces `psql:<stdin>:2: ERROR: syntax error at or near ":"`,
while the same `-v env_confirm=staging` reference at the top level (e.g.
`SELECT :'env_confirm';`, outside any DO block) substitutes correctly. This
isolates the failure precisely to "inside a dollar-quoted DO/function body,"
not to `-v` delivery, quoting through SSH, or `docker compose exec` argv
handling.

**Fix.** Every value a DO block needs is now bridged into a session GUC via
`set_config('gate.<name>', :'<name>', false)`, called from **top-level** SQL
(a plain `SELECT`, not inside any DO block or dollar-quoting), where `:'name'`
substitution works normally and was never in question. Every DO block then
reads the value back with `current_setting('gate.<name>')` — ordinary
PL/pgSQL, with no psql-level substitution involved at all. This is applied
consistently to: the `.sh`-supplied `env_confirm`, `expected_221_sha256`,
`deploy_221_after`, `hist_start`, `hist_end`, `hist_window_minutes`,
`recon_overlap_secs`, `baseline_mode`, and `rewind_interval` (bridged once,
near the top of the file, in a new "PHASE 0-pre" block, before PHASE 0
itself needs `gate.env_confirm`); and to the `\gset`-produced
`restore_last_received_at` (PHASE 2), `driving_rows_in_band` (PHASE 4), and
`ref_digest`/`post_digest` (PHASE 7), each bridged immediately after its own
`\gset`, since those are also read back from inside a later DO block. Values
used **only** in plain top-level SQL (every `SELECT`/`UPDATE`/`CALL`/
`EXPLAIN` statement not inside a DO block) or in psql meta-commands
(`\if`, `\set`) were confirmed unaffected and were **not** changed — they
never had this problem, and changing them would have been an unnecessary,
unrelated edit. `gate_execute` and `probe_idonly_contrast` fall in this
category (used only by `\if`, never referenced from inside a DO block) and
so needed no bridging.

This fix touches **only** how values are delivered into DO block bodies. It
does not change: what PHASE 0–8 check, `ON_ERROR_STOP` semantics, the
staging-only identity checks, the authorization gates, the bounded-window
assertions, the equivalence acceptance criteria, or the restoration
mechanism. `scripts/test/assert_normalization_221_staging_gate.sh`'s own
restoration calls (`restore_state()`'s `alter_job(...)` and
`UPDATE telemetry.pipeline_state ...`, both issued via `-c` with plain
top-level SQL and no dollar-quoting) were **never affected by this bug** and
needed no change — confirmed by the same root-cause analysis and by this
session's reproduction of correct top-level substitution.

**Local validation performed (this session, no staging/production
connection):**
1. Re-simulated the `.sh`'s full `remote_psql()` chain locally with stand-in
   `ssh`/`docker` executables (real `bash -c` parsing a `%q`-escaped remote
   command string, then a shim that reports the exact `argv` a real `docker
   compose exec ... psql` would receive) — confirmed every `-v` pair and the
   piped-in SQL script arrive intact, matching the fourth session's own
   observation that `-v` delivery was never the problem.
2. Ran the **corrected** `.sql`, in dry-run mode (`gate_execute=off`), via
   `docker exec -i` against the disposable local `ems-timescaledb-test`
   container: PHASE 0 now evaluates correctly instead of syntax-erroring —
   first confirmed against a database not named `ems` (correctly produced
   the expected `PHASE 0 STOP: current_database()=ems_test`), then against a
   disposable local database created and dropped solely for this test and
   named `ems` (correctly produced `PHASE 0 ok: database=ems,
   env_confirm=staging.` and proceeded to PHASE 1a, which then failed for
   the expected, unrelated reason — `admin.schema_migrations` does not exist
   in that bare container, since it carries no EMS schema).
3. `bash -n scripts/test/assert_normalization_221_staging_gate.sh` — no
   syntax errors.

None of this connected to staging or production, issued `--execute`, called
`alter_job`, or called `telemetry.load_normalized_points_incremental`. It
demonstrates the DO-block substitution mechanism is now correct; it is
**not** a substitute for a real, separately authorized staging run of the
full gate, which is still required before this document can describe any
PASS.

## Second incident: real `--execute` run reached PHASE 7 and failed; restoration also failed

With the PHASE 0 DO-block fix in place, a second real, authorized `--execute`
run (2026-08-30) got much further: preflight, reconnaissance, the PHASE 5
EXPLAIN probe, and all four PHASE 6 bounded-window CALLs (1m/5m/15m/2h)
passed. PHASE 7's fixed historical-window equivalence CALL then ran and its
digest check **genuinely failed** (`ref=b26ca269...`, `post=41165db1...`).
Immediately afterward, the `.sh`'s own `restore_state()` trap **also
failed**, on both its `alter_job()` call and its `pipeline_state` UPDATE,
each with `ERROR: syntax error at or near ":"`. Job 1000 and
`pipeline_state` were restored **manually**, using the values already
captured and printed before the pause, and independently verified against
that captured baseline. No production access occurred. A follow-up,
strictly read-only investigation (staging connection for `SELECT`s only; no
mutation) then root-caused both failures, summarized below; a further
session applied and locally validated the fixes.

### Gate restoration: confirmed root cause

`psql -c "<SQL>"` **never performs `:name`/`:'name'` variable substitution,
at all** — regardless of quoting or line count. This is a distinct psql
behavior from the dollar-quoted-DO-block issue fixed earlier: `-c` bypasses
psql's substitution scanner entirely, for any SQL, not just inside `$$...$$`.
Confirmed by direct local reproduction against a disposable Postgres
instance:

```
psql -v x=hello -c "SELECT :'x';"          → ERROR: syntax error at or near ":"
psql -v x=42    -c "SELECT :x;"            → ERROR: syntax error at or near ":"
psql -v x=hello -f - <<< "SELECT :'x';"    → hello   (works)
```

The full SSH → `bash -c` → `docker compose exec` → `psql` transport chain
was independently re-traced (a real `bash -c` fed the exact reconstructed
`remote_cmd` string, with a fake `docker` shim reporting the argv a real
`docker compose exec ... psql` would receive) and confirmed to deliver the
`-c` argument to psql **completely intact**, including every `:'var'`
reference — so this was never a transport, quoting, or SSH-hop problem, only
the wrong psql invocation mode for SQL that needs psql-side substitution.
`restore_state()`'s two calls (`alter_job(...)` and the `pipeline_state`
UPDATE) both used `-c` with `:'var'` references and so both failed
identically; every other `-c` call site in the `.sh`
(`pause_job1000`, `capture_job_config`, `capture_pipeline_state`, and the
restoration-verification read) interpolates values via bash
(`${VAR}`/`'${FS}'`) rather than psql's `:'var'`, which is exactly why those
five call sites worked correctly on both real runs.

**Fix applied (2026-08-30):** both `restore_state()` calls now pipe their SQL
via `-f -` (stdin heredoc) instead of passing it as a `-c` argument —
matching the mechanism already proven correct for the main gate invocation
and for the manual emergency restoration. No other change to restoration
logic, captured values, ordering, or failure handling. Locally validated:
the real `remote_psql()` function (extracted verbatim from the fixed `.sh`)
was run through a re-simulated SSH → `bash -c` → `docker compose exec`
chain into a real disposable local Postgres instance for both the
`alter_job`-shaped call and the `pipeline_state` UPDATE-shaped call (the
latter inside a rolled-back transaction); both correctly substituted every
value and matched the exact baseline used in the real incident.

### PHASE 7 equivalence: confirmed finding

The digest change was **not** demonstrated corruption. Read-only evidence
from staging (state independently restored beforehand; no mutation was
performed for this investigation):

- `normalized_points` rows in the exact digest predicate band:
  `189428` (reference) → `191864` (current) — **+2436 rows**, not a value
  mutation on existing keys.
- `capture_bucket_samples` rows in the band with `normalized_at` inside the
  equivalence CALL's own execution window: **43 rows**, all for a single
  device, all `status = NORMALIZED`, `raw_received_at` genuinely inside the
  window.
- `capture_bucket_samples` count for the band: `3268` (pre-CALL) → `3311`
  (current) — the same **+43**.
- 2436 / 43 ≈ 56.7 points/bucket — consistent with one device's normal
  per-sample field count.

Mechanism, read from the deployed loader body (`pg_get_functiondef`, fetched
read-only): every call independently rebuilds candidate `(site, bucket_start,
device)` buckets from raw data joined against **current** metadata, and
inserts any bucket not already in `capture_bucket_samples` as a fresh
`'SELECTED'` row (`ON CONFLICT DO NOTHING`), then normalizes it in the same
transaction. This candidate-discovery step is separate from, and unaffected
by, migration 221's change (which only touched the
`selected_elements ↔ raw_messages` join, downstream of candidate discovery).
**"Zero pre-existing SELECTED/FAILED driving rows" (PHASE 4's
`EQUIVALENCE_LIMITATION_ZERO_DRIVING_ROWS`) does not imply the loader will be
a no-op** — the loader can still discover and normalize previously-uncaptured
buckets regardless of that count. Why this device's 43 buckets had never been
captured before this run was not investigated (out of scope for this fix;
the mechanism, not the specific history, was what needed root-causing).

**Neither finding implicates migration 221.** The restoration failure is a
pure gate-tooling defect. The equivalence finding is additive growth from a
code path 221 didn't touch, not a join defect.

### Methodology correction (2026-08-30 fix)

PHASE 7's `$chk_equiv$` check previously aborted immediately on any digest
mismatch, before computing its own `v_added`/`v_removed`/`v_val_changed`
breakdown — so it could never distinguish additive growth from real
corruption. It now:

- Computes `v_added` (existing-key), `v_removed`, `v_val_changed`,
  `v_pra_regress`, `v_cbs_changed` exactly as before (all four
  correctness checks are unchanged in what they detect).
- Treats **removed keys** and **existing-key value mutation** (present in
  both snapshots) as hard failures, same as before.
- Treats **additive key growth** (present now, absent from the reference) as
  **expected, not a failure** — reported via a `EQUIVALENCE_ADDITIVE_KEY_GROWTH`
  warning and a `NOTICE`, never a `RAISE EXCEPTION`.
- Keeps the digest as a defensive cross-check, evaluated *after* the
  breakdown: a mismatch is only a failure if it is *unexplained* by
  added/removed/changed all being zero (mathematically that combination
  should not produce a differing digest; if it ever does, that is still
  treated as a correctness failure, not silently trusted away).
- PHASE 4's `EQUIVALENCE_LIMITATION_ZERO_DRIVING_ROWS` message text was
  corrected to state plainly that zero pre-existing driving rows does not
  predict a no-op call (see above); the marker string itself is unchanged so
  the `.sh`'s existing grep-based verdict logic still finds it.

Locally validated against a disposable database (four scenarios, each in a
rolled-back transaction, using the exact corrected DO block text extracted
from the file): identical reference/post sets → PASS (no warning); additive
keys only → PASS with `EQUIVALENCE_ADDITIVE_KEY_GROWTH` reported; changed
value on an existing key → FAIL; removed key → FAIL. An initial version of
this fix had a logic bug (the defensive digest cross-check didn't account
for `v_added`, so pure additive growth was misclassified as an unexplained
failure) — caught by the additive-only test scenario and corrected before
being considered done.

**Update: a third `--execute` run, with both fixes applied, has since been
performed and passed — see "Third execute attempt: PASS" below.**

## Third execute attempt: PASS (2026-08-30)

A real, authorized `--execute` run, with both fixes above applied, completed
the full gate against staging with an overall **PASS** verdict per the
`.sql`'s own PHASE 9 logic, and restoration was completed automatically by
the `.sh`'s fixed `restore_state()` trap (`RESTORE_OK`) and then
independently re-verified with a separate read-only query against staging.

**Preflight/reconnaissance:** PHASE 0 through PHASE 4 all passed cleanly,
including the checksum check (git-HEAD-blob based) and the PHASE 1b
identity-arguments check (IN-prefix normalized) — both real fixes from the
prior read-only investigation, exercised live for the first time here.

**PHASE 5 (EXPLAIN plan probe):** Nested Loop over an Index Scan on
`capture_bucket_samples` joined to a `Custom Scan (ChunkAppend)` on
`raw_messages` with `Chunks excluded during startup: 0` — the plan shape
migration 221 is meant to produce (chunk exclusion / nested loop, not a full
`Parallel Append`/`Hash Join`). Execution Time 0.166 ms (0 driving rows this
run, so the raw_messages side was `never executed`).

**PHASE 6 bounded windows (all `SUCCESS`, `baseline_mode=as_is`):**

| Window | server_duration_ms | rows | watermark advanced to |
|---|---|---|---|
| 1m | 880.9 | 2726 | 2026-08-30 14:28:26.87+05:30 |
| 5m | 548.0 | 0 | 2026-08-30 14:28:26.87+05:30 |
| 15m | 469.3 | 0 | 2026-08-30 14:28:26.87+05:30 |
| 2h | 525.3 | 0 | 2026-08-30 14:28:26.87+05:30 |

All four collapsed to the same watermark (checkpoint was already near
`max(raw_messages.received_at)`), so this measures real steady-state
per-invocation cost, not window-scaled cost — consistent with migration
221's own premise that runtime should not scale with `p_max_window`. The 2h
run (525 ms) is far below Job 1000's 300,000 ms `max_runtime`; no
near-`max_runtime` warning fired. No numeric pass/fail threshold is applied
to any of this — it is evidence, per the gate's existing design.

**PHASE 7 equivalence: full PASS, digest matched exactly**
(`ref_digest = post_digest = 41165db13b34e8cec5704c18d3a8e5eb`, both over
191,864 rows). Explicitly, per the corrected methodology: **0 additive key
growth, 0 removed keys, 0 changed values on existing keys, no unexplained
digest mismatch.** This is a materially different (and stronger) result than
the second attempt's real FAIL on the same window (`ref=b26ca269...` →
`post=41165db1...`) — because that second attempt's own equivalence CALL
already discovered and normalized the 43 previously-uncaptured buckets
identified in the prior investigation, this window is now genuinely settled,
and re-running over it a further time is a true no-op. This third run is
therefore consistent with, not contradictory to, the earlier diagnosis.
`EQUIVALENCE_LIMITATION_ZERO_DRIVING_ROWS` still fired (0 pre-existing
`SELECTED`/`FAILED` rows going into this run too) — so, per that limitation:
this PASS is for **non-corruption**; it did **not** exercise migration 221's
changed `selected_elements ↔ raw_messages` join against fresh driving rows
in *this* run. Join-correctness rests on PHASE 5's EXPLAIN evidence for this
specific run, as the gate's own design has always stated for this case.

**Restoration:** automatic and successful. `alter_job()` and the
`pipeline_state` `UPDATE` both completed via the fixed `-f -` mechanism with
no error; the `.sh` reported `RESTORE_OK`. Independently re-verified with a
separate read-only query immediately after: `telemetry.pipeline_state`
(`normalized_points` row, exactly 1 row) matches the captured baseline on
all 7 fields (`last_received_at`, `last_started_at`, `last_completed_at`,
`last_inserted_rows=2726`, `last_status=SUCCESS`, `last_error=NULL`,
`updated_at`); Job 1000 matches the captured baseline on all 6 fields
(`scheduled=true`, `schedule_interval=00:01:00`, `max_runtime=00:05:00`,
`max_retries=3`, `retry_period=00:01:00`,
`config={"overlap": "15 minutes", "max_window": "2 hours"}`). No anomalies
or blockers were observed in this run.

**What this does and does not establish:** migration 221's deployed body
carries the intended contract (PHASE 1c), its plan shape matches the
intended chunk-exclusion improvement (PHASE 5), it does not corrupt existing
data over a re-run of this specific historical window (PHASE 7), and it does
not regress bounded-window catch-up behavior (PHASE 6). It does **not**,
from this run alone, prove the changed join is correct against a batch of
genuinely fresh `SELECTED`/`FAILED` rows — no run so far has had a nonzero
pre-existing driving-row count in the chosen window. That remains a gap
specific to reconnaissance-window selection, not to the gate's mechanism,
and is a separate, later decision from this validation.

## Preflight (PHASE 0–1, read-only, always runs)

Runs identically in dry-run and `--execute` mode. Any failure here is a
hard `STOP` — a genuine mid-flight abort, not a soft warning.

- **PHASE 0** — `current_database() = 'ems'` and `:env_confirm = 'staging'`.
- **PHASE 1a** — `admin.schema_migrations` records migrations
  `218_recovery_onboarding_aware_deferral`,
  `219_airsense_environmental_sensor_compatibility`,
  `220_recovery_supersession_interval_predicate`,
  `221_normalization_selected_elements_pk_join`, and
  `222_recover_failed_raw_messages_comment_restore` — and the deployed 221's
  `checksum_sha256` matches a SHA-256 the `.sh` computes **locally from this
  checkout's own file**, never supplied by the operator (mirrors
  `scripts/apply_migrations.sh`'s own checksum discipline).
- **PHASE 1b** — exactly one `telemetry.load_normalized_points_incremental`
  overload exists (`interval, interval`); no leftover single-argument
  overload from before migration 205.
- **PHASE 1c** — `pg_get_functiondef()` on the live catalog is pattern-
  matched against the exact join predicate migration 221 introduces, the
  migration-205 bound, the advisory-lock/`SKIPPED_LOCKED`/`FAILED`/
  `EXCEPTION` invariants, and the migration-212 wrapper's two-argument call
  and `config->>'max_window'` read. This is a read-only equivalent of what
  `scripts/test/assert_normalization_bounded_catchup_window.sql`'s TEST D/J/M
  already assert against a local disposable database.
- **PHASE 1d** — `pg_stat_user_tables` must show `last_analyze` or
  `last_autoanalyze` on `telemetry.capture_bucket_samples` at or after
  `--deploy-221-after`. **If absent, the gate STOPS. It does not run
  `ANALYZE` itself** (approved decision 9) — a missing precondition here
  means investigate why 221's own `ANALYZE telemetry.capture_bucket_samples`
  statement is not reflected, not paper over it.
- **PHASE 1e** — the `normalized_points` row in `telemetry.pipeline_state`
  exists and is not `RUNNING`.
- **PHASE 1f** — no other session is currently executing
  `load_normalized_points_incremental` or `run_normalization_job`.

## Reconnaissance for selecting the historical window

**This gate does not choose the fixed historical window.** Per approved
decision 6, that requires a separate, prior, read-only reconnaissance step,
reviewed by a human before it is fed into this gate. The reconnaissance
output the operator must supply (as `.sh` flags) is:

- `--hist-start`, `--hist-end` — the historical band's bounds. `PHASE 4`
  re-validates, at gate time, that: the whole minute-count matches
  `--recon-overlap-secs`'s companion `hist_window_minutes` internally
  derived from the two timestamps; `hist_end` is strictly behind the current
  `normalized_points` checkpoint (so the run cannot advance into unprocessed
  data); the band (minus the overlap pad) sits comfortably inside
  `telemetry.raw_messages`'s live retention window (read from
  `_timescaledb_functions.policy_retention`'s `config->>'drop_after'` —
  never hard-coded, the same pattern migrations 206/218/220 already use);
  and the band actually contains raw rows.
- `--recon-overlap-secs` — the `v_dynamic_overlap` the loader would compute
  for this window (from `config.telemetry_capture_policies`), needed because
  PHASE 4/7 read `capture_bucket_samples`/`raw_messages` over
  `(hist_start - overlap, hist_end]`, the same band the loader itself would
  scan.
- `--deploy-221-after` — used by PHASE 1d above.

**How to gather these** (read-only, run manually against staging before
scheduling any `--execute` run — not automated by this gate, per approved
decision 6):
1. Read `telemetry.pipeline_state.last_received_at` for the current
   `normalized_points` checkpoint.
2. Read `telemetry.raw_messages`'s retention (`_timescaledb_functions.policy_retention`
   as above) and `max(received_at)`.
3. Pick a band strictly behind the checkpoint, comfortably inside retention,
   with a non-trivial population of `telemetry.capture_bucket_samples` rows
   (ideally including some in `'SELECTED'`/`'FAILED'` status — see the
   equivalence limitation below).
4. Have a second person review the chosen band before it is used with
   `--execute`.

### OPEN DESIGN QUESTION E-2 — an all-`NORMALIZED` band under-tests the join

If every `capture_bucket_samples` row in the chosen band is already
`'NORMALIZED'`/`'RECOVERED'`, PHASE 7's driving set
(`tmp_selected_samples`, filtered to `status IN ('SELECTED','FAILED')`) is
empty, and the equivalence phase proves only "221 introduces no spurious
writes over already-normalized history" — it does **not** exercise the
changed `selected_elements ↔ raw_messages` join against real driving rows.
When this happens, PHASE 5's `EXPLAIN (ANALYZE, BUFFERS)` probe (and, if
`--enable-idonly-contrast-probe` is set, the contrast against the pre-221
id-only join shape) becomes the *only* evidence that the changed join is
both row- and plan-correct for this run. Reconnaissance should prefer a band
with real `SELECTED`/`FAILED` population; if none is available close enough
to "now" to also satisfy the checkpoint/retention constraints above, the
run's Equivalence result is PASS (non-corruption) with this limitation
carried forward.

**This limitation is now machine-checkable, not just documented prose**
(2026-08-30 review pass): PHASE 4 counts `capture_bucket_samples` rows in
the band with `status IN ('SELECTED','FAILED')` and, when that count is
zero, emits a fixed, never-reworded marker string,
`EQUIVALENCE_LIMITATION_ZERO_DRIVING_ROWS`, as a `WARNING` (not silently, and
not just as one NOTICE among dozens). The `.sh`'s final verdict block greps
the evidence file for this exact marker and, when present, prints an
explicit note alongside its PASS/INCONCLUSIVE verdict that join-correctness
for that run rests on PHASE 5's `EXPLAIN` evidence rather than PHASE 7's
data-level diff. A reviewer reading only the `.sh`'s terminal output (not
the full evidence file) will still see this limitation called out, rather
than needing to notice its absence of population from a raw counts table.

**Reconnaissance finding (2026-08-30, read-only investigation, no
mutation): no naturally occurring window currently exists anywhere in
retained staging history.** A targeted, read-only query against the full
`telemetry.capture_bucket_samples` table (no time filter — the entire
retained history, not just a candidate band) found:

```
status | n | earliest | latest
-------+---+----------+-------
                (0 rows)
```

for `status IN ('SELECTED','FAILED')`. The full status distribution for the
same table: `NORMALIZED = 538,797` (spanning 2026-08-09 through 2026-08-30),
`RECOVERED = 444` (2026-08-25 through 2026-08-28) — **zero** `SELECTED`,
**zero** `FAILED`. Staging's normalization pipeline is currently in a fully
healthy steady state: Job 1000 processes every captured bucket to
`NORMALIZED` (or `RECOVERED`, via the migration 218/220 recovery path)
within its normal 1-minute schedule, with no backlog and no persistent
failures anywhere in the retained window. `raw_messages` retention is 48h
and compression kicks in after 1 day — neither is the limiting factor here;
the limiting factor is simply that there is currently nothing pending or
failed to find.

This is not a gate defect and not something to work around: per this
document's own standing rule (approved decision 3 and the E-2 discussion
above), the gate must never manufacture `SELECTED`/`FAILED` rows or
otherwise synthesize a driving set, and this investigation did not do so
either — it was read-only throughout. Practically, this means: **another
gate run over a freshly-chosen historical window is unlikely to newly
satisfy E-2** unless a real normalization failure or backlog occurs on
staging between now and that run — which is not something to schedule
around. The existing evidence this limitation rests on (PHASE 1c's static
contract check against the deployed procedure body, and PHASE 5's `EXPLAIN`
plan-shape probe, which validates the planner's chosen access path
independent of matching row count) is the best currently obtainable
join-correctness signal without either waiting for an organic failure/
backlog to appear or deliberately engineering one — the latter being exactly
what this document's own safety model rules out.

## Exact staging mutations and their authorization

| # | Mutation | Where | Requires | Reversal |
|---|---|---|---|---|
| 1 | Pause Job 1000 (`alter_job(..., scheduled => false)`) | `.sh`, before invoking the `.sql` with `gate_execute=on` | `--execute` + `--i-authorize-staging-mutation` + `EMS_GATE_AUTHORIZED_BY`/`EMS_GATE_AUTHORIZATION_REF` | `.sh`'s `restore_state` trap calls `alter_job()` with every captured field (`schedule_interval`, `max_runtime`, `max_retries`, `retry_period`, `scheduled`, `config`) restored verbatim, on **every** exit path (success, failure, or interrupt) |
| 2 | Transient `UPDATE telemetry.pipeline_state ... WHERE pipeline_name='normalized_points'` (moves `last_received_at` to a per-window starting checkpoint) | `.sql` PHASE 6 (once per bounded window) and PHASE 7 (once, for equivalence) | `gate_execute=on` (set only by `.sh --execute`) | `.sh`'s `restore_state` trap issues an `UPDATE` restoring every captured column (`last_received_at`, `last_started_at`, `last_completed_at`, `last_inserted_rows`, `last_status`, `last_error`, `updated_at`) from values captured **after Job 1000 is paused but before any bounded `CALL`** — independent of the `.sql`'s own PHASE 8, which may not run if an earlier phase aborted the connection (see below) |
| 3 | N bounded `CALL telemetry.load_normalized_points_incremental(INTERVAL '15 minutes', <bound>)` | `.sql` PHASE 6 (four calls: 1m/5m/15m/2h) and PHASE 7 (one equivalence call) | `gate_execute=on` | Each `CALL` is its own committed transaction (the procedure has no intermediate `COMMIT` and its `EXCEPTION WHEN OTHERS` handler marks `FAILED` then re-`RAISE`s, so a failing call rolls back its own writes) — reversed at the `pipeline_state`/watermark level by mutation #2's restoration, not by undoing individual rows |

No mutation touches `telemetry.raw_messages`, `telemetry.normalized_points`
schema, `telemetry.capture_bucket_samples` schema, any Grafana object, or
any object outside `telemetry.pipeline_state`'s one row and Job 1000's
config. **No `ANALYZE` is ever run by this gate.** No permanent database
object (function, table, view) is created — PHASE 5/7 use only session
`TEMP TABLE`s (`ON COMMIT DROP`-scoped or dropped explicitly at the top of
each phase) and `BEGIN; ... ROLLBACK;` blocks, per approved decision 3 (no
twin/probe functions).

### Why restoration lives in the `.sh`, not only in the `.sql`

An earlier draft of the `.sql`'s header claimed the `.sh` would "re-invoke
this file with a restore-only flag" if a mid-run failure occurred. That
does not work: `gate_restore_pipeline_state` and `gate_restore_job1000` are
session-scoped `TEMP TABLE`s. If `ON_ERROR_STOP` aborts the `.sql`
mid-PHASE-6/7 (e.g. a `SKIPPED_LOCKED` or a failed assertion), the psql
connection closes and both temp tables are gone **before** PHASE 8 can run
— there is nothing left to re-invoke into. The `.sh` is therefore the
**only durable source of truth for restoration**, via two functions and a
trap:

- `capture_job_config()` reads Job 1000's full config (`schedule_interval`,
  `max_runtime`, `max_retries`, `retry_period`, `scheduled`, `config`) —
  called **before** the pause, since this data has no race with Job 1000's
  own schedule (only `scheduled` is about to change, and only by this
  script's own next call).
- `pause_job1000()` then issues `alter_job(..., scheduled => false)`.
- `capture_pipeline_state()` reads the `normalized_points` row **only after**
  the pause — capturing it earlier would risk a race against Job 1000's live
  1-minute schedule (a run could land between the read and the pause and
  make the captured baseline stale). This ordering fix came out of the
  2026-08-30 review pass; the original draft captured both before pausing.
- `restore_state()`, installed as an `EXIT`/`INT`/`TERM` trap, unconditionally
  restores Job 1000 from the shell-held config whenever it was captured, and
  separately restores `telemetry.pipeline_state` whenever *that* was
  captured — the two are tracked by independent flags
  (`JOB_CAPTURED`/`PIPELINE_CAPTURED`) precisely because a failure could, in
  principle, occur between the two captures, and the trap must still be able
  to do the one restoration it has real data for. Restoration failures do
  not silently vanish: a failed `alter_job()`/`UPDATE`, or a
  post-restoration verification read that cannot reach staging at all, each
  print a distinct, `grep`-able marker
  (`RESTORE_FAILED`/`RESTORE_MISMATCH`/`RESTORE_VERIFICATION_UNREACHABLE`)
  that the `.sh`'s own final verdict checks for and treats as INCONCLUSIVE
  regardless of how the gate run itself otherwise went.

The `.sql`'s own PHASE 2/8 remain useful for in-run bookkeeping, the
evidence printout, and a same-connection sanity check on the common
(non-aborted) path, but they are not what a reviewer should rely on for
"was staging actually put back."

## 1m / 5m / 15m / 2h methodology

PHASE 6 times four bounded `CALL`s, one per supported `p_max_window` value —
**1 minute, 5 minutes, 15 minutes, and 2 hours** — with **no** fifth,
unbounded/`NULL` run (approved decisions 4 and 5: `p_max_window IS NULL` is
a real, valid default of the procedure, used by manual/unbounded catch-up
call sites like `postgres/maintenance/45_rebuild_normalized_history.sql`,
but it is explicitly out of scope for this gate). The 2-hour value is not
arbitrary — it is Job 1000's live `config.max_window` as set by migration
212, so this is also the window Job 1000 itself will actually run in
production once resumed.

Two `--baseline-mode` options, because a single mode cannot both preserve
"what Job 1000's own checkpoint would actually see" and "make all four
window sizes bind to genuinely different amounts of data":

- **`as_is`** (default) — each timed `CALL` starts from the real captured
  checkpoint. On a healthy staging instance where the checkpoint sits near
  `max(raw_messages.received_at)`, all four windows collapse to the same
  effective `v_window_end`, and the run measures the **real steady-state
  per-invocation cost** — which is the actual question migration 221
  answers (recall the root cause: runtime was *not* scaling with the
  window). This mode's finding will legitimately be "runtime does not scale
  with `p_max_window`" if 221 worked, not a bug in the measurement.
- **`rewind`** (`--rewind-interval`) — each timed `CALL` starts from
  `max(received_at) - rewind_interval`, so the four bounds genuinely
  process differently sized windows. Over already-normalized history the
  write path is a near-no-op (every row hits the `ON CONFLICT DO UPDATE`
  guard clause), so this mode characterizes the `tmp_capture_candidates` /
  `v_rtdata` scan and the (now cheap) `selected_elements` plan rather than a
  genuinely fresh backlog.

**Neither mode reproduces the original incident's heavy fresh-`SELECTED`
backlog** unless Job 1000 was paused long enough beforehand, independently
of this gate, for a real backlog to accumulate — OPEN DESIGN QUESTION,
requires review before the first `--execute` run, since deliberately
starving Job 1000 to manufacture a backlog is itself an operational decision
with its own blast radius, outside this gate's scope.

Each of the four timed runs asserts (not merely reports): `last_status =
'SUCCESS'` (a `SKIPPED_LOCKED` result means the pause did not actually take
— hard `STOP`, not skip); and the resulting `pipeline_state.last_received_at`
equals exactly `LEAST(max(received_at), checkpoint_before + p_max_window)` —
the literal migration-205 formula, not an approximation.

The 2-hour run additionally compares its measured `server_duration_ms`
against Job 1000's `max_runtime` (5 minutes / 300,000 ms): **at or over**
`max_runtime` is a `WARNING`, reported only; **within 2x** of `max_runtime`
is a `WARNING` for reviewer attention. Per approved decision 8, **neither
case changes Job 1000's configuration automatically** — a near-`max_runtime`
2-hour result is exactly the kind of finding this gate exists to surface to
a human, not to act on.

## Equivalence methodology

Per approved decision 3: **Equivalence Approach 1 only** — idempotent
re-normalization plus a diff. No twin/probe function of any kind is
created, temporarily or otherwise.

1. Snapshot `telemetry.normalized_points` over the full band the loader will
   re-touch, `(hist_start - recon_overlap_secs, hist_end]`, into a session
   `TEMP TABLE`, alongside a single `md5` content digest over that snapshot
   that **excludes** the two columns the loader's own
   `ON CONFLICT ... DO UPDATE` is allowed to legitimately bump forward
   (`platform_received_at`, `raw_message_id`).
2. Snapshot the matching `telemetry.capture_bucket_samples` rows
   (`status`, `raw_received_at`, `raw_message_id`) over the same band.
3. Set the checkpoint to `hist_start` and issue one bounded `CALL` with
   `p_max_window = hist_window_minutes` minutes, so the loader's own
   `v_window_end` computation lands exactly on `hist_end`
   (`LEAST(max(received_at), hist_start + window) = hist_end`, given PHASE
   4 already confirmed `hist_end` is behind `max(received_at)`).
4. Recompute the digest over the identical predicate and set-diff both
   directions (added/removed by natural key, changed value columns on a
   shared key, and a check that `platform_received_at` never regresses).
5. Assert the `capture_bucket_samples` snapshot for the band is unchanged in
   status/identity — a re-run must not flip any row's disposition.

**Acceptance for this phase is exact equality** — digest match, zero
set-diff, zero `capture_bucket_samples` change. No tolerance is applied;
this is a correctness check, not a performance measurement, and is reported
separately from the performance evidence in PHASE 9.

See OPEN DESIGN QUESTION E-2 above for the one real limitation: an
all-already-normalized band proves non-corruption but does not exercise the
changed join against fresh driving rows.

## Performance evidence

**This gate measures; it does not grade against an invented number.** Per
approved decision 7, the repository defines no numeric pass/fail threshold
for normalization runtime today — the migration-212 2-hour default is
explicitly documented as provisional pending exactly this kind of staging
measurement. PHASE 9 in the `.sql` prints a `MEASUREMENTS` table (per
window: checkpoint before/after, expected vs. actual watermark, server- and
client-measured duration, rows inserted) completely separately from
`ACCEPTANCE CHECKS` (the correctness/bounded/equivalence asserts, which are
genuine pass/fail). The first authorized run's `MEASUREMENTS` output
**is** the baseline; any numeric production-acceptance bar derived from it
is a **separate, later review**, not something either script decides.

PHASE 5 additionally runs one `EXPLAIN (ANALYZE, BUFFERS, VERBOSE)` inside
`BEGIN; ... ROLLBACK;` (so it writes nothing) against the exact join
predicate migration 221 changed, isolated from the full procedure — Postgres
cannot `EXPLAIN` a `CALL`, so this is an **approximate plan probe** of the
loader's internal join, not a full plan of the procedure body. A reviewer
should confirm the plan shows chunk exclusion / a nested loop, not a full
`Parallel Append` / `Hash Join` / `ColumnarScan` decompression, per the
migration's own before/after evidence. `--enable-idonly-contrast-probe`
additionally runs the known-slow pre-221 shape under a 120-second
`statement_timeout` for a side-by-side comparison — OPEN DESIGN QUESTION,
off by default, since it deliberately re-runs a shape already known to be
slow against live staging.

## PASS / FAIL / INCONCLUSIVE semantics

Computed identically by the `.sql`'s PHASE 9 printout and the `.sh`'s final
verdict block (the `.sh` classifies from the evidence file's own `ERROR`
lines rather than re-implementing the logic, so the two cannot disagree):

- **PASS** — every `ACCEPTANCE CHECK` that ran (PHASE 1 preflight, PHASE 6
  bounded-window watermark asserts, PHASE 7 equivalence) passed, **and** a
  reviewer confirms PHASE 5's `EXPLAIN` shows chunk exclusion / a nested
  loop. Performance is reported as evidence alongside PASS, never as a
  pass/fail input itself.
- **FAIL** — any `ACCEPTANCE CHECK` raised (surfaces as a hard `STOP`/`FAIL`
  in the evidence, aborting the run), or PHASE 5 still shows a full
  `Parallel Append` / `Hash Join` / `ColumnarScan` plan shape.
- **INCONCLUSIVE** — a `STOP` fired in PHASE 0–4 (environment/preflight/
  reconnaissance), or a `CALL` returned `SKIPPED_LOCKED`, or the equivalence
  band had no driving `SELECTED`/`FAILED` samples (OPEN DESIGN QUESTION
  E-2), or the 2-hour timing landed at/near `max_runtime` pending reviewer
  judgment. A dry-run (`gate_execute=off`) that completes cleanly is
  reported as "DRY-RUN clean," a *prerequisite* for scheduling `--execute`,
  never itself a PASS.

## Cleanup / restoration

Handled entirely by the `.sh`'s `restore_state()` trap (`EXIT`/`INT`/`TERM`),
described in detail above under "Exact staging mutations." After every
`--execute` run — success, assertion failure, or operator interrupt — the
evidence file records: the exact captured baseline (pipeline_state row +
full Job 1000 config), the restoration `UPDATE`/`alter_job()` statements
issued, and an explicit `RESTORE_OK` or `RESTORE_MISMATCH` line from a
follow-up read-only comparison against the captured baseline. **A
`RESTORE_MISMATCH` is a manual-intervention condition** — the script prints
it prominently but does not attempt a second automatic remediation, since a
failed restoration is exactly the situation that most needs a human to look
at the actual captured values before anything else touches the row.

## Separate post-gate Job 1000 operational observation

Per approved decision 10, this gate is explicitly **not** the same activity
as watching Job 1000 run unattended for multiple cycles after this gate
(and any subsequent resume-to-production-schedule decision). This gate:
validates the deployed migration body, produces one-shot bounded-window
timing evidence, and proves fixed-window equivalence, all while Job 1000 is
paused and under this gate's direct control. It says nothing about Job
1000's steady-state behavior once resumed to its normal 1-minute schedule —
retry behavior under `max_retries`/`retry_period`, `SKIPPED_LOCKED`
frequency under real concurrent load, or drift over ≥3 real scheduled
cycles. That observation is a **separate, later, explicitly-authorized
piece of work**, informed by but not replacing this gate's evidence, and is
out of scope for both files this document describes.

## Evidence retention

Every gate invocation (dry-run or `--execute`) writes one timestamped file
to `docs/operations/evidence/221-staging-gate/<UTC-timestamp>-<dryrun|execute>.log`
(the directory is created on first use; override with `--evidence-dir`).
Each file records: the full resolved run configuration header (mode,
baseline mode, historical window, checksum, and — for `--execute` runs —
`EMS_GATE_AUTHORIZED_BY`/`EMS_GATE_AUTHORIZATION_REF`, never a credential);
the captured pre-mutation baseline; the complete `psql` transcript (every
`NOTICE`/`WARNING`/`ERROR`, the `MEASUREMENTS` table, the `EXPLAIN` output);
and the restoration transcript plus its `RESTORE_OK`/`RESTORE_MISMATCH`
verdict. These evidence files are the artifact a later numeric-threshold
review (approved decision 7) and any production-promotion discussion should
cite directly, rather than a paraphrase of them. This gate does not itself
define a retention *period* for these files — OPEN DESIGN QUESTION, treat
as retained indefinitely (like any other repository file) until the team
sets an explicit policy.

## Review history

**2026-08-30, second session — critical design/review pass (no execution).**
Working in this same detached `ems-wt221` worktree, all three artifacts were
re-inspected against the repository (not re-derived from memory) and the
following corrections were made, strictly within these three files:

1. Re-confirmed S-1 (below) by re-searching the repository for any staging
   access mechanism (bastion/VPN/kubectl/Terraform/Ansible/Teleport/
   Tailscale/WireGuard) beyond what was already found — none exists in the
   repository itself. (This was superseded by a third session's read-only
   probe of the operator's own local environment — see below.)
2. **Fixed a real restoration-ordering gap**: `telemetry.pipeline_state` is
   now captured *after* Job 1000 is paused, not before (see "Cleanup /
   restoration" above) — closes a race against Job 1000's live 1-minute
   schedule that could have made the captured baseline stale.
3. **Hardened the capture/restore delimiter**: every dynamic/free-text field
   (`last_error`, `config::text`) is now defended against delimiter
   collision via the same `replace()` guard, via a single shared `$FS`
   variable, instead of one field being defended ad hoc.
4. **Hardened `remote_psql()`**: added `-T`, `BatchMode=yes`, and
   `ConnectTimeout=15` to the SSH invocation (avoids an unexpected tty, a
   hung password prompt, or an unbounded stall on a dead host).
5. **Hardened `restore_state()`** against its own connectivity failures:
   restoration and its verification no longer risk `set -e` killing the trap
   mid-cleanup; a connectivity failure during verification is now reported
   as `RESTORE_VERIFICATION_UNREACHABLE` rather than producing a malformed
   comparison.
6. **Made the equivalence limitation (E-2) machine-checkable**: PHASE 4 now
   counts driving rows and emits a fixed `EQUIVALENCE_LIMITATION_ZERO_DRIVING_ROWS`
   marker the `.sh` greps for, instead of relying on a human noticing prose.
7. Confirmed unchanged and correct on re-inspection: the four bounded
   windows (1m/5m/15m/2h) each hold `p_overlap` fixed at 15 minutes and vary
   only `p_max_window`, with no `NULL`/unbounded run anywhere; PHASE 1d's
   `last_analyze`/`last_autoanalyze` precondition still hard-`STOP`s with no
   `ANALYZE` fallback; PHASE 6's near-`max_runtime` 2h check remains
   report-only.
8. Documented, but deliberately not further engineered (see the open items
   below): the SSH-hop shell-quoting risk for dynamic values, and a GNU-`date`
   dependency in the `.sh`'s window-minutes calculation.

No database connection was made to perform this review; every finding above
was reached by reading the repository and the three artifacts.

**2026-08-30, third session — S-1 read-only transport probe (no execution).**
One explicitly authorized SSH command (`ssh -T -o BatchMode=yes
-o ConnectTimeout=15 ems-staging '...'`, a single connection running only
`echo`/`id`/`pwd`/`docker compose version`/`docker ps`/`ls`/
`docker compose ps` — no PostgreSQL connection, no `psql`, no database
inspection, no Job 1000 interaction, no gate execution, no mutation of any
kind) established the facts now recorded in "Staging transport (S-1)"
above: the `ems-staging` alias, `emsadmin` user, `/bin/bash` login shell,
direct `docker` group access, Docker Compose v5.5.0, and
`/opt/ems-platform` as the confirmed live deployment path. This resolves
S-1 **for this operator's own environment** and the `printf %q`/bash-shell
assumption in `remote_psql()` — it does not resolve the CI-identity
question (see the explicit caveats in that section) or the still-open items
below. No file was executed or mutated as part of this probe or this
documentation update.

**2026-08-30, fourth session — first authorized `--execute` attempt (real
staging mutation, failed at PHASE 0).** An operator ran the `.sh` with
`--execute` under full authorization. `capture_job_config()` and
`pause_job1000()` succeeded (Job 1000 paused); the main gate invocation then
failed immediately at PHASE 0 with `psql: ERROR: syntax error at or near
":"`. No `CALL` was issued and `telemetry.pipeline_state` was never
mutated. The `.sh`'s own `restore_state()` trap did not cleanly confirm
Job 1000's restoration on this run; the operator then **restored Job 1000
manually**, using the exact six-field configuration already captured and
printed before the pause, and **independently verified** the restoration
against that same captured configuration. Job 1000 has since resumed its
normal schedule and `pipeline_state` has advanced naturally. Production was
never touched. See "Incident: first authorized `--execute` attempt failed
at PHASE 0" near the top of this document for the full account. No file was
changed as part of this session — the failure was observed, Job 1000 was
restored, and the investigation was handed to the next session.

**2026-08-30, fifth session — root-caused and fixed the PHASE 0 failure (no
execution).** Working in this same detached `ems-wt221` worktree, with no
staging or production connection at any point: reproduced the exact failure
locally against a disposable TimescaleDB container already running for
other local testing (`ems-timescaledb-test`); isolated the cause to psql's
colon-substitution never scanning inside dollar-quoted `DO $tag$...$tag$;`
bodies (not a transport/quoting bug — the `-v` arguments were, and always
had been, delivered correctly); fixed every affected `DO` block in the
`.sql` by bridging operator-/`\gset`-supplied values through session GUCs
(`set_config()`/`current_setting()`) instead of referencing them via
`:'name'` from inside the block; corrected a separate, pre-existing stale
comment in the `.sql`'s PHASE 8 (which still claimed the `.sh` "re-invokes
this file with a restore-only flag" — superseded by the second session's
restoration-mechanism fix but never updated at that specific comment site);
updated the `.sh`'s `remote_psql()` header and this document to record the
incident and the fix. Re-validated locally: the full `remote_psql()` chain
re-simulated with stand-in `ssh`/`docker` executables (confirms `-v`
delivery is intact), the corrected `.sql` run in dry-run mode via `docker
exec -i` against the disposable local container (PHASE 0 now evaluates
correctly instead of syntax-erroring), and `bash -n` on the `.sh`. See "psql
variable interpolation inside DO blocks (2026-08-30 fix)" above for the full
writeup. This does **not** constitute a passing staging gate run — the gate
still requires a fresh, separately authorized `--execute` attempt to
actually validate migration 221 on staging.

## Open design questions summary

| ID | Question | Status | Where |
|---|---|---|---|
| S-1 | Staging interactive-transport mechanism is not an established *repository* convention (only CI's secrets-based SSH exists) | **Confirmed for this operator** (2026-08-30 read-only probe): `ems-staging` alias, user `emsadmin`, `/bin/bash`, direct Docker access, `/opt/ems-platform`. **Still open**: whether this is the sanctioned mechanism for *other* operators, and its relationship (if any) to CI's identity, remain unconfirmed | `.sh` header, "Staging transport (S-1)" above |
| — | Shell-quoting: `printf %q`-based quoting across the SSH hop assumes a POSIX-sh/bash-compatible remote login shell | **Resolved for this operator/environment** — remote login shell confirmed `/bin/bash` (2026-08-30 probe), and `-v` delivery through the full chain independently confirmed twice more (the fourth session's real failed run, and this session's local re-simulation). Not proven for any other operator/machine/CI identity. Residual, narrower caveat unchanged: a value containing a literal single quote (realistically only possible in Job 1000's live `config` JSON) is still unsupported | `.sh` `remote_psql()` comment |
| — | psql `:'name'` substitution does not reach inside `DO $tag$...$tag$;` bodies | **Fixed** (2026-08-30, fifth session) — every affected DO block now reads values via `current_setting('gate.<name>')`, bridged from top-level SQL via `set_config()`. Root-caused from a real staging PHASE 0 failure (fourth session) and reproduced/fixed/locally-validated without any staging or production connection (fifth session). Still requires a fresh authorized `--execute` run to confirm PHASE 0 onward actually passes on real staging | `.sql` "PHASE 0-pre" section; "psql variable interpolation inside DO blocks" above |
| — | This exact multi-hop chain (local shell → SSH → `docker compose exec` → `psql -v`) has not been exercised against real staging infrastructure | **Substantially confirmed** — the fourth session's real `--execute` attempt independently showed `-v` arguments arriving at psql correctly over this exact chain (the failure was downstream, in psql/PostgreSQL itself, not in transport); this session additionally re-simulated the full chain locally. **Still not exercised**: a live run where the gate reaches PHASE 1+ over the real SSH connection — no session has gotten that far yet | `.sh` `remote_psql()` comment |
| E-2 | An all-already-`NORMALIZED` historical band under-tests the changed join (equivalence proves non-corruption only, not join correctness on fresh rows) | **Mitigated** (machine-checkable via `EQUIVALENCE_LIMITATION_ZERO_DRIVING_ROWS`), **and confirmed unavoidable right now** — a 2026-08-30 read-only reconnaissance query found zero `SELECTED`/`FAILED` rows anywhere in retained `capture_bucket_samples` history (538,797 `NORMALIZED` + 444 `RECOVERED`, 0 pending/failed); staging is currently fully caught up with no backlog. Not something to work around — no synthetic driving rows were or should be manufactured | "Equivalence methodology" and "Reconnaissance finding" above |
| — | `--enable-idonly-contrast-probe` deliberately re-runs a known-slow pre-221 shape against live staging under a timeout; off by default | **By design** — reviewer decision each run | "Performance evidence" above |
| — | Neither `baseline_mode` reproduces the original incident's heavy fresh-backlog condition without a separate, independently authorized decision to let Job 1000 fall behind first | **Unresolved by design** — out of this gate's scope | "1m / 5m / 15m / 2h methodology" above |
| — | Evidence file retention period is unset | **Unresolved** — needs a team decision | "Evidence retention" above |
| — | `HIST_WINDOW_MINUTES` computation requires GNU `date -d`; not available on stock macOS/BSD `date` | **Unresolved** — only matters if the gate is run from macOS without coreutils | `.sh`, near `HIST_WINDOW_MINUTES` |

## Reviewer checklist (for this draft)

- [x] S-1 (staging transport) confirmed for this operator's own environment
      (2026-08-30 read-only probe: `ems-staging` alias, `emsadmin`,
      `/bin/bash`, direct Docker access, `/opt/ems-platform`). If a
      *different* operator or machine will run this gate, confirm their
      own `EMS_STAGING_SSH_HOST`/`EMS_STAGING_SSH_USER` work the same way
      first — nothing here is hard-coded or transferable by assumption.
- [x] Remote login shell confirmed `/bin/bash` for this operator's account
      — the `.sh`'s `printf %q` quoting is safe under it. Not proven for
      any other account/shell.
- [x] Multi-hop `-v` delivery through SSH → `docker compose exec` → `psql`
      confirmed repeatedly: the fourth session's real (failed) `--execute`
      run showed `-v` flags arriving at psql correctly, a later session
      independently re-simulated the full chain locally, and all three real
      `--execute` runs since (including the passing third one) confirm it
      live.
- [x] **Done**: a fresh, separately authorized `--execute` run against real
      staging, with the PHASE 0 DO-block substitution fix applied — the
      first of three real runs; see "Incident: first authorized `--execute`
      attempt failed at PHASE 0" for that run and "Third execute attempt:
      PASS" for the one that ultimately passed.
- [ ] If running from macOS, confirm GNU `date` (`coreutils`/`gdate`) is
      available, or adapt the `HIST_WINDOW_MINUTES` calculation first.
- [ ] Re-read `scripts/test/assert_normalization_221_staging_gate.sql`
      PHASE 1c's pattern-matches against the *current* deployed procedure
      body if migration 221 (or 205/212) is ever amended — these are
      string/ILIKE matches against `pg_get_functiondef()`, not a semantic
      parse, and will silently stop matching (STOP, fail closed) rather than
      silently pass on an unrelated body change.
- [ ] Confirm reconnaissance discipline: no `--hist-start`/`--hist-end`
      values should ever be chosen without the separate, reviewed
      reconnaissance step this document describes.
- [ ] Confirm no numeric performance threshold is applied anywhere in either
      script (per approved decision 7) before this gate is used as an input
      to a production-promotion decision.
- [ ] Confirm the ≥3-cycle Job 1000 post-resume observation (approved
      decision 10) is tracked as separate work, not assumed to be covered by
      a single gate run.
- [ ] Confirm evidence-file retention expectations with the team (currently
      unset).
