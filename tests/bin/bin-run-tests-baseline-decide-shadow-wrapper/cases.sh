# shellcheck shell=bash
# tests/bin/bin-run-tests-baseline-decide-shadow-wrapper/cases.sh
# Tests: bin/lib/run-tests-baseline-decide-shadow.sh
# Tags: run-tests, baseline, decide-shadow, scope:common, pwsh-not-required, TL2
# Case bodies of wrapper (a). One function per case; each runs driver.sh once and reads its output lines.
# Whether the unwrapped values (the stub launcher results) are as expected is checked as a fixture check in the same function.
# The entrypoint sources it after _lib.sh.

# ws_expect <mode> — the DRV_SNAP (SEQ=1) the unwrapped rtb_exec_one builds from stub result <mode>.
ws_expect() {
  case "$1" in
    pass)        printf 'rc=0 RC=0 TO=0 UNS=0 DEC=0 ST=PASS UNR=0 SEQ=1' ;;
    fail)        printf 'rc=0 RC=3 TO=0 UNS=0 DEC=0 ST=FAIL UNR=0 SEQ=1' ;;
    setup)       printf 'rc=2 RC= TO= UNS= DEC= ST= UNR= SEQ=1' ;;
    unsupported) printf 'rc=0 RC=78 TO=0 UNS=1 DEC=0 ST= UNR=0 SEQ=1' ;;
    decoy)       printf 'rc=0 RC=1 TO=0 UNS=0 DEC=1 ST=PASS UNR=0 SEQ=1' ;;
  esac
}

# For each result, the return code, every RTB_EXEC_* and RTB_EXEC_SEQ are the same before and after wrapping.
ws_case_transparent() {
  local work="$WS_DIR/transparent" m before after
  ws_drive "$work" '
for m in $WS_MODES; do RTB_EXEC_SEQ=0; drv_call "$m" "$WT_BRANCH" "$WORK/before-$m"; echo "BEFORE_$m $DRV_SNAP"; done
ROOT="$WT_BRANCH"; LOGDIR="$WORK/logs-1-1"
drv_install || exit 0
for m in $WS_MODES; do RTB_EXEC_SEQ=0; drv_call "$m" "$WT_BRANCH" "$WORK/after-$m"; echo "AFTER_$m $DRV_SNAP"; done' "WS_MODES=$WS_MODES"
  for m in $WS_MODES; do
    before="$(ws_line "BEFORE_$m ")"
    if [ "$before" = "$(ws_expect "$m")" ]; then pass "fixture: unwrapped $m gives [$before]"
    else fail "fixture: unwrapped $m: want [$(ws_expect "$m")] got [$before]; rc=$WS_RC out: $WS_OUT"; fi
  done
  ws_install_ok "wrapper install" || return 0
  for m in $WS_MODES; do
    before="$(ws_line "BEFORE_$m ")" after="$(ws_line "AFTER_$m ")"
    if [ "$after" = "$before" ]; then pass "wrapped $m is transparent: [$after]"
    else fail "wrapped $m changed the call: before [$before] after [$after]"; fi
  done
}

# Even after wrapping, stdin is not read: the caller's read still gets the next line (L2).
ws_case_stdin() {
  local work="$WS_DIR/stdin" got
  ws_drive "$work" '
{ read -r a; RTB_EXEC_SEQ=0; drv_call pass "$WT_BRANCH" "$WORK/b"; read -r b; echo "BEFORE_NEXT [$b]"; } <<<"$(printf "L1\nL2\nL3")"
ROOT="$WT_BRANCH"; LOGDIR="$WORK/logs-1-1"
drv_install || exit 0
{ read -r a; drv_call pass "$WT_BRANCH" "$WORK/a"; read -r b; echo "AFTER_NEXT [$b]"; } <<<"$(printf "L1\nL2\nL3")"'
  got="$(ws_line 'BEFORE_NEXT ')"
  if [ "$got" = "[L2]" ]; then pass "fixture: unwrapped rtb_exec_one leaves stdin to the caller"
  else fail "fixture: unwrapped call: caller read [$got], want [L2]; out: $WS_OUT"; fi
  ws_install_ok "wrapper install" || return 0
  got="$(ws_line 'AFTER_NEXT ')"
  if [ "$got" = "[L2]" ]; then pass "wrapped rtb_exec_one consumes no stdin (caller reads L2)"
  else fail "wrapped call consumed stdin: caller read [$got], want [L2]"; fi
}

# Even when the capture file cannot be written (LOGDIR's parent is a regular file), the return code and RTB_EXEC_* are unchanged.
ws_case_write_failure() {
  local work="$WS_DIR/wfail" before after
  ws_drive "$work" '
RTB_EXEC_SEQ=0; drv_call fail "$WT_BRANCH" "$WORK/b"; echo "BEFORE $DRV_SNAP"
: >"$WORK/blocker"; ROOT="$WT_BRANCH"; LOGDIR="$WORK/blocker/logs-1-1"
drv_install || exit 0
RTB_EXEC_SEQ=0; drv_call fail "$WT_BRANCH" "$WORK/a"; echo "AFTER $DRV_SNAP"; echo "EXITED_OK"'
  ws_install_ok "wrapper install" || return 0
  before="$(ws_line 'BEFORE ')" after="$(ws_line 'AFTER ')"
  if [ "$before" = "$(ws_expect fail)" ] && [ "$after" = "$before" ]; then
    pass "an unwritable capture file leaves the call transparent: [$after]"
  else
    fail "unwritable capture: before [$before] after [$after]; rc=$WS_RC out: $WS_OUT"
  fi
  case "$WS_OUT" in *EXITED_OK*) pass "the caller keeps running after the failed append" ;;
    *) fail "the caller stopped after the failed append; rc=$WS_RC out: $WS_OUT" ;; esac
}

# Three calls leave one capture file, its path fixed at the first call's ${LOGDIR}.decide-shadow-capture.tsv.
# Columns: comparison side (branch when $1 = $ROOT), rel, logdir, seq, return code, RTB_EXEC_RC/TIMEDOUT/UNSUPPORTED/DECOY/STATE/UNRUNNABLE.
ws_case_capture_fixed() {
  local work="$WS_DIR/fixed" want caps n
  ws_drive "$work" '
ROOT="$WT_BRANCH"; LOGDIR="$WORK/logs-100-1"
drv_install || exit 0
drv_call pass "$WT_BRANCH" "$WORK/la"
drv_call fail "$WT_BASE" "$WORK/lb"
LOGDIR="$WORK/logs-200-2"
drv_call setup "$WT_BRANCH" "$WORK/lc"
echo "CAP [${RTB_DECIDE_SHADOW_CAPTURE_FILE:-}]"'
  ws_install_ok "wrapper install" || return 0
  want="$work/logs-100-1.decide-shadow-capture.tsv"
  caps="$(ws_captures "$work")"
  n="$(printf '%s' "$caps" | grep -c .)"
  if [ "$n" -eq 1 ] && [ -f "$want" ]; then pass "three calls leave exactly one capture file, named from the first LOGDIR"
  else fail "want one capture file [$want], found $n: [$caps]"; fi
  if [ "$(ws_line 'CAP ')" = "[$want]" ]; then pass "RTB_DECIDE_SHADOW_CAPTURE_FILE stays fixed at the first call's path"
  else fail "RTB_DECIDE_SHADOW_CAPTURE_FILE: want [$want] got $(ws_line 'CAP ')"; fi
  WS_FIXED_WORK="$work" WS_FIXED_FILE="$want"
}

# ws_cap_row <n> <want-side-regex> <want-rest> <label> — checks row n of the capture.
ws_cap_row() {
  local row side rest
  row="$(sed -n "${1}p" "$WS_FIXED_FILE" 2>/dev/null)"
  side="$(printf '%s' "$row" | cut -f1)" rest="$(printf '%s' "$row" | cut -f2-)"
  if printf '%s' "$side" | grep -qxE -- "$2" && [ "$rest" = "$3" ]; then pass "capture row $1: $4"
  else fail "capture row $1 ($4): want side /$2/ and [$3], got [$row]"; fi
}

ws_case_capture_columns() {
  local t=$'\t' w="${WS_FIXED_WORK:-}"
  [ -f "${WS_FIXED_FILE:-}" ] || { fail "no capture file to read (see the fixed-path case)"; return 0; }
  if [ "$(grep -c . "$WS_FIXED_FILE")" -eq 3 ]; then pass "one capture row per call (3)"
  else fail "want 3 capture rows, got: $(cat "$WS_FIXED_FILE")"; fi
  ws_cap_row 1 'branch' "tests/bin/x.sh${t}$w/la${t}1${t}0${t}0${t}0${t}0${t}0${t}PASS${t}0" "branch side, pass"
  ws_cap_row 2 'base|merge-base' "tests/bin/x.sh${t}$w/lb${t}2${t}0${t}3${t}0${t}0${t}0${t}FAIL${t}0" "merge base side, fail rc 3"
  ws_cap_row 3 'branch' "tests/bin/x.sh${t}$w/lc${t}3${t}2${t}${t}${t}${t}${t}${t}" "setup failure rc 2, empty RTB_EXEC_*"
}

# With LOGDIR unset, the call does not stop under set -u, and no capture is written.
ws_case_logdir_unset() {
  local work="$WS_DIR/unset" caps
  rm -f "$TMPROOT/.decide-shadow-capture.tsv"
  ws_drive "$work" '
unset LOGDIR; ROOT="$WT_BRANCH"
drv_install || exit 0
RTB_EXEC_SEQ=0; drv_call pass "$WT_BRANCH" "$WORK/l"; echo "ALIVE $DRV_SNAP"
echo "CAP [${RTB_DECIDE_SHADOW_CAPTURE_FILE:-}]"'
  ws_install_ok "wrapper install" || return 0
  if [ "$(ws_line 'ALIVE ')" = "$(ws_expect pass)" ]; then pass "LOGDIR unset under set -u: the call returns transparently"
  else fail "LOGDIR unset: want ALIVE [$(ws_expect pass)]; rc=$WS_RC out: $WS_OUT"; fi
  caps="$(ws_captures "$work")"
  [ ! -e "$TMPROOT/.decide-shadow-capture.tsv" ] || caps="$caps $TMPROOT/.decide-shadow-capture.tsv"
  if [ -z "$caps" ] && [ "$(ws_line 'CAP ')" = "[]" ]; then pass "LOGDIR unset: no capture file and no fixed path"
  else fail "LOGDIR unset: capture written [$caps] / CAP $(ws_line 'CAP ')"; fi
}

# kill switch off: installing defines no rtb_exec_one_unwrapped, and no capture is written.
ws_case_kill_switch_off() {
  local work="$WS_DIR/off"
  ws_drive "$work" '
ROOT="$WT_BRANCH"; LOGDIR="$WORK/logs-300-3"
drv_load_shadow || exit 0
if declare -F rtb_exec_one_unwrapped >/dev/null 2>&1; then echo "UNWRAPPED defined"; else echo "UNWRAPPED none"; fi
RTB_EXEC_SEQ=0; drv_call pass "$WT_BRANCH" "$WORK/l"; echo "OFF $DRV_SNAP"' RUN_TESTS_BASELINE_DECIDE_SHADOW=off
  ws_install_ok "shadow lib load" || return 0
  if [ "$(ws_line 'UNWRAPPED ')" = "none" ]; then pass "kill switch off: rtb_exec_one_unwrapped is not defined"
  else fail "kill switch off: rtb_exec_one_unwrapped got defined; out: $WS_OUT"; fi
  if [ "$(ws_line 'OFF ')" = "$(ws_expect pass)" ] && [ -z "$(ws_captures "$work")" ]; then
    pass "kill switch off: the call is the original and writes no capture"
  else
    fail "kill switch off: OFF [$(ws_line 'OFF ')] captures [$(ws_captures "$work")]"
  fi
}

# A second install does not wrap the wrapper: the function definitions equal the first install's, and one call leaves one capture row.
ws_case_double_install() {
  local work="$WS_DIR/twice" cap="$WS_DIR/twice/logs-400-4.decide-shadow-capture.tsv" rows
  ws_drive "$work" '
ROOT="$WT_BRANCH"; LOGDIR="$WORK/logs-400-4"
drv_install || exit 0
s1="$(declare -f rtb_exec_one; declare -f rtb_exec_one_unwrapped)"
case "$s1" in *rtb_exec_one_unwrapped\ \"\$@\"*) echo "WRAPPED_ONCE yes" ;; *) echo "WRAPPED_ONCE no" ;; esac
rtb_decide_shadow_install || echo "DRV_INSTALL_ERR second install returned non-zero"
s2="$(declare -f rtb_exec_one; declare -f rtb_exec_one_unwrapped)"
if [[ "$s1" == "$s2" ]]; then echo "SNAP same"; else echo "SNAP differs"; printf "%s\n" "$s2"; fi
RTB_EXEC_SEQ=0; drv_call pass "$WT_BRANCH" "$WORK/l"; echo "CALL $DRV_SNAP"'
  ws_install_ok "wrapper install" || return 0
  if [[ "$(ws_line 'WRAPPED_ONCE ')" == "yes" ]]; then pass "fixture: one install wraps rtb_exec_one around rtb_exec_one_unwrapped"
  else fail "fixture: one install did not wrap rtb_exec_one; out: $WS_OUT"; fi
  if [[ "$(ws_line 'SNAP ')" == "same" ]]; then pass "second install leaves rtb_exec_one and rtb_exec_one_unwrapped as after one install"
  else fail "second install changed the wrapped functions; out: $WS_OUT"; fi
  if [[ "$(ws_line 'CALL ')" == "$(ws_expect pass)" ]]; then pass "after two installs the call is still transparent"
  else fail "after two installs: want CALL [$(ws_expect pass)]; rc=$WS_RC out: $WS_OUT"; fi
  rows="$(grep -c . "$cap" 2>/dev/null)" || rows=0
  if [[ -f "$cap" && "$rows" -eq 1 ]]; then pass "after two installs one call leaves exactly one capture row"
  else fail "after two installs: want 1 capture row in [$cap], got $rows: $(cat "$cap" 2>/dev/null)"; fi
}

# The capture rel column is escaped (backslash -> \\, TAB -> \t, LF -> \n), so each call stays one 11-column row.
ws_case_capture_rel_escaped() {
  local work="$WS_DIR/esc" cap="$WS_DIR/esc/logs-500-5.decide-shadow-capture.tsv" n want got i
  ws_drive "$work" '
ROOT="$WT_BRANCH"; LOGDIR="$WORK/logs-500-5"
drv_install || exit 0
for DRV_REL in $'"'"'tests/bin/a\tb.sh'"'"' $'"'"'tests/bin/a\\b.sh'"'"' $'"'"'tests/bin/a\nb.sh'"'"'; do
  RTB_EXEC_SEQ=0; drv_call pass "$WT_BRANCH" "$WORK/l"
done'
  ws_install_ok "wrapper install" || return 0
  n="$(grep -c . "$cap" 2>/dev/null)" || n=0
  if [[ "$n" -eq 3 ]]; then pass "three calls with escapable rels leave three capture rows"
  else fail "want 3 capture rows in [$cap], got $n: $(cat "$cap" 2>/dev/null)"; fi
  want=('tests/bin/a\tb.sh' 'tests/bin/a\\b.sh' 'tests/bin/a\nb.sh')
  for i in 0 1 2; do
    got="$(sed -n "$((i + 1))p" "$cap" 2>/dev/null)"
    if [[ "$(printf '%s' "$got" | awk -F'\t' '{ print NF }')" == 11 && "$(printf '%s' "$got" | cut -f2)" == "${want[i]}" ]]; then
      pass "capture row $((i + 1)): rel is the escaped literal [${want[i]}] in 11 columns"
    else
      fail "capture row $((i + 1)): want rel [${want[i]}] in 11 columns, got [$got]"
    fi
  done
}

# The skip log (budget-short here) escapes the path column the same way, so a TAB path stays one column.
ws_case_skip_log_escaped() {
  local work="$WS_DIR/skipesc" log line
  ws_drive "$work" '
. "$DRV_SHADOW_LIB" || exit 0
TESTS=($'"'"'tests/bin/a\tb.sh'"'"'); ROOT="$WT_BRANCH"; LOGDIR="$WORK/logs-600-6"
export RUN_ALL_CACHE_DIR="$WORK/cache"; unset RTB_BUDGET_TOTAL; SECONDS=590
rtb_decide_shadow_compare_before_handoff'
  log="$(find "$work/cache/baseline/decide-shadow" -maxdepth 1 -name 'divergence-*.tsv' 2>/dev/null | head -n 1)"
  [[ -n "$log" ]] || { fail "budget-short: no divergence log under [$work/cache]; out: $WS_OUT"; return 0; }
  line="$(grep '^NO_COMPARISON' "$log")"
  if [[ "$(printf '%s\n' "$line" | grep -c .)" -eq 1 && "$(printf '%s' "$line" | awk -F'\t' '{ print NF }')" == 3 ]] \
    && [[ "$(printf '%s' "$line" | cut -f2)" == 'tests/bin/a\tb.sh' && "$(printf '%s' "$line" | cut -f3)" == budget-short ]]; then
    pass "skip log: the TAB path is the escaped literal in a 3-column NO_COMPARISON line"
  else
    fail "skip log: want one NO_COMPARISON<TAB>tests/bin/a\\tb.sh<TAB>budget-short, got [$line]"
  fi
}
