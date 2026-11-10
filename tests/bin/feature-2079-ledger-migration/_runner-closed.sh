#!/usr/bin/env bash
# tests/bin/feature-2079-ledger-migration/_runner-closed.sh
# Tests: tests/run-all.sh
# Tags: tests, bin, ledger, durations, consolidate, parallel, scope:issue-specific, TL2
# TL3 gap (what this test does NOT catch): owned by the dispatcher headers, tests/bin/feature-2079-ledger-migration-*.sh.
# n21 (1)-(5), (7) helper (#2079 S7b): a real run-all closes its own segment however it ends,
# a run that measures nothing leaves no ledger, and the next run's start consolidates.
# Prints `R21 <name>=<value>` lines; the dispatcher asserts them. Real uname/host on purpose.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/tests/feature-1832-run-all-parallel/_lib.sh"

fx_init "n21-runner-closed" >/dev/null
r21() { printf 'R21 %s=%s\n' "$1" "$2"; }

# The current ledger format's name prefix (v3, #2932); fixed here like LM_CUR in _lib.sh.
CUR="dur.3"
# states — `open:closed:consolidating:base` counts of the ledger's current-format files.
states() {
  local f o=0 c=0 s=0 b=0
  for f in "$(fx_ledger_dir)"/"$CUR".*; do
    [ -f "$f" ] || continue
    case "${f##*/}" in
      *.closed.log) c=$((c + 1)) ;;
      *.consolidating.log) s=$((s + 1)) ;;
      *-0*.log) b=$((b + 1)) ;;
      *) o=$((o + 1)) ;;
    esac
  done
  printf '%s:%s:%s:%s' "$o" "$c" "$s" "$b"
}
closed_names() { local f; for f in "$(fx_ledger_dir)"/"$CUR".*.closed.log; do [ -f "$f" ] && printf '%s ' "${f##*/}"; done; }
ledger_files() { local n=0 f; for f in "$(fx_ledger_dir)"/dur.*; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n"; }
# closed_records — `<key basename>=<secs>` of every record in the closed segments, sorted.
closed_records() {
  local f l k
  for f in "$(fx_ledger_dir)"/"$CUR".*.closed.log; do
    [ -f "$f" ] || continue
    while IFS= read -r l; do
      case "$l" in '#'*|'') continue ;; esac
      k="${l##*|}"; l="${l#*|}"; printf '%s=%s\n' "${k##*/}" "${l%%|*}"
    done < "$f"
  done | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'
}
# closed_vt — `<key basename>=<verdict>|<termination>` of every v3 record in the closed segments, sorted.
closed_vt() {
  local f l rid secs v t k
  for f in "$(fx_ledger_dir)"/"$CUR".*.closed.log; do
    [ -f "$f" ] || continue
    while IFS= read -r l; do
      case "$l" in '#'*|'') continue ;; esac
      IFS='|' read -r rid secs v t k <<< "$l"
      printf '%s=%s|%s\n' "${k##*/}" "$v" "$t"
    done < "$f"
  done | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'
}

root="$(fx_new_root)"
fx_add_dummy "$root" q1 --sleep 0
fx_add_dummy "$root" q2 --sleep 1
fx_add_dummy "$root" slow --sleep 30
q="$(fx_tests_dir "$root")/bin"

# (1) a normal exit closes the run's segment and leaves no open name.
fx_exec "$root" 60 "$FX_TMP_ROOT/1.out" "$FX_TMP_ROOT/1.err" -j 2 "$q/q1.sh" "$q/q2.sh"
r21 normal_rc "$?"
r21 normal_states "$(states)"
first="$(closed_names)"

# (5) the next run's start folds the first run's closed segment into a base.
FX_LEDGER_KEEP=1
fx_exec "$root" 60 "$FX_TMP_ROOT/5.out" "$FX_TMP_ROOT/5.err" -j 1 "$q/q1.sh"
r21 second_states "$(states)"
gone=1
for f in $first; do [ -e "$(fx_ledger_dir)/$f" ] && gone=0; done
r21 first_closed_gone "$([ -n "$first" ] && echo "$gone" || echo none)"
FX_LEDGER_KEEP=0

# (2) a deadline exit (3) after one measured test still closes.
fx_exec "$root" 90 "$FX_TMP_ROOT/2.out" "$FX_TMP_ROOT/2.err" -j 1 --deadline 4 "$q/q1.sh" "$q/slow.sh"
r21 deadline_rc "$?"
r21 deadline_states "$(states)"

# (3) INT, once the first measurement is on disk, still closes.
fx_ledger_clear
fx_exec_bg "$root" "$FX_TMP_ROOT/3.out" "$FX_TMP_ROOT/3.err" -j 2 "$q/q1.sh" "$q/slow.sh"
waited=0
while [ "$waited" -lt 40 ] && [ "$(ledger_files)" -eq 0 ]; do sleep 0.5; waited=$((waited + 1)); done
r21 int_measured "$(ledger_files)"
kill -INT "$FX_BG_PID" 2>/dev/null
fx_wait_gone 30 "$FX_BG_PID" || fx_kill_tree "$FX_BG_PID"
wait "$FX_BG_PID" 2>/dev/null
r21 int_rc "$?"
r21 int_states "$(states)"
fx_kill_tree "$FX_BG_PID"

# (7) a failing test entrypoint (exit 1): the run exits 1, still closes, and records both.
fx_add_dummy "$root" bad --sleep 1 --exit 1
fx_exec "$root" 60 "$FX_TMP_ROOT/7.out" "$FX_TMP_ROOT/7.err" -j 2 "$q/q1.sh" "$q/bad.sh"
r21 fail_rc "$?"
r21 fail_states "$(states)"
r21 fail_records "$(closed_records)"
r21 fail_vt "$(closed_vt)"

# (8, #2932 v3) the harvest records the file result: a per-file timeout as `-|timeout`, a pass
# as `PASS|completed`. RUN_ALL_TIMEOUT_SECONDS caps every file's timeout for this run only.
# The per-file kill lives in the launcher libs; fx_new_root copies none of them, and without
# them <root>/bin/run-all.sh falls back to tlr_exec_plain (no timeout), so copy the set here
# exactly as tests/tests/feature-2501-run-all-report/_fx.sh rr_new_root does.
cp "$FX_REPO_ROOT/bin/run-with-timeout.sh" "$root/bin/run-with-timeout.sh"
for lib in run-all-launch.sh run-all-classify.sh run-all-hits.sh timed-exec.sh test-language-registry-plain.sh; do
  [ -f "$FX_REPO_ROOT/bin/lib/$lib" ] && cp "$FX_REPO_ROOT/bin/lib/$lib" "$root/bin/lib/$lib"
done
export RUN_ALL_TIMEOUT_SECONDS=3
fx_exec "$root" 90 "$FX_TMP_ROOT/8.out" "$FX_TMP_ROOT/8.err" -j 2 "$q/q1.sh" "$q/slow.sh"
r21 timeout_rc "$?"
unset RUN_ALL_TIMEOUT_SECONDS
r21 timeout_vt "$(closed_vt)"

# (4) --print-plan and a run with no test to execute create no ledger at all.
fx_exec "$root" 60 "$FX_TMP_ROOT/4.out" "$FX_TMP_ROOT/4.err" --print-plan --all
r21 plan_files "$(ledger_files)"
empty="$(fx_new_root)"
fx_exec "$empty" 60 "$FX_TMP_ROOT/4b.out" "$FX_TMP_ROOT/4b.err" --all
r21 empty_files "$(ledger_files)"
exit 0
