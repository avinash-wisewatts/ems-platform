#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# scripts/test/assert_normalization_221_staging_gate.sh
#
# Status:
#   DRAFT -- designed for a FUTURE, EXPLICITLY AUTHORIZED staging execution.
#   NOT wired into scripts/test/run_integration_environment.sh (that runner
#   is the disposable local-DB CI suite -- see its header). This is a
#   hand-run operational gate against the STAGING `ems` database only.
#
# ============================================================================
#   STAGING ONLY -- THIS SCRIPT MUST NEVER TARGET PRODUCTION.
# ============================================================================
#
# Purpose:
#   Drive scripts/test/assert_normalization_221_staging_gate.sql against
#   staging: preflight-only by default, or a full authorized run (bounded
#   1m/5m/15m/2h timing + fixed-window equivalence) with --execute. This
#   wrapper is the ONLY place that:
#     * resolves and enforces the staging target,
#     * pauses/resumes TimescaleDB job 1000 (telemetry.run_normalization_job),
#     * holds the DURABLE capture of telemetry.pipeline_state and job 1000's
#       config used to restore them, independent of whether the .sql's own
#       PHASE 8 ran (see the .sql header's "CORRECTION" note -- a psql temp
#       table does not survive a connection that ON_ERROR_STOP just aborted).
#
# What this script does NOT do:
#   * It does not choose the historical reconnaissance window. --hist-start /
#     --hist-end / --recon-overlap-secs must come from a prior, separately
#     reviewed read-only reconnaissance pass (see README-221.md).
#   * It does not run ANALYZE. If the .sql's PHASE 1d stats precondition is
#     absent, the gate STOPS; this script does not work around that.
#   * It does not change Job 1000's schedule/max_runtime/max_retries/
#     retry_period/config as a *result* of the 2h timing run -- a near-
#     max_runtime 2h result is reported only (PHASE 6 WARNING in the .sql).
#   * It never invents a numeric performance pass/fail threshold.
#
# OPEN DESIGN QUESTIONS in this script are marked inline as:
#   OPEN DESIGN QUESTION — requires review
#
# S-1 (transport) — CONFIRMED 2026-08-30 via one explicitly authorized,
# read-only SSH probe (no PostgreSQL connection, no psql, no Job 1000
# interaction, no mutation of any kind):
#   * SSH alias `ems-staging` (this operator's local ~/.ssh/config) reaches
#     the staging host as user `emsadmin`.
#   * Remote login shell: `/bin/bash` (from `$SHELL`).
#   * `emsadmin` has direct Docker access via group membership
#     (`groups=...,988(docker)`) -- no `sudo` required for any `docker`/
#     `docker compose` command.
#   * Docker Compose v5.5.0 is present and working.
#   * Staging project path: `/opt/ems-platform` -- confirmed to exist, to
#     contain this repository's checkout (`.git`, `compose.yaml`), and to be
#     the live deployment: `docker compose ps` there listed all five
#     expected services healthy, with `ems-admin-portal`/`ems-live-telemetry`
#     running the exact image tag
#     `ghcr.io/avinash-wisewatts/ems-platform-app:2c90645ae64abc48a0630722697e4660cff7a9da`
#     -- the same commit this worktree is detached at.
#   * The `timescaledb` Docker Compose *service* name (as opposed to its
#     `ems-timescaledb` container name) matches this script's
#     `EMS_STAGING_DB_CONTAINER` default exactly, confirming
#     `docker compose exec -T timescaledb ...` resolves correctly.
#   * This also RESOLVES the `printf %q` remote-command-construction concern
#     below: bash-flavored `%q` quoting is safe here because the confirmed
#     remote login shell is bash, not a POSIX `sh`/dash variant.
#
#   What this DOES NOT establish: this is the confirmed transport for THIS
#   operator, on THIS machine, using THIS operator's own SSH alias -- it is
#   NOT a repository-committed convention (no `~/.ssh/config` entry, of
#   course, is ever committed to a repo), and it does NOT establish that
#   `emsadmin` is the same identity CI/CD's `STAGING_HOST` / `STAGING_USER` /
#   `STAGING_SSH_KEY` / `STAGING_PROJECT_PATH` secrets (used by
#   `.github/workflows/deploy-staging.yml`'s `appleboy/ssh-action` step, per
#   `docs/operations/CICD_PIPELINE.md`) resolve to -- that remains unknown
#   and is irrelevant to this operator-run gate, which never reads those CI
#   secrets. A different operator on a different machine still needs their
#   own working `EMS_STAGING_SSH_HOST` / `EMS_STAGING_SSH_USER` set up
#   before running this script; this script still refuses to run with any
#   of them unset (see the hard checks below) and never hard-codes a host or
#   user.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GATE_SQL="${SCRIPT_DIR}/assert_normalization_221_staging_gate.sql"
MIGRATION_221_FILE="${PROJECT_ROOT}/postgres/migrations/221_normalization_selected_elements_pk_join.sql"

# ----------------------------------------------------------------------------
# 0. STAGING ONLY banner (always printed, cannot be suppressed).
# ----------------------------------------------------------------------------
print_banner() {
    cat <<'BANNER'
============================================================================
  MIGRATION 221 STAGING VALIDATION GATE
  *** STAGING ONLY. THIS SCRIPT MUST NEVER BE POINTED AT PRODUCTION. ***
  Default mode is PREFLIGHT / DRY-RUN (no mutation). --execute additionally
  performs bounded CALLs, transient pipeline_state watermark moves, and a
  Job 1000 pause/resume -- each requires explicit authorization (see below).
============================================================================
BANNER
}

usage() {
    cat <<'USAGE'
Usage: assert_normalization_221_staging_gate.sh --hist-start <ISO ts> --hist-end <ISO ts> --recon-overlap-secs <N> \
          --deploy-221-after <ISO ts> [options]

Required (both modes -- PHASE 4 in the .sql re-validates these; it does not
choose them):
  --hist-start TS              Reconnaissance-selected historical window start
                                (exclusive), ISO 8601 timestamptz.
  --hist-end TS                Reconnaissance-selected historical window end
                                (inclusive), ISO 8601 timestamptz.
  --recon-overlap-secs N       v_dynamic_overlap (seconds) the loader would
                                compute for this window, from reconnaissance.
  --deploy-221-after TS        Migration-221 deploy time on staging (ISO
                                8601); PHASE 1d requires capture_bucket_samples
                                stats to postdate this.

Mode:
  --execute                    Run the FULL gate (bounded CALLs + equivalence
                                + Job 1000 pause/resume). Requires
                                EMS_GATE_AUTHORIZED_BY, EMS_GATE_AUTHORIZATION_REF,
                                and --i-authorize-staging-mutation.
                                Omit for PREFLIGHT / DRY-RUN (default).
  --i-authorize-staging-mutation
                                Required together with --execute. A second,
                                explicit confirmation that this run WILL pause
                                Job 1000, move the pipeline_state watermark
                                (transiently, then restore it), and issue N
                                real bounded CALLs against staging.

Options:
  --baseline-mode as_is|rewind Default: as_is. See PHASE 6 in the .sql for
                                what each mode measures and its limitation.
  --rewind-interval INTERVAL   Required when --baseline-mode rewind (e.g.
                                "2 hours 30 minutes").
  --enable-idonly-contrast-probe
                                OPEN DESIGN QUESTION — requires review.
                                Also runs the known-slow pre-221 id-only join
                                shape under a 120s statement_timeout, inside
                                the EXPLAIN probe's own BEGIN;...ROLLBACK;.
                                Off by default.
  --evidence-dir DIR           Default: docs/operations/evidence/221-staging-gate
  -h, --help                   Show this help.

Required environment variables (never hard-coded, never printed by this
script):
  EMS_GATE_ENV_CONFIRM          Must be exactly "staging".
  EMS_STAGING_SSH_HOST          Staging SSH host or SSH-config alias (e.g.
                                this operator's confirmed `ems-staging`
                                alias -- see the S-1 note above). Still
                                required explicitly: this script never
                                hard-codes a host, since a different
                                operator's alias name/value may differ.
  EMS_STAGING_SSH_USER          Staging SSH user (confirmed for this
                                operator's `ems-staging` alias: `emsadmin`,
                                with direct Docker group access, no sudo
                                needed -- still not assumed as a default;
                                see the S-1 note above).
  EMS_STAGING_PROJECT_PATH      Repository checkout path on the staging
                                host. CONFIRMED via the S-1 probe to be
                                `/opt/ems-platform` for the actual staging
                                deployment (same value production uses per
                                its own runbook) -- also mirrors
                                STAGING_PROJECT_PATH's role in
                                deploy-staging.yml, though that CI secret's
                                actual value was not read or compared here.
  EMS_GATE_AUTHORIZED_BY        (only for --execute) operator name/handle.
  EMS_GATE_AUTHORIZATION_REF    (only for --execute) approval reference
                                (ticket/PR/review link) -- recorded into the
                                evidence file, never invented by this script.

Optional environment variables:
  EMS_STAGING_DB_CONTAINER      Default: timescaledb (matches
                                apply_migrations.sh; CONFIRMED via the S-1
                                probe to be the correct Docker Compose
                                *service* name at /opt/ems-platform -- the
                                running container is named ems-timescaledb,
                                but `docker compose exec` addresses it by
                                service name, which is `timescaledb`)
  EMS_STAGING_DB_NAME           Default: ems
  EMS_STAGING_DB_USER           Default: ems_admin
USAGE
}

# ----------------------------------------------------------------------------
# 1. Argument parsing.
# ----------------------------------------------------------------------------
EXECUTE=0
AUTHORIZE_MUTATION=0
BASELINE_MODE="as_is"
REWIND_INTERVAL=""
PROBE_IDONLY_CONTRAST=0
HIST_START=""
HIST_END=""
RECON_OVERLAP_SECS=""
DEPLOY_221_AFTER=""
EVIDENCE_DIR="${PROJECT_ROOT}/docs/operations/evidence/221-staging-gate"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hist-start) HIST_START="$2"; shift 2 ;;
        --hist-end) HIST_END="$2"; shift 2 ;;
        --recon-overlap-secs) RECON_OVERLAP_SECS="$2"; shift 2 ;;
        --deploy-221-after) DEPLOY_221_AFTER="$2"; shift 2 ;;
        --execute) EXECUTE=1; shift ;;
        --i-authorize-staging-mutation) AUTHORIZE_MUTATION=1; shift ;;
        --baseline-mode) BASELINE_MODE="$2"; shift 2 ;;
        --rewind-interval) REWIND_INTERVAL="$2"; shift 2 ;;
        --enable-idonly-contrast-probe) PROBE_IDONLY_CONTRAST=1; shift ;;
        --evidence-dir) EVIDENCE_DIR="$2"; shift 2 ;;
        -h|--help) print_banner; usage; exit 0 ;;
        *) echo "ERROR: unrecognized argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

fail() { echo "ERROR: $1" >&2; exit 1; }

print_banner

[[ -n "${HIST_START}" && -n "${HIST_END}" && -n "${RECON_OVERLAP_SECS}" && -n "${DEPLOY_221_AFTER}" ]] \
    || { usage >&2; fail "--hist-start, --hist-end, --recon-overlap-secs and --deploy-221-after are all required"; }

if [[ "${BASELINE_MODE}" != "as_is" && "${BASELINE_MODE}" != "rewind" ]]; then
    fail "--baseline-mode must be 'as_is' or 'rewind'"
fi
if [[ "${BASELINE_MODE}" == "rewind" && -z "${REWIND_INTERVAL}" ]]; then
    fail "--baseline-mode rewind requires --rewind-interval"
fi

if [[ "${EXECUTE}" -eq 1 && "${AUTHORIZE_MUTATION}" -ne 1 ]]; then
    fail "--execute requires --i-authorize-staging-mutation as an explicit second confirmation"
fi

# ----------------------------------------------------------------------------
# 2. Hard target / environment checks (always run, dry-run or not).
#    Fails closed: any unset/mismatched value stops the script before any
#    connection is attempted.
# ----------------------------------------------------------------------------
: "${EMS_GATE_ENV_CONFIRM:?EMS_GATE_ENV_CONFIRM must be set to 'staging'}"
: "${EMS_STAGING_SSH_HOST:?EMS_STAGING_SSH_HOST must be set (see --help; e.g. a confirmed ems-staging SSH alias)}"
: "${EMS_STAGING_SSH_USER:?EMS_STAGING_SSH_USER must be set}"
: "${EMS_STAGING_PROJECT_PATH:?EMS_STAGING_PROJECT_PATH must be set}"

DB_CONTAINER="${EMS_STAGING_DB_CONTAINER:-timescaledb}"
DB_NAME="${EMS_STAGING_DB_NAME:-ems}"
DB_USER="${EMS_STAGING_DB_USER:-ems_admin}"

if [[ "${EMS_GATE_ENV_CONFIRM}" != "staging" ]]; then
    fail "EMS_GATE_ENV_CONFIRM=${EMS_GATE_ENV_CONFIRM} (expected exactly 'staging'). Refusing to proceed."
fi

# Defense in depth: refuse anything that even LOOKS like production, on top
# of the .sql's own current_database()='ems' + :env_confirm='staging' check
# (PHASE 0) and this script never reading any PRODUCTION_* secret.
for candidate in "${EMS_STAGING_SSH_HOST}" "${EMS_STAGING_SSH_USER}" "${EMS_STAGING_PROJECT_PATH}" "${DB_NAME}"; do
    lc="$(printf '%s' "${candidate}" | tr '[:upper:]' '[:lower:]')"
    case "${lc}" in
        *prod*|*production*)
            fail "one of the staging target values looks like production ('${candidate}'). Refusing to proceed."
            ;;
    esac
done

if [[ "${EXECUTE}" -eq 1 ]]; then
    : "${EMS_GATE_AUTHORIZED_BY:?--execute requires EMS_GATE_AUTHORIZED_BY}"
    : "${EMS_GATE_AUTHORIZATION_REF:?--execute requires EMS_GATE_AUTHORIZATION_REF}"
fi

echo "Target : ${EMS_STAGING_SSH_USER}@${EMS_STAGING_SSH_HOST}:${EMS_STAGING_PROJECT_PATH}"
echo "DB     : container=${DB_CONTAINER} db=${DB_NAME} user=${DB_USER}"
echo "Mode   : $([[ ${EXECUTE} -eq 1 ]] && echo 'EXECUTE (full gate, mutating)' || echo 'DRY-RUN (preflight only)')"
echo

# ----------------------------------------------------------------------------
# 3. Remote psql helper.
#
#    Mirrors scripts/apply_migrations.sh's own local invocation shape
#    (`docker compose exec -T <container> psql ... -f -`), relayed over SSH
#    because staging is remote.
#
#    Hardening applied here (2026-08-30 review pass):
#      -T                  disable remote pseudo-tty allocation. ssh only
#                          allocates one automatically when stdin is a tty
#                          and no -T/-t is given; being explicit removes that
#                          ambiguity for every call site (including the ones
#                          below that pipe a heredoc/`<<< ""` rather than a
#                          file), and avoids a tty ever being interposed in
#                          front of psql's own stdout, which this script
#                          parses.
#      BatchMode=yes       fail immediately (non-zero exit) instead of
#                          hanging on an interactive password/passphrase
#                          prompt if key auth is not already set up -- this
#                          script must never block waiting for terminal
#                          input it cannot receive under `set -e`+trap.
#      ConnectTimeout=15   bound how long a dead/unreachable host can stall
#                          the script before the restore trap gets a chance
#                          to run.
#
#    Shell-compatibility of the per-argument `printf %q` quoting below:
#    RESOLVED for this confirmed operator/environment (2026-08-30 S-1
#    probe) -- the remote login shell for `emsadmin` on the staging host is
#    confirmed `/bin/bash`, so bash-flavored `%q` quoting is interpreted
#    exactly as intended; the POSIX-`sh`/dash-incompatibility risk this
#    comment used to flag does not apply here. This is confirmed for THIS
#    operator's account on THIS host only -- it says nothing about any
#    other operator, machine, or CI identity (see the S-1 note in this
#    file's header). A residual, narrower caveat remains: for the values
#    this script actually passes (ISO timestamps, small integers, interval
#    literals, and capture_job_config()'s read-back of Job 1000's live
#    `config` JSON), `%q` quoting holds as long as none of them contains a
#    literal single-quote character -- treat any future job config value
#    containing a single quote as unsupported until this is hardened
#    further (e.g. base64-encoding values across the SSH hop).
#
#    2026-08-30, FOURTH session -- REAL `--execute` attempt against staging
#    (authorized) exercised this exact chain for the first time and hit a
#    real failure at PHASE 0, which paused Job 1000 before failing (Job 1000
#    was subsequently restored manually and independently verified; see
#    README-221.md "Review history"). Root-caused and fixed in this file's
#    companion .sql, NOT here:
#      * This function's own construction of `remote_cmd` and its delivery
#        of every `-v name=value` pair through
#        ssh -> bash -c "<remote_cmd>" -> docker compose exec -> psql argv
#        was traced end-to-end (both by re-simulating this exact chain
#        locally with stand-in `ssh`/`docker` shims, and by the failing
#        staging run itself, which confirmed psql received the `-v` flags
#        correctly). That part of the mechanism is NOT the bug and needed no
#        change here.
#      * The actual bug: psql's own colon-substitution scanner never looks
#        inside a dollar-quoted string, and every `DO $tag$ ... $tag$;` block
#        in the .sql referenced `-v`-supplied values via `:'name'` from
#        *inside* that dollar-quoted body -- so those references reached
#        PostgreSQL completely unsubstituted (`ERROR: syntax error at or near
#        ":"`), exactly at PHASE 0, which is entirely one such DO block.
#        Reproduced locally against a disposable TimescaleDB container
#        (`docker exec -i <container> psql -v env_confirm=staging -f -` with
#        a `DO $$ ... IF :'env_confirm' <> 'staging' ... $$;` body) and fixed
#        in the .sql via session GUCs (`set_config()`/`current_setting()`)
#        bridging every such value into DO block bodies instead of relying on
#        psql substitution inside them. See the .sql's "PHASE 0-pre" header
#        and README-221.md, "psql variable interpolation inside DO blocks
#        (2026-08-30 fix)", for the full writeup.
#      * This function's -c-based restoration calls in restore_state() below
#        were NOT affected by this bug -- they are plain top-level
#        `SELECT alter_job(...)` / `UPDATE ...` statements with no
#        dollar-quoting, and top-level :'var' substitution was confirmed
#        (both by this bug's own root-causing and by the failing staging
#        run) to work correctly. No change was needed there.
#      * Local validation of the fix (this session): full transport
#        re-simulation (fake ssh/docker capturing exact argv) plus a real
#        `docker exec -i` run of the corrected .sql, dry-run mode, against a
#        disposable local TimescaleDB container -- PHASE 0 now evaluates
#        correctly (passes when database/env_confirm match, fails with the
#        correct, expected message otherwise) instead of syntax-erroring.
#        No staging or production connection was made for this validation.
# ----------------------------------------------------------------------------
remote_psql() {
    # Usage: remote_psql <psql-arg>... < sql-on-stdin
    local remote_cmd
    remote_cmd=$(printf 'cd %q && docker compose exec -T %q psql -X -v ON_ERROR_STOP=1 -U %q -d %q' \
        "${EMS_STAGING_PROJECT_PATH}" "${DB_CONTAINER}" "${DB_USER}" "${DB_NAME}")
    local arg
    for arg in "$@"; do
        remote_cmd+=" $(printf '%q' "${arg}")"
    done
    ssh -T -o BatchMode=yes -o ConnectTimeout=15 \
        "${EMS_STAGING_SSH_USER}@${EMS_STAGING_SSH_HOST}" "${remote_cmd}"
}

# ----------------------------------------------------------------------------
# 4. Expected migration-221 checksum -- computed from THIS checkout's git
#    HEAD blob, never supplied by the operator.
#
#    CORRECTION (2026-08-30, real staging dry-run): this used to be a raw
#    `sha256sum` of the checked-out file on disk, intended to match
#    scripts/apply_migrations.sh's own sha256sum convention. On this
#    operator's Windows checkout (core.autocrlf=true, the standard Windows
#    git default), the on-disk file has CRLF line endings, so its raw
#    checksum can NEVER match the checksum apply_migrations.sh recorded when
#    it actually ran the migration -- on the Linux staging host, from a
#    fresh LF-checkout. This is exactly what a real, authorized dry-run hit:
#    PHASE 1a STOPped on a checksum mismatch even though `git diff HEAD` on
#    the file showed zero differences. `git show HEAD:<path> | sha256sum`
#    (git always stores blobs LF-normalized) reproduced staging's recorded
#    checksum exactly, confirming the deployed content is correct and the
#    mismatch was a line-ending artifact of this platform's checkout, not a
#    real content drift. Failing closed on a dirty working-tree file (below)
#    preserves the check's actual intent: verify staging against the
#    reviewed, committed content -- not silently against git's blob if the
#    on-disk file has genuinely diverged from HEAD.
# ----------------------------------------------------------------------------
[[ -f "${MIGRATION_221_FILE}" ]] || fail "migration file not found: ${MIGRATION_221_FILE}"
git -C "${PROJECT_ROOT}" diff --quiet HEAD -- "postgres/migrations/221_normalization_selected_elements_pk_join.sql" \
    || fail "migration 221 file has uncommitted local changes -- refusing to compute a checksum from git HEAD that would not reflect what's actually on disk. Commit or discard the change first."
EXPECTED_221_SHA256="$(git -C "${PROJECT_ROOT}" show "HEAD:postgres/migrations/221_normalization_selected_elements_pk_join.sql" | sha256sum | awk '{print $1}')"
echo "Expected migration-221 checksum (from this checkout's git HEAD blob): ${EXPECTED_221_SHA256}"

# ----------------------------------------------------------------------------
# 5. Evidence file.
# ----------------------------------------------------------------------------
mkdir -p "${EVIDENCE_DIR}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
MODE_TAG="$([[ ${EXECUTE} -eq 1 ]] && echo execute || echo dryrun)"
EVIDENCE_FILE="${EVIDENCE_DIR}/${TS}-${MODE_TAG}.log"
echo "Evidence file: ${EVIDENCE_FILE}"
{
    echo "# Migration 221 staging gate evidence"
    echo "# started_at (UTC): ${TS}"
    echo "# mode: ${MODE_TAG}"
    echo "# baseline_mode: ${BASELINE_MODE}${REWIND_INTERVAL:+ (rewind_interval=${REWIND_INTERVAL})}"
    echo "# hist_start: ${HIST_START}"
    echo "# hist_end: ${HIST_END}"
    echo "# recon_overlap_secs: ${RECON_OVERLAP_SECS}"
    echo "# deploy_221_after: ${DEPLOY_221_AFTER}"
    echo "# expected_221_sha256: ${EXPECTED_221_SHA256}"
    if [[ "${EXECUTE}" -eq 1 ]]; then
        echo "# authorized_by: ${EMS_GATE_AUTHORIZED_BY}"
        echo "# authorization_ref: ${EMS_GATE_AUTHORIZATION_REF}"
    fi
    echo
} > "${EVIDENCE_FILE}"

# ----------------------------------------------------------------------------
# 6. Durable capture-for-restoration (EXECUTE mode only). Independent,
#    read-only queries -- NOT the .sql's temp tables -- so restoration
#    survives even if the main gate connection is aborted by ON_ERROR_STOP
#    mid-PHASE-6/7 (see the .sql header's CORRECTION note).
#
#    Field separator: single character, held in $FS, applied consistently.
#    An earlier draft hard-coded '|' inline and only defended against it
#    colliding with real data inside last_error, via
#    `replace(last_error,'|','_')`, leaving config::text (arbitrary JSONB
#    content) undefended. Every dynamic/free-text field below (last_error,
#    config::text) now gets the same `replace(...,"${FS}",'_')` guard, so no
#    field is special-cased, and every `read`/split site uses `IFS="${FS}"`
#    rather than a repeated literal. FS must stay a SINGLE character:
#    bash's `IFS=... read` splits on any character IN $IFS, not on a
#    multi-character substring, so a 2+ character token here would silently
#    split in the wrong places. A raw non-printable byte was also
#    deliberately avoided: it would force bash's `printf %q`, in
#    remote_psql()'s quoting of this SQL string for the SSH hop, into
#    `$'...'` ANSI-C quoting -- syntax a POSIX `sh`/`dash` login shell does
#    not understand -- turning a narrow data-collision risk into a
#    guaranteed-on-every-call transport risk. A plain printable ASCII
#    character keeps %q's output in ordinary, portable backslash-escaped
#    form.
#
#    Capture ORDER matters and is deliberately NOT "capture everything, then
#    pause": Job 1000 runs on a live 1-minute schedule. If
#    telemetry.pipeline_state were captured BEFORE the pause took effect, a
#    scheduled run could land in the gap between the read and the pause and
#    make the captured baseline stale (restoring to a watermark Job 1000 has
#    already moved past). Job 1000's OWN config (schedule_interval,
#    max_runtime, etc.) has no such race -- only its `scheduled` flag is
#    about to change, and only by this script's own next call -- so it is
#    captured first; pipeline_state is captured ONLY AFTER the pause command
#    has been issued, closing the race for the value that actually matters.
#    (The .sql's own PHASE 1e/1f still separately re-check, on the following
#    connection, that no run is RUNNING and no competing session holds the
#    advisory lock, before any bounded CALL.)
# ----------------------------------------------------------------------------
FS='|'

JOB_CAPTURED=0
PIPELINE_CAPTURED=0
CAPTURED_PIPELINE_STATE=""   # \x1f-delimited: last_received_at, last_started_at, last_completed_at, last_inserted_rows, last_status, last_error, updated_at
CAPTURED_JOB_ID=""
CAPTURED_JOB_SCHEDULE_INTERVAL=""
CAPTURED_JOB_MAX_RUNTIME=""
CAPTURED_JOB_MAX_RETRIES=""
CAPTURED_JOB_RETRY_PERIOD=""
CAPTURED_JOB_SCHEDULED=""
CAPTURED_JOB_CONFIG=""

capture_job_config() {
    echo "--- Capturing Job 1000 config for restoration (before pause) ---"

    local job_row
    job_row="$(remote_psql -tAc "
        SELECT job_id || '${FS}' || schedule_interval || '${FS}' || max_runtime || '${FS}' ||
               max_retries || '${FS}' || retry_period || '${FS}' || scheduled || '${FS}' ||
               replace(coalesce(config::text,'{}'), '${FS}', '_')
        FROM timescaledb_information.jobs
        WHERE proc_schema = 'telemetry' AND proc_name = 'run_normalization_job';
    " <<< "")"
    [[ -n "${job_row}" ]] || fail "could not capture Job 1000 (telemetry.run_normalization_job) config -- refusing to proceed with --execute"

    IFS="${FS}" read -r CAPTURED_JOB_ID CAPTURED_JOB_SCHEDULE_INTERVAL CAPTURED_JOB_MAX_RUNTIME \
        CAPTURED_JOB_MAX_RETRIES CAPTURED_JOB_RETRY_PERIOD CAPTURED_JOB_SCHEDULED CAPTURED_JOB_CONFIG <<< "${job_row}"

    {
        echo "--- CAPTURED job1000 config (restoration source of record) ---"
        echo "job1000: id=${CAPTURED_JOB_ID} schedule_interval=${CAPTURED_JOB_SCHEDULE_INTERVAL} max_runtime=${CAPTURED_JOB_MAX_RUNTIME} max_retries=${CAPTURED_JOB_MAX_RETRIES} retry_period=${CAPTURED_JOB_RETRY_PERIOD} scheduled=${CAPTURED_JOB_SCHEDULED} config=${CAPTURED_JOB_CONFIG}"
        echo
    } | tee -a "${EVIDENCE_FILE}"

    # As soon as Job 1000's config is captured, the trap can meaningfully
    # restore it even if something below fails before pipeline_state is
    # ever captured or mutated.
    JOB_CAPTURED=1
}

pause_job1000() {
    echo "--- Pausing Job 1000 (job_id=${CAPTURED_JOB_ID}) ---"
    remote_psql -c "SELECT alter_job(${CAPTURED_JOB_ID}, scheduled => false);" <<< "" | tee -a "${EVIDENCE_FILE}"
}

capture_pipeline_state() {
    echo "--- Capturing telemetry.pipeline_state for restoration (after pause) ---"

    CAPTURED_PIPELINE_STATE="$(remote_psql -tAc "
        SELECT coalesce(last_received_at::text,'')  || '${FS}' ||
               coalesce(last_started_at::text,'')    || '${FS}' ||
               coalesce(last_completed_at::text,'')  || '${FS}' ||
               last_inserted_rows                    || '${FS}' ||
               last_status                           || '${FS}' ||
               replace(coalesce(last_error,''), '${FS}', '_') || '${FS}' ||
               updated_at::text
        FROM telemetry.pipeline_state
        WHERE pipeline_name = 'normalized_points';
    " <<< "")"
    [[ -n "${CAPTURED_PIPELINE_STATE}" ]] || fail "could not capture telemetry.pipeline_state (normalized_points row) after pausing Job 1000 -- refusing to proceed with --execute (Job 1000 remains paused; rerun restoration manually from the job1000 config already printed above before leaving staging)"

    {
        echo "--- CAPTURED pipeline_state (restoration source of record) ---"
        echo "pipeline_state: ${CAPTURED_PIPELINE_STATE}"
        echo
    } | tee -a "${EVIDENCE_FILE}"

    PIPELINE_CAPTURED=1
}

# ----------------------------------------------------------------------------
# 7. Restoration trap. Idempotent: safe to run whether or not the .sql's own
#    PHASE 8 already restored pipeline_state on the same connection, and safe
#    to run whether or not this run ever captured/paused anything. Restores
#    Job 1000's config whenever JOB_CAPTURED=1 (independent of whether
#    pipeline_state was ever captured -- e.g. capture_pipeline_state() itself
#    failed right after the pause) and restores pipeline_state only when
#    PIPELINE_CAPTURED=1 (there is otherwise nothing valid to restore it to,
#    and per the capture-ordering note above it was never mutated in that
#    case either, since PHASE 6/7 only run after both captures succeed).
# ----------------------------------------------------------------------------
RESTORED=0
restore_state() {
    local exit_code=$?
    if [[ "${JOB_CAPTURED}" -ne 1 || "${RESTORED}" -eq 1 ]]; then
        return "${exit_code}"
    fi
    RESTORED=1

    echo "--- Restoring Job 1000 to captured baseline ---" | tee -a "${EVIDENCE_FILE}"

    # `|| true`: a failed remote_psql here (e.g. connectivity lost) must not
    # let `set -e` abort this trap before the RESTORE_FAILED message below is
    # printed -- an uncaught failure INSIDE a trap handler is exactly the
    # "died silently mid-cleanup" outcome this script must avoid.
    # CORRECTION (2026-08-30, real staging --execute run): this used to be
    # `-c "SELECT alter_job(:'job_id'::integer, ...)"`. `psql -c` NEVER
    # performs :name/:'name' substitution -- confirmed by direct local
    # reproduction (psql -v x=hello -c "SELECT :'x';" fails identically,
    # while the same text via -f -/stdin substitutes correctly) and
    # independently by re-tracing the full SSH -> bash -c -> docker compose
    # exec -> psql argv chain, which showed the -c argument arriving at psql
    # completely intact -- so this was never a transport/quoting problem.
    # -f - (matching the main gate invocation's already-proven mechanism)
    # does perform substitution, so the SQL is now piped via stdin instead
    # of passed as a -c argument. No other change to this call's logic,
    # captured values, or the failure-handling below it.
    remote_psql -v ON_ERROR_STOP=1 \
        -v job_id="${CAPTURED_JOB_ID}" \
        -v job_schedule="${CAPTURED_JOB_SCHEDULE_INTERVAL}" \
        -v job_max_runtime="${CAPTURED_JOB_MAX_RUNTIME}" \
        -v job_max_retries="${CAPTURED_JOB_MAX_RETRIES}" \
        -v job_retry_period="${CAPTURED_JOB_RETRY_PERIOD}" \
        -v job_scheduled="${CAPTURED_JOB_SCHEDULED}" \
        -v job_config="${CAPTURED_JOB_CONFIG}" \
        -f - << 'SQL' 2>&1 | tee -a "${EVIDENCE_FILE}" || true
        SELECT alter_job(
            :'job_id'::integer,
            schedule_interval => :'job_schedule'::interval,
            max_runtime       => :'job_max_runtime'::interval,
            max_retries       => :'job_max_retries'::integer,
            retry_period      => :'job_retry_period'::interval,
            scheduled         => :'job_scheduled'::boolean,
            config            => :'job_config'::jsonb
        );
SQL
    JOB_RESTORE_RC=${PIPESTATUS[0]:-1}
    if [[ "${JOB_RESTORE_RC}" -ne 0 ]]; then
        echo "RESTORE_FAILED (job1000): MANUAL INTERVENTION REQUIRED — re-run the alter_job() above by hand against staging using the captured values printed earlier in ${EVIDENCE_FILE}." | tee -a "${EVIDENCE_FILE}"
    fi

    if [[ "${PIPELINE_CAPTURED}" -eq 1 ]]; then
        echo "--- Restoring telemetry.pipeline_state to captured baseline ---" | tee -a "${EVIDENCE_FILE}"

        local r_last_received r_last_started r_last_completed r_last_rows r_last_status r_last_error r_updated
        IFS="${FS}" read -r r_last_received r_last_started r_last_completed r_last_rows r_last_status r_last_error r_updated <<< "${CAPTURED_PIPELINE_STATE}"

        # CORRECTION (2026-08-30, real staging --execute run): same defect and
        # same fix as the alter_job() restoration above -- psql -c never
        # substitutes :'var', -f -/stdin does. See that call's comment.
        remote_psql -v ON_ERROR_STOP=1 \
            -v r_last_received="${r_last_received}" \
            -v r_last_started="${r_last_started}" \
            -v r_last_completed="${r_last_completed}" \
            -v r_last_rows="${r_last_rows}" \
            -v r_last_status="${r_last_status}" \
            -v r_last_error="${r_last_error}" \
            -v r_updated="${r_updated}" \
            -f - << 'SQL' 2>&1 | tee -a "${EVIDENCE_FILE}" || true
            UPDATE telemetry.pipeline_state
            SET last_received_at   = NULLIF(:'r_last_received','')::timestamptz,
                last_started_at    = NULLIF(:'r_last_started','')::timestamptz,
                last_completed_at  = NULLIF(:'r_last_completed','')::timestamptz,
                last_inserted_rows = :'r_last_rows'::bigint,
                last_status        = :'r_last_status',
                last_error         = NULLIF(:'r_last_error',''),
                updated_at         = :'r_updated'::timestamptz
            WHERE pipeline_name = 'normalized_points';
SQL
        PIPELINE_RESTORE_RC=${PIPESTATUS[0]:-1}
        if [[ "${PIPELINE_RESTORE_RC}" -ne 0 ]]; then
            echo "RESTORE_FAILED (pipeline_state): MANUAL INTERVENTION REQUIRED — see captured baseline printed earlier in ${EVIDENCE_FILE}." | tee -a "${EVIDENCE_FILE}"
        fi

        echo "--- Verifying pipeline_state restoration ---" | tee -a "${EVIDENCE_FILE}"
        # `|| true` here too: if connectivity is what's actually broken, this
        # verification query will fail the same way the restore itself would
        # have -- report that plainly rather than letting `set -e` kill the
        # trap before printing anything.
        local verify=""
        verify="$(remote_psql -tAc "
            SELECT coalesce(last_received_at::text,'')||'${FS}'||coalesce(last_started_at::text,'')||'${FS}'||coalesce(last_completed_at::text,'')||'${FS}'||last_inserted_rows||'${FS}'||last_status||'${FS}'||replace(coalesce(last_error,''),'${FS}','_')||'${FS}'||updated_at::text
            FROM telemetry.pipeline_state WHERE pipeline_name='normalized_points';
        " <<< "" 2>&1)" || verify=""

        if [[ -z "${verify}" ]]; then
            echo "RESTORE_VERIFICATION_UNREACHABLE: could not re-read telemetry.pipeline_state to confirm restoration (staging connectivity may be down). Manually confirm against the captured baseline above before treating staging as clean: ${CAPTURED_PIPELINE_STATE}" | tee -a "${EVIDENCE_FILE}"
        elif [[ "${verify}" == "${CAPTURED_PIPELINE_STATE}" ]]; then
            echo "RESTORE_OK: telemetry.pipeline_state matches the captured baseline." | tee -a "${EVIDENCE_FILE}"
        else
            echo "RESTORE_MISMATCH: telemetry.pipeline_state does not match the captured baseline. MANUAL REVIEW REQUIRED." | tee -a "${EVIDENCE_FILE}"
            echo "  captured: ${CAPTURED_PIPELINE_STATE}" | tee -a "${EVIDENCE_FILE}"
            echo "  current:  ${verify}" | tee -a "${EVIDENCE_FILE}"
        fi
    else
        echo "pipeline_state was never captured (failure occurred before capture_pipeline_state() completed) -- nothing to restore there; Job 1000 restoration above is the only action needed." | tee -a "${EVIDENCE_FILE}"
    fi

    return "${exit_code}"
}
trap restore_state EXIT INT TERM

# ----------------------------------------------------------------------------
# 8. Run the gate.
# ----------------------------------------------------------------------------
if [[ "${EXECUTE}" -eq 1 ]]; then
    capture_job_config
    pause_job1000
    capture_pipeline_state
fi

GATE_EXECUTE_VAL="off"
[[ "${EXECUTE}" -eq 1 ]] && GATE_EXECUTE_VAL="on"
PROBE_VAL="off"
[[ "${PROBE_IDONLY_CONTRAST}" -eq 1 ]] && PROBE_VAL="on"

# NOTE: requires GNU `date` (coreutils) for `-d` on the operator's own
# machine -- satisfied by Linux and Git-Bash/MSYS on Windows, but NOT by
# stock macOS/BSD `date`. OPEN DESIGN QUESTION — requires review if the
# gate is ever run from macOS without GNU coreutils installed (`brew
# install coreutils` provides `gdate`, which would need to be substituted
# here).
HIST_WINDOW_MINUTES="$(( ( $(date -u -d "${HIST_END}" +%s) - $(date -u -d "${HIST_START}" +%s) ) / 60 ))"

echo
echo "--- Running gate ($([[ ${EXECUTE} -eq 1 ]] && echo EXECUTE || echo DRY-RUN)) ---"
GATE_STATUS=0
remote_psql \
    -v env_confirm=staging \
    -v gate_execute="${GATE_EXECUTE_VAL}" \
    -v expected_221_sha256="${EXPECTED_221_SHA256}" \
    -v deploy_221_after="${DEPLOY_221_AFTER}" \
    -v baseline_mode="${BASELINE_MODE}" \
    -v rewind_interval="${REWIND_INTERVAL:-0 seconds}" \
    -v hist_start="${HIST_START}" \
    -v hist_end="${HIST_END}" \
    -v hist_window_minutes="${HIST_WINDOW_MINUTES}" \
    -v recon_overlap_secs="${RECON_OVERLAP_SECS}" \
    -v probe_idonly_contrast="${PROBE_VAL}" \
    -f - < "${GATE_SQL}" 2>&1 | tee -a "${EVIDENCE_FILE}" || GATE_STATUS=$?

# `restore_state` runs automatically via the EXIT trap from here, whether
# GATE_STATUS is 0 or non-zero.

# ----------------------------------------------------------------------------
# 9. Verdict.
#    Mirrors the .sql's own PHASE 9 semantics: this script does not invent a
#    numeric performance bar. It classifies PASS/FAIL/INCONCLUSIVE from the
#    gate's own printed NOTICEs/ERRORs, for quick triage; the evidence file
#    is the record a reviewer actually reads.
# ----------------------------------------------------------------------------
echo
echo "============================================================"
if [[ "${EXECUTE}" -eq 1 ]] && grep -q 'RESTORE_FAILED\|RESTORE_MISMATCH\|RESTORE_VERIFICATION_UNREACHABLE' "${EVIDENCE_FILE}"; then
    # Checked first, and independent of GATE_STATUS/ERROR grep below: an
    # unconfirmed or failed restoration is always the most important thing
    # to surface, even if the gate run itself otherwise looked clean.
    echo "VERDICT: INCONCLUSIVE -- restoration was NOT confirmed (RESTORE_FAILED / RESTORE_MISMATCH / RESTORE_VERIFICATION_UNREACHABLE present). MANUAL STAGING REVIEW REQUIRED before treating staging as clean, regardless of the gate's own result below. Review ${EVIDENCE_FILE}."
    GATE_STATUS=1
elif grep -q '^psql:.*ERROR' "${EVIDENCE_FILE}" || grep -q '^ERROR:' "${EVIDENCE_FILE}"; then
    if [[ "${EXECUTE}" -eq 1 ]]; then
        echo "VERDICT: INCONCLUSIVE/FAIL -- a STOP or FAIL fired during an EXECUTE run. Review ${EVIDENCE_FILE}. Confirm RESTORE_OK above before treating staging as clean."
    else
        echo "VERDICT: INCONCLUSIVE (dry-run) -- a STOP fired during preflight/recon. Fix the underlying condition before scheduling --execute. Review ${EVIDENCE_FILE}."
    fi
    GATE_STATUS=${GATE_STATUS:-1}
elif [[ "${GATE_STATUS}" -ne 0 ]]; then
    echo "VERDICT: INCONCLUSIVE -- gate exited non-zero ($GATE_STATUS) with no ERROR line matched; inspect ${EVIDENCE_FILE} manually."
else
    if grep -q 'EQUIVALENCE_LIMITATION_ZERO_DRIVING_ROWS' "${EVIDENCE_FILE}"; then
        echo "NOTE: EQUIVALENCE_LIMITATION_ZERO_DRIVING_ROWS fired (see PHASE 4/E-2) -- Equivalence is PASS for non-corruption only; it did NOT exercise the changed join against fresh SELECTED/FAILED rows. Treat join-correctness as resting on PHASE 5's EXPLAIN evidence for this run."
    fi
    if [[ "${EXECUTE}" -eq 1 ]]; then
        echo "VERDICT INPUT: EXECUTE run completed with no ERROR and restoration confirmed (RESTORE_OK). Correctness/bounded/equivalence = PASS (per PHASE 9 in the .sql)."
        echo "Performance = EVIDENCE ONLY -- read the MEASUREMENTS table in ${EVIDENCE_FILE}; no numeric threshold is applied here."
        echo "Reviewer: also read PHASE 5's EXPLAIN plan shape."
    else
        echo "VERDICT: DRY-RUN clean -- preflight + reconnaissance + EXPLAIN probe passed with no ERROR."
        echo "This is a prerequisite for scheduling an authorized --execute run, not a substitute for one."
    fi
fi
echo "Evidence: ${EVIDENCE_FILE}"
echo "============================================================"

exit "${GATE_STATUS}"
