# shellcheck shell=bash
# tests/bin/bin-run-tests-baseline-decide-shadow-isolation/_lib.sh
# Tests: bin/run-tests-baseline
# Tags: run-tests, baseline, decide-shadow, helpers, scope:common, pwsh-not-required, TL2
# Shared part of the isolation / budget entrypoints: feature-2431's helpers and cli.sh (TMPROOT, isolation,
# seed_failing, read_step_field, mk_fixture_repo), one fixture repo, si_run, which runs the CLI once and keeps
# exit, stdout, stderr and state per variant, and small functions that read the divergence log.
# The entrypoint sources it after tests/lib/harness.sh. Not run on its own.

: "${SCRIPT_CHECKOUT_ROOT:?the entrypoint sets SCRIPT_CHECKOUT_ROOT before sourcing _lib.sh}"
command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not available";  exit 77; }
# shellcheck source=../feature-2431-run-tests-baseline/helpers.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2431-run-tests-baseline/helpers.sh"
# shellcheck source=../feature-2431-run-tests-baseline/cli.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2431-run-tests-baseline/cli.sh"

# The budget and timeout values are the code defaults; si_run passes the shadow kill switch and seam per variant.
unset RTB_BUDGET_TOTAL RUN_ALL_TIMEOUT_SECONDS RUN_ALL_PARALLEL
unset RUN_TESTS_BASELINE_DECIDE_SHADOW RUN_TESTS_BASELINE_DECIDE_SHADOW_FAULT_FOR_TEST
mkdir -p "$TMPROOT/transcripts"
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMPROOT/transcripts"
SI_RWT="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"
SI_HEADER='# run-tests-baseline decide shadow v1'
SI_STDERR_RE='^run-tests-baseline: decide shadow: compared=([0-9]+) unrecorded=([0-9]+) no_comparison=([0-9]+) log=(.+)$'
SI_TESTS="tests/bin/test-preexisting.sh tests/bin/test-broken.sh"
SI_NTESTS=2

# fixture: test-preexisting.sh fails with the same lines on main and feature (preexisting);
# only the feature copy of test-broken.sh fails (broken). SI_B2 is main, SI_HEAD is feature.
# The real launcher takes tens of seconds per test, so a minimal launcher that runs the test directly is put on main
# (rtb_exec_one prefers <wt>/bin/lib/run-all-launch.sh; the precedent is feature-3047's eb_cli_lang_cap).
SI_REPO="$TMPROOT/repo-si"
mk_fixture_repo "$SI_REPO" >/dev/null || { echo "fixture: repo not built"; exit 1; }
git -C "$SI_REPO" checkout -q main
mkdir -p "$SI_REPO/bin/lib"
printf '%s\n' \
  'run_all_exec() {' \
  '  local rc=0' \
  '  RUN_ALL_EXEC_LAUNCHED=1' \
  '  RUN_ALL_RESULT_DIR="$4" bash "$1" >"$2" 2>"$3" </dev/null || rc=$?' \
  '  case "$rc" in 0) RUN_ALL_EXEC_STATE=PASS ;; 77) RUN_ALL_EXEC_STATE=SKIP ;; *) RUN_ALL_EXEC_STATE=FAIL ;; esac' \
  '  return "$rc"' \
  '}' >"$SI_REPO/bin/lib/run-all-launch.sh"
git -C "$SI_REPO" add -A
git -C "$SI_REPO" commit -q -m "fast fixture launcher"
SI_B2="$(git -C "$SI_REPO" rev-parse HEAD)"
git -C "$SI_REPO" checkout -q feature
git -C "$SI_REPO" merge -q --no-edit main
feat_commit_failing "$SI_REPO" tests/bin/test-broken.sh
SI_HEAD="$(git -C "$SI_REPO" rev-parse HEAD)"

declare -A SI_RC=() SI_STDOUT=() SI_STDERR=() SI_STATE=() SI_SECS=() SI_CACHE=()

# Variant expect: the values the shadow-off CLI gives on this fixture (the current code's values). The isolation entrypoint
# checks that the off run equals them; the fault entrypoints compare against them without re-running off.
SI_RC[expect]=1
SI_STDOUT[expect]="$(printf '%s\n' \
  'BASELINE: preexisting tests/bin/test-preexisting.sh fails-at-base-exit-1' \
  'BASELINE: broken tests/bin/test-broken.sh passes-at-base' \
  'BASELINE_SUMMARY: preexisting=1 inherited=0 broken=1 undetermined=0 file_verdict=0 new_on_branch=0')"
SI_STATE[expect]="{\"base\":\"$SI_B2\",\"head\":\"$SI_HEAD\",\"entries\":[{\"path\":\"tests/bin/test-preexisting.sh\",\"class\":\"preexisting\",\"detail\":\"fails-at-base-exit-1\",\"new_lines\":{\"count\":0,\"head\":[]}},{\"path\":\"tests/bin/test-broken.sh\",\"class\":\"broken\",\"detail\":\"passes-at-base\",\"new_lines\":{\"count\":0,\"head\":[]}}]}"
SI_STDERR[expect]=""

# si_run <label> [VAR=val...] — runs the CLI once with a new cache and session (so variants do not share
# records). stdout and stderr are captured separately. Results are kept in SI_*[<label>].
si_run() {
  local label="$1" sid="si-$1-$$" cache out err t0 rc=0; shift
  cache="$(cli_case_cache "si-$label")"
  out="$TMPROOT/si-$label.stdout" err="$TMPROOT/si-$label.stderr"
  [ -z "${SI_PRESEED_FN:-}" ] || "$SI_PRESEED_FN" "$cache"
  # shellcheck disable=SC2086  # SI_TESTS is a space-separated list of paths
  seed_failing "$sid" $SI_TESTS
  t0=$SECONDS
  (cd "$TMPROOT" && env RUN_ALL_CACHE_DIR="$cache" "$@" bash "$SI_RWT" 120 \
    bash "$BASELINE_CLI" --session "$sid" --worktree "$SI_REPO" >"$out" 2>"$err") || rc=$?
  SI_SECS[$label]=$((SECONDS - t0))
  SI_RC[$label]="$rc" SI_CACHE[$label]="$cache"
  SI_STDOUT[$label]="$(cat "$out")" SI_STDERR[$label]="$(cat "$err")"
  SI_STATE[$label]="$(read_step_field "$sid" run_tests baseline_classification)"
}

# si_logs <label> — the divergence logs in that variant's cache (one per line, excluding the retention dummies).
si_logs() {
  find "${SI_CACHE[$1]}/baseline/decide-shadow" -maxdepth 1 -type f -name 'divergence-*.tsv' \
    ! -name 'divergence-dummy-*' 2>/dev/null
}

# si_summary <label> — the SUMMARY line of the first divergence log; "(none)" if there is none.
si_summary() {
  local f
  f="$(si_logs "$1" | head -n 1)"
  [ -n "$f" ] && grep -m 1 '^SUMMARY' "$f" 2>/dev/null || printf '(none)'
}

# si_shadow_err_lines <label> — the shadow lines of stderr (lines containing `decide shadow:`).
si_shadow_err_lines() { printf '%s\n' "${SI_STDERR[$1]}" | grep -F 'run-tests-baseline: decide shadow:'; }

# si_same <ref> <label> <what> — passes / fails, item by item, that exit, stdout (BASELINE lines and BASELINE_SUMMARY) and the state's
# baseline_classification equal <ref>.
si_same() {
  local ref="$1" l="$2" what="$3"
  if [ "${SI_RC[$l]}" = "${SI_RC[$ref]}" ]; then pass "$what: exit ${SI_RC[$l]} equals $ref"
  else fail "$what: exit ${SI_RC[$l]} differs from $ref ${SI_RC[$ref]}; stderr: ${SI_STDERR[$l]}"; fi
  if [ "${SI_STDOUT[$l]}" = "${SI_STDOUT[$ref]}" ]; then pass "$what: stdout equals $ref"
  else fail "$what: stdout differs from $ref: [${SI_STDOUT[$l]}] vs [${SI_STDOUT[$ref]}]"; fi
  if [ "${SI_STATE[$l]}" = "${SI_STATE[$ref]}" ]; then pass "$what: state baseline_classification equals $ref"
  else fail "$what: baseline_classification differs from $ref: [${SI_STATE[$l]}] vs [${SI_STATE[$ref]}]"; fi
}

# si_tmp_clean <label> — no lines-written-* and no shadow capture or input is left in TMP_BASE (<cache>/baseline/tmp).
si_tmp_clean() {
  local tb="${SI_CACHE[$1]}/baseline/tmp" left
  left="$(find "$tb" -maxdepth 1 -name 'lines-written-*' 2>/dev/null)"
  if [ -z "$left" ]; then pass "$1: the EXIT trap removed RTB_LINES_WRITTEN_LOG"
  else fail "$1: lines-written file left after exit: [$left]"; fi
  left="$(find "$tb" -maxdepth 1 -name '*decide-shadow*' 2>/dev/null)"
  if [ -z "$left" ]; then pass "$1: no shadow capture or input TSV left in TMP_BASE"
  else fail "$1: shadow files left in TMP_BASE: [$left]"; fi
}
