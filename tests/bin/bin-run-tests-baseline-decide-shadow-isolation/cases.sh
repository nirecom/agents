# shellcheck shell=bash
# tests/bin/bin-run-tests-baseline-decide-shadow-isolation/cases.sh
# Tests: bin/run-tests-baseline
# Tags: run-tests, baseline, decide-shadow, cli, scope:common, pwsh-not-required, TL2
# Case bodies of the isolation entrypoint. si_isolation_setup runs the CLI once each with off and on,
# and each function reads only those results (it never runs the CLI itself). FAULT is in fault.sh, the budget in budget.sh.
# The entrypoint sources it after _lib.sh.

# si_preseed_retention <cache> — puts a 31-day-old dummy log and a new dummy log (on run only).
si_preseed_retention() {
  local d="$1/baseline/decide-shadow"
  mkdir -p "$d"
  : >"$d/divergence-dummy-old-1-1.tsv"
  touch -d '31 days ago' "$d/divergence-dummy-old-1-1.tsv"
  : >"$d/divergence-dummy-recent-2-2.tsv"
}

si_isolation_setup() {
  si_run off RUN_TESTS_BASELINE_DECIDE_SHADOW=off
  SI_PRESEED_FN=si_preseed_retention si_run on
}

# kill switch off: equals the current code's values (variant expect) and writes neither a log nor a stderr line.
si_case_off() {
  si_same expect off "fixture: shadow off"
  if [ -z "$(si_logs off)" ] && [ -z "$(si_shadow_err_lines off)" ]; then
    pass "kill switch off: no divergence log and no shadow stderr line"
  else
    fail "kill switch off: log [$(si_logs off)] stderr [$(si_shadow_err_lines off)]"
  fi
}

si_case_on_same() { si_same off on "shadow on"; }

si_case_exit_trap() { local l; for l in off on; do si_tmp_clean "$l"; done; }

# The log's place, unique name and first line. The place is under RUN_ALL_CACHE_DIR; nothing is written to $HOME.
si_case_log_place() {
  local logs n f
  logs="$(si_logs on)"
  n="$(printf '%s' "$logs" | grep -c .)"
  if [ "$n" -eq 1 ]; then pass "shadow on: exactly one divergence log in <cache>/baseline/decide-shadow"
  else fail "shadow on: want one divergence log, found $n: [$logs]; stderr: ${SI_STDERR[on]}"; return 0; fi
  f="${logs##*/}"
  if printf '%s' "$f" | grep -qE '^divergence-.+-[0-9]{9,}-[0-9]+\.tsv$'; then pass "log name divergence-<host>-<epoch>-<pid>.tsv: $f"
  else fail "log name not divergence-<host>-<epoch>-<pid>.tsv: $f"; fi
  if [ "$(head -n 1 "$logs")" = "$SI_HEADER" ]; then pass "log line 1 is the v1 header"
  else fail "log line 1: want [$SI_HEADER] got [$(head -n 1 "$logs")]"; fi
  if [ ! -e "$HOME/.claude/run-all" ] && [ ! -e "$TMPROOT/home/.claude/run-all" ]; then
    pass "nothing written under \$HOME/.claude/run-all (every write follows RUN_ALL_CACHE_DIR)"
  else
    fail "a write reached \$HOME/.claude/run-all: $(find "$HOME/.claude/run-all" 2>/dev/null | head -n 5)"
  fi
}

# The shapes of RUN / COMPARED / NO_COMPARISON / SUMMARY, and compared + no_comparison = the failing count.
si_case_log_lines() {
  local f run cmp nc sum c n
  f="$(si_logs on | head -n 1)"
  [ -f "$f" ] || { fail "shadow on: no divergence log to read"; return 0; }
  run="$(awk -F'\t' -v h="$SI_HEAD" -v b="$SI_B2" 'NR == 2 && $1 == "RUN" && NF == 4 && $2 ~ /^[0-9]+$/ && $3 == h && $4 == b { print "ok" }' "$f")"
  if [ "$run" = ok ]; then pass "line 2 is RUN<TAB><epoch><TAB><HEAD><TAB><B2>"
  else fail "line 2: want RUN with HEAD $SI_HEAD and B2 $SI_B2, got [$(sed -n 2p "$f")]"; fi
  cmp="$(awk -F'\t' '$1 == "COMPARED" { n++; if (NF != 9 || $7 !~ /^(match|recorded:.+|unrecorded)$/ || $8 !~ /^\{/ || ($9 != "null" && $9 !~ /^\{/)) bad++ } END { print n + 0, bad + 0 }' "$f")"
  nc="$(awk -F'\t' '$1 == "NO_COMPARISON" { n++; if (NF != 3 || $3 !~ /^(outside-decide|branch-result-reused-from-cache|base-result-reused-from-ledger-or-inheritance|capture-unreadable)$/) bad++ } END { print n + 0, bad + 0 }' "$f")"
  if [ "${cmp#* }" = 0 ] && [ "${nc#* }" = 0 ]; then pass "COMPARED has 9 fields, NO_COMPARISON 3 with a known reason (${cmp% *} + ${nc% *})"
  else fail "malformed COMPARED ($cmp) / NO_COMPARISON ($nc) lines in: $(cat "$f")"; fi
  n="$(awk -F'\t' '($1 == "COMPARED" || $1 == "NO_COMPARISON") && ($2 == "tests/bin/test-preexisting.sh" || $2 == "tests/bin/test-broken.sh") { print $2 }' "$f" | sort -u | grep -c .)"
  if [ "$n" -eq "$SI_NTESTS" ]; then pass "every failing test has its own COMPARED or NO_COMPARISON line"
  else fail "want both failing tests in COMPARED/NO_COMPARISON, got $n: $(cat "$f")"; fi
  sum="$(si_summary on)"
  if printf '%s\n' "$sum" | grep -qE $'^SUMMARY\tcompared=[0-9]+\tmatched=[0-9]+\trecorded=[0-9]+\tunrecorded=[0-9]+\tno_comparison=[0-9]+\tskipped=-\telapsed_ms=[0-9]+$'; then
    pass "SUMMARY has the v1 shape with skipped=-"
  else
    fail "SUMMARY shape: got [$sum]"
  fi
  c="$(printf '%s' "$sum" | sed -n 's/.*compared=\([0-9]*\).*no_comparison=\([0-9]*\).*/\1 \2/p')"
  if [ -n "$c" ] && [ $(( ${c% *} + ${c#* } )) -eq "$SI_NTESTS" ] && [ "$c" = "${cmp% *} ${nc% *}" ]; then
    pass "compared + no_comparison = $SI_NTESTS failing tests, and matches the lines"
  else
    fail "counts: SUMMARY [$c], lines [${cmp% *} ${nc% *}], failing $SI_NTESTS"
  fi
}

si_case_log_retention() {
  local d="${SI_CACHE[on]}/baseline/decide-shadow"
  if [ ! -e "$d/divergence-dummy-old-1-1.tsv" ]; then pass "a divergence log older than 30 days is swept"
  else fail "the 31-day-old divergence log was not swept"; fi
  if [ -e "$d/divergence-dummy-recent-2-2.tsv" ]; then pass "a recent divergence log is kept"
  else fail "the recent divergence log was removed"; fi
}

# stderr has exactly one shadow line, and no shadow output is mixed into stdout.
si_case_streams() {
  local lines n sum f
  lines="$(si_shadow_err_lines on)"
  n="$(printf '%s' "$lines" | grep -c .)"
  if [ "$n" -eq 1 ] && [[ "$lines" =~ $SI_STDERR_RE ]]; then
    pass "stderr carries exactly one decide shadow line"
    sum="$(si_summary on)" f="$(si_logs on | head -n 1)"
    case "$sum" in
      *$'\tcompared='"${BASH_REMATCH[1]}"$'\t'*$'\tunrecorded='"${BASH_REMATCH[2]}"$'\tno_comparison='"${BASH_REMATCH[3]}"$'\t'*)
        pass "the stderr counts match SUMMARY" ;;
      *) fail "stderr counts [$lines] differ from SUMMARY [$sum]" ;;
    esac
    if [ -n "$f" ] && [ "${BASH_REMATCH[4]##*/}" = "${f##*/}" ]; then pass "log= names the divergence log"
    else fail "log= [${BASH_REMATCH[4]}] is not the divergence log [$f]"; fi
  else
    fail "want one stderr line /$SI_STDERR_RE/, got $n: [$lines]"
  fi
  if printf '%s\n' "${SI_STDOUT[on]}" | grep -vE '^(BASELINE: |BASELINE_SUMMARY: |$)' | grep -q .; then
    fail "stdout carries a non-BASELINE line: ${SI_STDOUT[on]}"
  else
    pass "stdout holds only BASELINE lines with shadow on"
  fi
}

# RTB_DECIDE_SHADOW_CAPTURE_FILE from the environment: the shadow did not create that file, so it must not delete it.
# The control (a capture the shadow created is removed) is si_tmp_clean in si_case_exit_trap.
si_case_env_capture_kept() {
  local cf="$TMPROOT/si-env-capture.tsv" first
  printf 'PRESEED\tkeep-me\n' >"$cf"
  si_run envcap "RTB_DECIDE_SHADOW_CAPTURE_FILE=$cf"
  if [[ -f "$cf" ]]; then pass "an environment-provided capture file survives the run"
  else fail "the environment-provided capture file [$cf] was deleted; stderr: ${SI_STDERR[envcap]}"; return 0; fi
  first="$(head -n 1 "$cf")"
  if [[ "$first" == $'PRESEED\tkeep-me' ]]; then pass "the environment-provided capture file keeps its original first line"
  else fail "first line of [$cf]: want [PRESEED<TAB>keep-me], got [$first]"; fi
  si_same off envcap "shadow on with an environment-provided capture file"
}
