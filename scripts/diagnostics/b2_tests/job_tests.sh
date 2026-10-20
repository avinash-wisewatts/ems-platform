#!/usr/bin/env bash
# LOCAL ONLY (see lib.sh). Job-state cases for the B2 precheck (B1-state copies) and
# postcheck (B2-state copies): fixture + one mutation + optionally a session
# that makes TimescaleDB's job_stats report job 1063 as 'Running'.
# Usage: job_tests.sh [precheck|postcheck|all]
set -u
source "$(dirname "$0")/lib.sh"; H="$(cd "$(dirname "$0")" && pwd)"; O="$B2T_WORK/out"
WHICH=${1:-all}
ENV_PRE="SESSION.identity P5.bridge P5.capture_set"
ENV_POST="SESSION.identity POST.bridge HEALTH.1h_checkpoint"
pass=0; fail=0
# kind name want running(yes/no) mutation
jc() {
  local kind=$1 name=$2 want=$3 running=$4 sql=$5 db=b2j_$2 tmpl
  [[ $WHICH != all && $WHICH != $kind ]] && return
  [[ $kind == precheck ]] && tmpl=b2t_b1 || tmpl=b2t_b2
  adm -d postgres -c "DROP DATABASE IF EXISTS $db WITH (FORCE)" -c "CREATE DATABASE $db TEMPLATE $tmpl" >/dev/null
  adm -d $db < $H/jobs_fixture.sql >/dev/null || echo "  fixture failed: $name"
  [[ -n "$sql" ]] && { printf '%s\n' "$sql" | adm -d $db >/dev/null || echo "  mutation failed: $name"; }
  local bg=""
  if [[ $running == yes ]]; then
    local app; app=$(adm -d $db -c "SELECT application_name FROM _timescaledb_catalog.bgw_job WHERE id = 1063")
    docker exec -i "$B2T_CONTAINER" psql -X -q -U ems_admin -d $db -c "SET application_name = '$app'" -c "SELECT pg_sleep(8)" >/dev/null 2>&1 & bg=$!
    sleep 2
  fi
  ro $db < $D/prod_b2_$kind.sql > $O/job_${kind}_$name.txt 2>&1; local rc=$?
  gate $kind $O/job_${kind}_$name.txt --rc $rc > $O/job_${kind}_$name.gate; local grc=$?
  [[ -n $bg ]] && wait $bg
  local envk; [[ $kind == precheck ]] && envk=$ENV_PRE || envk=$ENV_POST
  local got other exp line
  got=$(grep -oE '^  line [0-9]+: [^ ]+ FAIL' $O/job_${kind}_$name.gate | awk '{print $3}' | grep -vxF -f <(tr ' ' '\n' <<<"$envk") | sort | tr '\n' ' ')
  other=$(grep -E '^  ' $O/job_${kind}_$name.gate | grep -vE 'line [0-9]+: [^ ]+ FAIL$' | tr '\n' ';')
  exp=$(tr ' ' '\n' <<<"$want" | grep . | sort | tr '\n' ' ')
  line=$(grep -E '^(JOBS|HEALTH)\.(job)?1063 ' $O/job_${kind}_$name.txt | head -1)
  if [[ "$want" == SQLERROR ]]; then
    if [[ $grc == 1 && $rc != 0 ]] && grep -q "psql exit status $rc" $O/job_${kind}_$name.gate; then pass=$((pass+1)); echo "ok   $kind/$name psql_rc=$rc gate_rc=$grc ($(grep -m1 -oE 'ERROR: .{0,70}' $O/job_${kind}_$name.txt))"
    else fail=$((fail+1)); echo "BAD  $kind/$name psql_rc=$rc gate_rc=$grc"; fi
  elif [[ "$got" == "$exp" && -z "$other" ]]; then
    pass=$((pass+1)); echo "ok   $kind/$name failing=[${got% }] | $line"
  else
    fail=$((fail+1)); echo "BAD  $kind/$name got=[$got] want=[$exp] other=[$other] | $line"
  fi
  adm -d postgres -c "DROP DATABASE IF EXISTS $db WITH (FORCE)" >/dev/null
}
S="_timescaledb_internal.bgw_job_stat"
RUN="UPDATE $S SET last_start = now() - interval '5 seconds', last_finish = '-infinity', total_runs = total_runs + 1 WHERE job_id = 1063;"
PREV_FAIL="UPDATE $S SET last_run_success = false, consecutive_failures = 1, total_failures = total_failures + 1 WHERE job_id = 1063; UPDATE $S SET total_failures = total_failures - 1 WHERE job_id = 1053;"
for kind in precheck postcheck; do
  if [[ $kind == precheck ]]; then J=JOBS.1063; J1100=JOBS.1100; J1103=JOBS.1103; P=P10.failures; else J=HEALTH.job1063; J1100=HEALTH.job1100; J1103=HEALTH.job1103; P=HEALTH.failures; fi
  jc $kind clean "" no ""
  jc $kind running_prev_success "" yes "$RUN"
  jc $kind running_prev_failed "$J $P" yes "$PREV_FAIL $RUN"
  jc $kind running_failure_count_changed "$J $P" yes "UPDATE $S SET total_failures = total_failures + 1 WHERE job_id = 1063; $RUN"
  jc $kind running_never_succeeded "$J" yes "UPDATE $S SET last_successful_finish = '-infinity' WHERE job_id = 1063; $RUN"
  jc $kind running_contradictory_consecutive "$J" yes "UPDATE $S SET consecutive_failures = 2 WHERE job_id = 1063; $RUN"
  jc $kind not_running_last_failed "$J $P" no "$PREV_FAIL"
  jc $kind not_running_null_status_crashed "$J" no "$RUN"
  jc $kind not_running_never_finished "$J" no "UPDATE $S SET last_start = '-infinity', last_finish = '-infinity', last_successful_finish = '-infinity' WHERE job_id = 1063;"
  jc $kind missing_stats_row "$J" no "DELETE FROM $S WHERE job_id = 1063;"
  jc $kind missing_job "$J1103" no "DELETE FROM $S WHERE job_id = 1103; DELETE FROM _timescaledb_catalog.bgw_job WHERE id = 1103;"
  jc $kind paused_energy_job "$J" no "UPDATE _timescaledb_catalog.bgw_job SET scheduled = false WHERE id = 1063;"
  jc $kind other_job_failed_while_1063_runs "$J1100 $P" yes "UPDATE $S SET last_run_success = false, consecutive_failures = 1, total_failures = 1 WHERE job_id = 1100; UPDATE $S SET total_failures = 2839 WHERE job_id = 1053; $RUN"
  jc $kind sql_error SQLERROR no "ALTER TABLE $S RENAME TO bgw_job_stat_renamed;"
done
echo "JOB CASES: $pass ok, $fail bad"; [[ $fail == 0 ]]
