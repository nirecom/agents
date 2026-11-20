# shellcheck shell=bash
# tests/bin/bin-run-tests-baseline-decide-corpus/assert-divergence-log.sh
# Tests: bin/run-tests-baseline
# Tags: run-tests, baseline, decide-shadow, divergence-log, helper, scope:common, pwsh-not-required, TL2
# Checks a run's divergence log from one CLI output (shared by corpus (1)(2)). The caller defines pass / fail and sources it.
# adl_check <label> <cli-output> <cache-dir> [compared=N] [no_comparison=N] [min_compared=N] [allow_skipped=a,b] [VAR=val...]
#   min_compared requires compared >= N on a skipped=- run; a run whose reasons are all in zero_compared_ok=<reason,...> may have compared=0.
#   A run that reached the hand-off always has the shadow line and the log; a run that did not, or with the kill switch off, has neither.
#   SUMMARY skipped accepts only - / budget-short by default; failed / timed-out only when named in allow_skipped.
# adl_expect <label> <path> <match|recorded:<id>|unrecorded|no:<reason>> [<live class> <live detail>] reads the log of the last adl_check (ADL_LOG).

ADL_HEADER='# run-tests-baseline decide shadow v1'
ADL_LOG=""

_adl_np() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }
_adl_field() { printf '%s\n' "$1" | tr ' \t' '\n\n' | sed -n "s/^$2=//p" | head -n 1; }

adl_check() {
  local label="$1" out="$2" cache="$3" off=0 want_c="" want_n="" min_c="" zero_ok="" allow=",-,budget-short," arg line n log dir summary
  local reasons bad
  local c u nc m r s el ln_c ln_n ln_u
  shift 3
  [ "${RUN_TESTS_BASELINE_DECIDE_SHADOW:-}" != off ] || off=1
  for arg in "$@"; do
    case "$arg" in
      compared=*) want_c="${arg#compared=}" ;;
      no_comparison=*) want_n="${arg#no_comparison=}" ;;
      min_compared=*) min_c="${arg#min_compared=}" ;;
      zero_compared_ok=*) zero_ok="${arg#zero_compared_ok=}" ;;
      allow_skipped=*) allow="$allow${arg#allow_skipped=},," ;;
      RUN_TESTS_BASELINE_DECIDE_SHADOW=off) off=1 ;;
    esac
  done
  ADL_LOG=""
  line="$(printf '%s\n' "$out" | grep -E '^run-tests-baseline: decide shadow: ')"
  if [ "$off" = 1 ] || ! printf '%s\n' "$out" | grep -q '^BASELINE_SUMMARY: '; then
    if [ -z "$line" ]; then pass "$label: no shadow line on a run that does not reach the hand-off / with the kill switch off"
    else fail "$label: a shadow line appeared on a run that does not reach the hand-off / with the kill switch off: $line"; fi
    return 0
  fi
  if [ "$(printf '%s\n' "$line" | grep -c .)" != 1 ]; then
    fail "$label: not exactly one decide shadow line on stderr (0 lines if the shadow is not implemented): [${line:-(none)}]"
    return 0
  fi
  n="$(printf '%s\n' "$out" | grep -c '^BASELINE: ')"
  log="$(printf '%s\n' "$line" | sed -n 's/.* log=//p')"
  if [ -z "$log" ] || [ ! -f "$log" ]; then fail "$label: cannot read the log of the shadow line: [$log]"; return 0; fi
  ADL_LOG="$log"
  dir="$(_adl_np "$(dirname "$log")")"
  if [ "$dir" = "$(_adl_np "$cache")/baseline/decide-shadow" ] && [[ "${log##*/}" == divergence-*.tsv ]]; then
    pass "$label: the log is at <cache>/baseline/decide-shadow/divergence-*.tsv (under the test's tmp)"
  else
    fail "$label: the log is in the wrong place: $log (cache=$cache)"
  fi
  if [ "$(head -n 1 "$log" | tr -d '\r')" = "$ADL_HEADER" ] && sed -n '2p' "$log" | grep -q $'^RUN\t'; then
    pass "$label: line 1 is the header, line 2 the RUN line"
  else
    fail "$label: no header or RUN line: $(head -n 2 "$log" | tr '\n' '|')"
  fi
  summary="$(grep $'^SUMMARY\t' "$log")"
  if [ "$(printf '%s\n' "$summary" | grep -c .)" != 1 ]; then fail "$label: not exactly one SUMMARY line"; return 0; fi
  c="$(_adl_field "$summary" compared)" m="$(_adl_field "$summary" matched)" r="$(_adl_field "$summary" recorded)"
  u="$(_adl_field "$summary" unrecorded)" nc="$(_adl_field "$summary" no_comparison)"
  s="$(_adl_field "$summary" skipped)" el="$(_adl_field "$summary" elapsed_ms)"
  if [ "$u" = 0 ]; then pass "$label: SUMMARY unrecorded=0"
  else fail "$label: there is an unrecorded mismatch (unrecorded=$u): $(grep $'\tunrecorded\t' "$log" | cut -f2-7 | tr '\n' '|')"; fi
  if [[ "$c" =~ ^[0-9]+$ && "$nc" =~ ^[0-9]+$ ]] && [ $((c + nc)) -eq "$n" ]; then
    pass "$label: compared($c) + no_comparison($nc) = failing list count($n)"
  else
    fail "$label: compared=$c plus no_comparison=$nc differs from the failing list count $n"
  fi
  ln_c="$(grep -c $'^COMPARED\t' "$log")" ln_n="$(grep -c $'^NO_COMPARISON\t' "$log")"
  if [ "$ln_c" = "$c" ] && [ "$ln_n" = "$nc" ] && [[ "$m$r" =~ ^[0-9]+$ ]] && [ $((m + r + u)) -eq "$c" ]; then
    pass "$label: the COMPARED / NO_COMPARISON line counts and matched+recorded+unrecorded agree with SUMMARY"
  else
    fail "$label: line counts disagree with SUMMARY (COMPARED=$ln_c NO_COMPARISON=$ln_n; $summary)"
  fi
  ln_u="$(printf '%s\n' "$line" | sed -n 's/.* unrecorded=\([0-9]*\).*/\1/p')"
  if [ "$line" = "run-tests-baseline: decide shadow: compared=$c unrecorded=$ln_u no_comparison=$nc log=$log" ] && [ "$ln_u" = "$u" ]; then
    pass "$label: the numbers on the stderr line equal SUMMARY"
  else
    fail "$label: the stderr line and SUMMARY differ: [$line] vs [$summary]"
  fi
  if [[ "$el" =~ ^[0-9]+$ ]] && [ "$el" -lt 10000 ]; then pass "$label: (b) elapsed_ms=$el < 10000"
  else fail "$label: elapsed_ms is not a number below 10000: [$el]"; fi
  echo "INFO: $label: elapsed_ms=$el skipped=$s failing=$n"
  if [[ "$allow" == *",$s,"* ]]; then pass "$label: SUMMARY skipped=$s is an accepted value"
  else fail "$label: SUMMARY skipped=$s is a shadow fault (not named in allow_skipped)"; fi
  if [ "$s" != "-" ] && { [ "$c" != 0 ] || [ "$nc" != "$n" ]; }; then
    fail "$label: a skipped=$s run should count every test as no_comparison (compared=$c no_comparison=$nc)"
  fi
  # Reject a run where every test is no_comparison (e.g. no capture could be read). A skipped run is all no_comparison above.
  # A zero_compared_ok=<reason,...> run may have compared=0 only when every no_comparison reason is in that list.
  if [ -n "$min_c" ] && [ "$s" = "-" ]; then
    reasons="$(grep $'^NO_COMPARISON\t' "$log" | cut -f3 | sort -u | tr '\n' ',')"
    bad=""
    for arg in ${reasons//,/ }; do [[ ",$zero_ok," == *",$arg,"* ]] || bad="$bad $arg"; done
    if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge "$min_c" ]; then pass "$label: compared=$c is at least $min_c"
    elif [ "$c" = 0 ] && [ -n "$zero_ok" ] && [ -n "$reasons" ] && [ -z "$bad" ]; then
      pass "$label: compared=0 is due only to the named reasons ($zero_ok): ${reasons%,}"
    else fail "$label: compared=$c is below $min_c (no_comparison reasons: ${reasons%,}; reasons not accepted:${bad:- none})"; fi
  fi
  if [ -n "$want_c" ] || [ -n "$want_n" ]; then
    if [ "$s" = "-" ] && [ "$c" = "${want_c:-$c}" ] && [ "$nc" = "${want_n:-$nc}" ]; then
      pass "$label: expected counts compared=${want_c:-*} no_comparison=${want_n:-*}"
    else
      fail "$label: expected compared=${want_c:-*} no_comparison=${want_n:-*} skipped=-, got compared=$c no_comparison=$nc skipped=$s"
    fi
  fi
}

# adl_expect <label> <path> <match|recorded:<id>|unrecorded|no:<reason>> [<live class> <live detail>]
# — reads that test's one log line. recorded is matched down to the id (so the recorded discrepancy is not mistaken).
# With a 4th argument, checks the live (class, detail) of the COMPARED line. match always checks decide's (class, detail) equals live; recorded that it differs.
adl_expect() {
  local label="$1" path="$2" want="$3" want_live="${4:-}" row got live dec
  [ -n "$ADL_LOG" ] && [ -f "$ADL_LOG" ] || { fail "$label: $path: no divergence log"; return 0; }
  row="$(awk -F'\t' -v p="$path" '($1 == "COMPARED" || $1 == "NO_COMPARISON") && $2 == p' "$ADL_LOG")"
  if [ "$(printf '%s\n' "$row" | grep -c .)" != 1 ]; then
    fail "$label: not exactly one line for $path: [${row:-(none)}]"; return 0
  fi
  case "$row" in
    COMPARED*) got="$(printf '%s\n' "$row" | cut -f7)"
      live="$(printf '%s\n' "$row" | cut -f3,4 | tr '\t' ' ')"
      dec="$(printf '%s\n' "$row" | cut -f5,6 | tr '\t' ' ')" ;;
    *) got="no:$(printf '%s\n' "$row" | cut -f3)" ;;
  esac
  if [ "$got" = "$want" ]; then pass "$label: $path is $want"
  else fail "$label: $path should be $want but is [$got]: $(printf '%s\n' "$row" | cut -f1-7)"; fi
  # A no_comparison line has no live / decide columns.
  case "$want" in no:*) return 0 ;; esac
  if [ -n "$want_live" ]; then
    if [ "$live" = "$want_live" ]; then pass "$label: live of $path is $want_live"
    else fail "$label: live of $path should be $want_live but is [$live]"; fi
  fi
  case "$want" in
    match)
      if [ -n "$live" ] && [ "$dec" = "$live" ]; then pass "$label: decide of $path equals live ($dec)"
      else fail "$label: $path is match but decide [$dec] differs from live [$live]"; fi ;;
    recorded:*)
      # A recorded discrepancy holds only when decide differs from live (do not pass a decide that happens to equal live).
      if [ -n "$live" ] && [ -n "$dec" ] && [ "$dec" != "$live" ]; then pass "$label: decide [$dec] of $path differs from live [$live]"
      else fail "$label: $path is $want but decide [$dec] does not differ from live [$live]"; fi ;;
  esac
}
