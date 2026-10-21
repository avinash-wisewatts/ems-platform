# Shared settings for the B2 precheck/postcheck tests. Sourced, not run.
#
# LOCAL ONLY. Everything runs in the disposable test container from
# compose.test.yaml (docker compose -f compose.test.yaml up -d), never against
# staging or production. Generated databases are b2e2e, b2t_b1, b2t_b2 and
# short-lived b2n_* / b2j_* copies; outputs go to $B2T_WORK, outside the repo.
#
# Order: rebuild_templates.sh (once, ~6 min), then gate_tests.sh,
# neg_tests.sh and job_tests.sh in any order. Each prints "... N ok, M bad"
# and exits non-zero if any case is bad.
D="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"         # scripts/diagnostics
REPO="$(cd "$D/../.." && pwd)"
B2T_CONTAINER=${B2T_CONTAINER:-ems-timescaledb-test}
B2T_WORK=${B2T_WORK:-${TMPDIR:-/tmp}/ems_b2_tests}
mkdir -p "$B2T_WORK/out"
if [[ -z ${PYTHON:-} ]]; then
  if python3 -c '' >/dev/null 2>&1; then PYTHON=python3; else PYTHON=python; fi
fi
adm() { docker exec -i "$B2T_CONTAINER" psql -X -q -A -t -v ON_ERROR_STOP=1 -U ems_admin "$@"; }
# The same session settings the runbook uses on production.
ro() {
  docker exec -i -e PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=30s -c lock_timeout=2s' \
    "$B2T_CONTAINER" psql -X -q -P pager=off -U ems_admin -d "$1"
}
gate() { "$PYTHON" -I "$D/prod_b2_gate.py" "$@"; }
