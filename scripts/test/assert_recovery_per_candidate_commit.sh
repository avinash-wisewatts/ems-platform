#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# WiseWatts EMS -- migration 203 regression test runner
#
# Runs the declarative assertions (A, D, G, H, structural) in
# assert_recovery_per_candidate_commit.sql, then separately proves tests B
# and C -- that a mid-candidate cancellation rolls back only the in-flight
# candidate, leaving prior candidates committed and the cancelled one free
# of partial state -- against a throwaway scratch table using the exact
# same loop shape telemetry.recover_failed_raw_messages() now relies on
# (FOR ... FOR UPDATE SKIP LOCKED LOOP ... COMMIT; END LOOP;, invoked via a
# nested CALL from a job-shaped wrapper procedure). This requires real
# backend cancellation mid-statement, which is not expressible as a single
# declarative SQL script -- hence the shell orchestration here rather than
# in the .sql file.
#
# Safety: the scratch table/procedures are created in and dropped from the
# disposable ems_test database only (compose.test.yaml's timescaledb-test
# service). Nothing here touches telemetry.* or any non-test database.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PSQL=(docker compose -f "${PROJECT_ROOT}/compose.test.yaml" exec -T timescaledb-test psql -X -U ems_admin -d ems_test)

echo "[recovery-per-candidate-commit] Running declarative assertions (A, D, G, H, structural)..."
"${PSQL[@]}" -v ON_ERROR_STOP=1 -f - < "${SCRIPT_DIR}/assert_recovery_per_candidate_commit.sql"

echo
echo "[recovery-per-candidate-commit] Running mechanism test (B, C): mid-candidate cancellation durability..."

LOGFILE="$(mktemp)"
trap '"${PSQL[@]}" -v ON_ERROR_STOP=1 -c "DROP PROCEDURE IF EXISTS zz_commit_mech_wrapper(integer,jsonb); DROP PROCEDURE IF EXISTS zz_commit_mech_inner(); DROP TABLE IF EXISTS zz_commit_mech_queue;" >/dev/null 2>&1 || true; rm -f "${LOGFILE}"' EXIT

"${PSQL[@]}" -v ON_ERROR_STOP=1 -c "
DROP TABLE IF EXISTS zz_commit_mech_queue;
CREATE TABLE zz_commit_mech_queue(id serial PRIMARY KEY, done boolean DEFAULT false);
INSERT INTO zz_commit_mech_queue(id) SELECT g FROM generate_series(1,6) g;

CREATE OR REPLACE PROCEDURE zz_commit_mech_inner()
LANGUAGE plpgsql
AS \$\$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT id FROM zz_commit_mech_queue WHERE NOT done ORDER BY id FOR UPDATE SKIP LOCKED
    LOOP
        PERFORM pg_sleep(3);
        UPDATE zz_commit_mech_queue SET done = true WHERE id = r.id;
        RAISE NOTICE 'zz_commit_mech processed id=%, committing', r.id;
        COMMIT;
    END LOOP;
END;
\$\$;

-- Mirrors the real shape: TimescaleDB job scheduler's top-level
-- CALL telemetry.run_failed_message_recovery_job(job_id, config), which
-- nested-CALLs telemetry.recover_failed_raw_messages(p_limit).
CREATE OR REPLACE PROCEDURE zz_commit_mech_wrapper(job_id integer, config jsonb)
LANGUAGE plpgsql
AS \$\$
BEGIN
    CALL zz_commit_mech_inner();
END;
\$\$;
"

# Run the wrapper CALL in the background; each candidate takes ~3s.
"${PSQL[@]}" -c "CALL zz_commit_mech_wrapper(1, '{}'::jsonb);" > "${LOGFILE}" 2>&1 &
CALL_BGPID=$!

# Wait for candidate 2 to have committed, then cancel while candidate 3 is
# still mid pg_sleep -- proves cancellation lands mid-batch, not after it.
for _ in $(seq 1 60); do
    grep -q "processed id=2" "${LOGFILE}" 2>/dev/null && break
    sleep 0.5
done
if ! grep -q "processed id=2" "${LOGFILE}" 2>/dev/null; then
    echo "MECHANISM TEST FAILED: candidate 2 never committed within the timeout" >&2
    exit 1
fi

TARGET_PID="$(
    "${PSQL[@]}" -t -A -c "SELECT pid FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND query = \$q\$CALL zz_commit_mech_wrapper(1, '{}'::jsonb);\$q\$ LIMIT 1;"
)"
if [[ -z "${TARGET_PID}" ]]; then
    echo "MECHANISM TEST FAILED: could not find the backend running zz_commit_mech_wrapper to cancel" >&2
    exit 1
fi

CANCELLED="$("${PSQL[@]}" -t -A -c "SELECT pg_cancel_backend(${TARGET_PID});")"
if [[ "${CANCELLED}" != "t" ]]; then
    echo "MECHANISM TEST FAILED: pg_cancel_backend(${TARGET_PID}) did not report success" >&2
    exit 1
fi

wait "${CALL_BGPID}" || true

if ! grep -q "canceling statement due to user request" "${LOGFILE}"; then
    echo "MECHANISM TEST FAILED: expected the cancelled CALL to report 'canceling statement due to user request'; log was:" >&2
    cat "${LOGFILE}" >&2
    exit 1
fi

DONE_COUNT="$("${PSQL[@]}" -t -A -c "SELECT count(*) FROM zz_commit_mech_queue WHERE done;")"
CANDIDATE3_DONE="$("${PSQL[@]}" -t -A -c "SELECT done FROM zz_commit_mech_queue WHERE id = 3;")"

# TEST B: candidates 1 and 2 (committed before cancellation) must survive.
if [[ "${DONE_COUNT}" -lt 2 ]]; then
    echo "TEST B FAILED: expected at least 2 candidates to remain durably committed after cancellation, found ${DONE_COUNT}" >&2
    exit 1
fi
echo "TEST B passed: ${DONE_COUNT} candidate(s) committed before the cancellation remain durably committed afterward."

# TEST C: candidate 3 (in-flight at the moment of cancellation) must show
# no partial state -- either fully done, or not done at all, never a
# half-applied row (the UPDATE ... SET done=true is the only mutation, so
# "not done" here is the proof: the cancelled iteration's UPDATE never took
# effect).
if [[ "${CANDIDATE3_DONE}" != "f" ]]; then
    echo "TEST C FAILED: expected candidate 3 (in-flight at cancellation) to show done=false (no partial state), got done=${CANDIDATE3_DONE}" >&2
    exit 1
fi
echo "TEST C passed: the in-flight candidate at the moment of cancellation shows no partial state (done=false, its update was rolled back cleanly)."

echo
echo "[recovery-per-candidate-commit] All assertions (A-H, structural) passed."
