#!/usr/bin/env bash
# LOCAL ONLY (see lib.sh): each case = fresh copy of a template
# database, one mutation, run the script read-only, gate it, compare the set
# of failing keys with the expected set (environment-specific keys excluded).
set -u
source "$(dirname "$0")/lib.sh"; H="$(cd "$(dirname "$0")" && pwd)"; O="$B2T_WORK/out"
ENV_PRE="P10.failures P10.paused P5.bridge P5.capture_set JOBS.1100 JOBS.1103 SESSION.identity"
ENV_POST="HEALTH.1h_checkpoint HEALTH.failures HEALTH.job1100 HEALTH.job1103 HEALTH.paused POST.bridge SESSION.identity"
pass=0; fail=0
case_run() {  # kind template name "expected extra failing keys" mutation-sql
  local kind=$1 tmpl=$2 name=$3 want=$4 sql=$5 db=b2n_$3
  adm -d postgres -c "DROP DATABASE IF EXISTS $db WITH (FORCE)" -c "CREATE DATABASE $db TEMPLATE $tmpl" >/dev/null
  [[ -n "$sql" ]] && { printf '%s\n' "$sql" | adm -d $db >/dev/null || { echo "  mutation failed: $name"; }; }
  [[ -n "${BG:-}" ]] && { eval "$BG" & sleep 12; }
  ro $db < $D/prod_b2_$kind.sql > $O/neg_$name.txt 2>&1; local rc=$?
  gate $kind $O/neg_$name.txt --rc $rc > $O/neg_$name.gate; local grc=$?
  [[ -n "${BG:-}" ]] && wait
  local envk; [[ $kind == precheck ]] && envk=$ENV_PRE || envk=$ENV_POST
  local got; got=$(grep -oE '^  line [0-9]+: [^ ]+ FAIL' $O/neg_$name.gate | awk '{print $3}' | grep -vxF -f <(tr ' ' '\n' <<<"$envk") | sort | tr '\n' ' ')
  local other; other=$(grep -E '^  ' $O/neg_$name.gate | grep -vE 'line [0-9]+: [^ ]+ FAIL$' | tr '\n' ';')
  local exp; exp=$(tr ' ' '\n' <<<"$want" | grep . | sort | tr '\n' ' ')
  if [[ $grc == 1 && "$got" == "$exp" && -z "$other" ]] || [[ -z "$want" && "$got" == "" && -z "$other" ]]; then
    pass=$((pass+1)); echo "ok   $kind/$name gate_rc=$grc failing=[${got% }]"
  else
    fail=$((fail+1)); echo "BAD  $kind/$name gate_rc=$grc got=[$got] want=[$exp] other=[$other]"
  fi
  adm -d postgres -c "DROP DATABASE IF EXISTS $db WITH (FORCE)" >/dev/null
}
TAMPER="DO \$\$ BEGIN EXECUTE replace(pg_get_functiondef('analytics.get_canonical_energy_read(bigint, uuid, timestamptz, timestamptz, text, text)'::regprocedure), E'\$function\$\nDECLARE', E'\$function\$\n-- tampered\nDECLARE'); END \$\$;"
# ---- precheck on the B1 state
case_run precheck b2t_b1 baseline "" ""
case_run precheck b2t_b1 checksum "P1.ledger" "UPDATE admin.schema_migrations SET checksum_sha256 = repeat('0', 64) WHERE migration_id LIKE '269_%';"
case_run precheck b2t_b1 extra263 "P1.ledger P2.pending" "INSERT INTO admin.schema_migrations SELECT '263_asset_energy_consumption_asset_points_attribution', 'postgres/migrations/263_x.sql', checksum_sha256, applied_at, applied_by, execution_ms, application_mode FROM admin.schema_migrations WHERE migration_id LIKE '269_%';"
case_run precheck b2t_b1 missing269 "P1.ledger P2.pending" "DELETE FROM admin.schema_migrations WHERE migration_id LIKE '269_%';"
case_run precheck b2t_b1 foreignrow "P1.ledger P2.ledger_in_manifest" "INSERT INTO admin.schema_migrations SELECT '307_not_in_b2_manifest', 'postgres/migrations/307_x.sql', checksum_sha256, applied_at, applied_by, execution_ms, application_mode FROM admin.schema_migrations WHERE migration_id LIKE '269_%';"
case_run precheck b2t_b1 utc_default "PRE.runner_tz PRE.283_viewdef" "ALTER ROLE ems_admin IN DATABASE b2n_utc_default SET TimeZone = 'UTC';"
case_run precheck b2t_b1 b2fn_exists "PRE.b2_absent" "CREATE FUNCTION analytics.energy_direction_status() RETURNS int LANGUAGE sql AS 'SELECT 1';"
case_run precheck b2t_b1 trigger_exists "PRE.trigger_absent" "CREATE TRIGGER sites_prevent_timezone_change_with_telemetry BEFORE UPDATE ON metadata.sites FOR EACH ROW EXECUTE FUNCTION metadata.prevent_site_organization_change();"
case_run precheck b2t_b1 canonical_changed "PRE.canonical_269" "$TAMPER"
BG="(echo 'SET application_name = holder; BEGIN; LOCK TABLE metadata.sites IN ACCESS SHARE MODE;'; sleep 20; echo 'COMMIT;') | docker exec -i \"$B2T_CONTAINER\" psql -X -q -U ems_admin -d b2n_sites_lock >/dev/null" \
case_run precheck b2t_b1 sites_lock "LOCK.idle_xact LOCK.sites" ""
# ---- postcheck on the B2 state
case_run postcheck b2t_b2 baseline "" ""
case_run postcheck b2t_b2 missing286 "LEDGER.rows LEDGER.286 LEDGER.order LEDGER.all149" "DELETE FROM admin.schema_migrations WHERE migration_id LIKE '286_%';"
case_run postcheck b2t_b2 checksum283 "LEDGER.283 LEDGER.all149" "UPDATE admin.schema_migrations SET checksum_sha256 = repeat('0', 64) WHERE migration_id LIKE '283_%';"
case_run postcheck b2t_b2 order "LEDGER.order" "UPDATE admin.schema_migrations SET applied_at = (SELECT applied_at FROM admin.schema_migrations WHERE migration_id LIKE '282_%') - interval '1 second' WHERE migration_id LIKE '283_%';"
case_run postcheck b2t_b2 early_b1_row "LEDGER.order" "UPDATE admin.schema_migrations SET applied_at = now() + interval '1 hour' WHERE migration_id LIKE '269_%';"
case_run postcheck b2t_b2 canonical_changed "POST.fn_canonical_read" "$TAMPER"
case_run postcheck b2t_b2 public_grant "POST.fn_catalog" "GRANT EXECUTE ON FUNCTION analytics.get_portal_analytics_catalog(bigint, uuid) TO PUBLIC;"
case_run postcheck b2t_b2 grafana_revoked "POST.fn_canonical_read" "REVOKE EXECUTE ON FUNCTION analytics.get_canonical_energy_read(bigint, uuid, timestamptz, timestamptz, text, text) FROM grafana_reader;"
case_run postcheck b2t_b2 trigger_disabled "POST.tz_trigger" "ALTER TABLE metadata.sites DISABLE TRIGGER sites_prevent_timezone_change_with_telemetry;"
case_run postcheck b2t_b2 dropped_back "POST.dropped" "CREATE FUNCTION analytics.get_portal_asset_energy_series(bigint, uuid, uuid[], timestamptz, timestamptz, text) RETURNS int LANGUAGE sql AS 'SELECT 1';"
case_run postcheck b2t_b2 comment "POST.availability_comment" "COMMENT ON FUNCTION analytics.get_portal_analytics_energy_availability(bigint, uuid) IS 'x';"
case_run postcheck b2t_b2 fn_missing "POST.fn_rollup_15min_range" "DROP FUNCTION analytics.energy_semantic_rollup_15min_range(uuid, uuid[], timestamptz, timestamptz) CASCADE;"
echo "NEGATIVE CASES: $pass ok, $fail bad"; [[ $fail == 0 ]]
