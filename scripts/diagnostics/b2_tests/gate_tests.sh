#!/usr/bin/env bash
# Output-contract cases for prod_b2_gate.py. The real outputs come from
# running both scripts read-only on the local templates; the "good" files turn
# their environment-specific FAIL lines into PASS. LOCAL ONLY -- see lib.sh.
set -u
source "$(dirname "$0")/lib.sh"
G="$B2T_WORK/gate"; mkdir -p "$G"
ro b2t_b1 < "$D/prod_b2_precheck.sql" > "$G/precheck.real.txt" 2>&1
ro b2t_b2 < "$D/prod_b2_postcheck.sql" > "$G/postcheck.real.txt" 2>&1
ok=0; bad=0
t() {  # kind file rc expected_gate_rc name
  gate "$1" "$2" --rc "$3" > "$G/$5.$1.gate" 2>&1; local r=$?
  if [[ $r == "$4" ]]; then ok=$((ok+1)); echo "ok   $1/$5 gate_rc=$r $(tail -1 "$G/$5.$1.gate")"; else bad=$((bad+1)); echo "BAD  $1/$5 gate_rc=$r want=$4"; cat "$G/$5.$1.gate"; fi
}
for kind in precheck postcheck; do
  real=$G/$kind.real.txt
  good=$G/$kind.good.txt; sed -E 's/ FAIL$/ PASS/' "$real" > "$good"
  t $kind "$good" 0 0 prodlike_pass
  t $kind "$real" 0 1 local_real
  t $kind "$good" 1 1 rc1
  t $kind "$good" 3 1 rc3
  sed '0,/ PASS$/s// FAIL/' "$good" > $G/f1; t $kind $G/f1 0 1 one_fail
  awk 'NR==6{next}1' "$good" > $G/f2; t $kind $G/f2 0 1 missing_line
  awk 'NR==6{print}1' "$good" > $G/f3; t $kind $G/f3 0 1 duplicate_line
  awk 'NR==6{print "ZZ.unknown extra PASS"}1' "$good" > $G/f4; t $kind $G/f4 0 1 unknown_key
  awk 'NR==6{print ""}1' "$good" > $G/f5; t $kind $G/f5 0 1 blank_line
  head -n -1 "$good" > $G/f6; t $kind $G/f6 0 1 no_end
  head -n 10 "$good" > $G/f7; t $kind $G/f7 0 1 truncated
  : > $G/f8; t $kind $G/f8 0 1 empty
  awk -v e="$(tail -1 "$good")" '$0==e{print "psql:<stdin>:200: ERROR:  canceling statement due to statement timeout"}1' "$good" > $G/f9; t $kind $G/f9 0 1 error_line
  awk 'NR==4{print "WARNING:  there is no transaction in progress"}1' "$good" > $G/f10; t $kind $G/f10 0 1 warning_line
  awk 'NR==4{print "now 2026-10-20 00:00:00+00"}1' "$good" > $G/f11; t $kind $G/f11 0 1 two_now
  sed 's/$/\r/' "$good" > $G/f12; t $kind $G/f12 0 0 crlf_pass
  sed -E '0,/ PASS$/s// PASS FAIL/' "$good" > $G/f13; t $kind $G/f13 0 1 fail_suffix
  { cat "$good"; echo "INFO trailing"; } > $G/f14; t $kind $G/f14 0 1 after_end
done
t postcheck $G/precheck.good.txt 0 1 wrong_kind
t precheck $G/postcheck.good.txt 0 1 wrong_kind
gate postcheck $G/postcheck.good.txt > /dev/null 2>&1; r=$?; [[ $r == 2 ]] && { ok=$((ok+1)); echo "ok   missing --rc -> usage error 2"; } || { bad=$((bad+1)); echo "BAD missing --rc rc=$r"; }
echo "GATE CASES: $ok ok, $bad bad"; [[ $bad == 0 ]]
