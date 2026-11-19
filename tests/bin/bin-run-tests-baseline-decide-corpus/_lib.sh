# shellcheck shell=bash
# tests/bin/bin-run-tests-baseline-decide-corpus/_lib.sh
# Tests: bin/run-tests-baseline
# Tags: run-tests, baseline, decide-shadow, corpus, helper, scope:common, pwsh-not-required, TL2
# Shared fixture of corpus (1). Puts many tests in one repo and runs the real CLI only once.
# The repo's bin/lib/run-all-launch.sh is a stub that reads corpus-spec/<stem> (outside the test and its data dir)
# and produces state / rc / LAUNCHED / HITS / err hit lines / cases.tsv / fail-details.tsv.
# corpus-spec holds the merge base side result on main (merge base) and the branch side result on feature (HEAD).
# The "test changed" axis is made by appending one line to the test body on feature. See cps_table for the table format.
# The caller sets SCRIPT_CHECKOUT_ROOT and sources tests/lib/harness.sh before this file. Not run on its own.

: "${SCRIPT_CHECKOUT_ROOT:?set SCRIPT_CHECKOUT_ROOT before sourcing}"
declare -F harness_isolate >/dev/null || { echo "FAIL: source tests/lib/harness.sh before _lib.sh"; exit 1; }

BASELINE_CLI="$SCRIPT_CHECKOUT_ROOT/bin/run-tests-baseline"
CPS_REAL_HOME="${HOME:-}"
TMPROOT="$(make_tmp)"
readonly TMPROOT
trap 'chmod -R u+rwx "$TMPROOT" >/dev/null 2>&1 || true; rm -rf "$TMPROOT"' EXIT
harness_isolate "$TMPROOT/iso"
export WORKFLOW_STATE_DIR="$(np "$TMPROOT/iso/workflow-state")" WORKFLOW_PLANS_DIR="$(np "$TMPROOT/iso/plans")"
unset CLAUDE_CODE_SESSION_ID RTB_BUDGET_TOTAL RUN_ALL_TIMEOUT_SECONDS
unset RUN_TESTS_BASELINE_DECIDE_SHADOW RUN_TESTS_BASELINE_DECIDE_SHADOW_FAULT_FOR_TEST
mkdir -p "$TMPROOT/transcripts" "$TMPROOT/home" "$TMPROOT/cwd" "$TMPROOT/cache" "$TMPROOT/systmp"
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMPROOT/transcripts"
HOME="$(np "$TMPROOT/home")"
export HOME USERPROFILE="$HOME"
# Point every CLI write (cache, TMP_BASE, mktemp) under the test's tmp.
export RUN_ALL_CACHE_DIR="$(np "$TMPROOT/cache")" TMPDIR="$(np "$TMPROOT/systmp")"
export DEFAULT_BRANCHES=main
# Giving these a value lets rtb_exec_one's carried read skip a get-config-var start per test (the stub does not read them).
export RUN_TL3="${RUN_TL3-}" RUN_TL4="${RUN_TL4-}"
AGENTS_WIN="$(np "$SCRIPT_CHECKOUT_ROOT")"
# shellcheck source=tests/bin/bin-run-tests-baseline-decide-corpus/assert-divergence-log.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/bin-run-tests-baseline-decide-corpus/assert-divergence-log.sh"

SEED_JS="$TMPROOT/seed.js"
cat >"$SEED_JS" <<'JSCODE'
"use strict";
// argv: agents sid paths-json exits-json
const [agents, sid, paths, exits] = process.argv.slice(2);
const a = (key, value) => ({ kind: "step_annotation", step: "run_tests", key, value,
  provenance: "observed", origin: "run-tests-hook" });
try {
  require(agents + "/hooks/workflow-state/state-io/events").appendEvents(sid, [
    { kind: "step_status", step: "run_tests", status: "pending", provenance: "observed", origin: "run-tests-hook" },
    a("run_outcome", "fail"), a("failing_tests", JSON.parse(paths)), a("unrunnable_count", 0),
    a("failing_test_exits", JSON.parse(exits))]);
} catch (e) { process.stderr.write("seed-error: " + e.message + "\n"); process.exit(1); }
JSCODE

# stub launcher. cwd is the checkout rtb_exec_one cd'ed into (the base worktree or HEAD).
CPS_STUB="$TMPROOT/run-all-launch.sh"
cat >"$CPS_STUB" <<'STUB'
# corpus stub launcher: returns a result following corpus-spec/<stem>, one token per line (key TAB value...).
run_all_exec() {
  local t="$1" out="$2" err="$3" res="$4" stem k a b c rc=1 n=0
  stem="${t##*/}"; stem="${stem%.*}"
  : >"$out"; : >"$err"
  RUN_ALL_EXEC_LAUNCHED=1
  [ -f "corpus-spec/$stem" ] || return 1
  while IFS=$'\t' read -r k a b c; do
    case "$k" in
      state) RUN_ALL_EXEC_STATE="$a" ;;
      rc) rc="$a" ;;
      launched) RUN_ALL_EXEC_LAUNCHED="$a" ;;
      hits) RUN_ALL_EXEC_HITS="$a" ;;
      missing) RUN_ALL_EXEC_MISSING="$a" ;;
      err) case "$a" in
             guard) printf '[run-all] command guard hit: corpus\n' >>"$err" ;;
             decoy) printf '[run-all] root decoy hit: corpus\n' >>"$err" ;;
             wtchange) printf '[run-all] worktree change: corpus\n' >>"$err" ;;
           esac ;;
      case) n=$((n + 1))
            printf '%s\t%s\t%s\t-\n' "$n" "$a" "$b" >>"$res/cases.tsv"
            [ "$a" != FAIL ] || [ -z "$c" ] || printf '%s\t%s\t%s\n' "$n" "$b" "$c" >>"$res/fail-details.tsv" ;;
    esac
  done <"corpus-spec/$stem"
  return "$rc"
}
STUB

# One table row: <file>|<changed y/n>|<recorded exit or ->|<base spec>|<branch spec>|<live class> <live detail>|<shadow expectation>
# A spec is space-separated tokens (key:value[:value2[:value3]], e.g. state:FAIL rc:1 case:FAIL:case-a:line-X).
# The shadow expectation is match / recorded / no:<reason>. Reading fills the CPS_* arrays.
CPS_F=() CPS_CH=() CPS_EX=() CPS_BASE=() CPS_BR=() CPS_LIVE=() CPS_WANT=()
cps_table() {
  local f ch ex ba br live want
  while IFS='|' read -r f ch ex ba br live want; do
    [ -n "$f" ] && [ "${f#\#}" = "$f" ] || continue
    CPS_F+=("$f") CPS_CH+=("$ch") CPS_EX+=("$ex") CPS_BASE+=("$ba") CPS_BR+=("$br") CPS_LIVE+=("$live") CPS_WANT+=("$want")
  done
}

_cps_spec() { local tok; for tok in $1; do printf '%s\n' "${tok//:/$'\t'}"; done; }
_cps_body() {
  case "$1" in
    *.js) printf '// corpus %s\nprocess.exit(1);\n' "$1" ;;
    *) printf '#!/usr/bin/env bash\n# corpus %s\nexit 1\n' "$1" ;;
  esac
}

# cps_build <repo> — main gets the stub, every test and the base spec; feature gets the branch spec and the "change".
cps_build() {
  local repo="$1" i f
  harness_git_init "$repo"
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name T
  git -C "$repo" config commit.gpgsign false
  git -C "$repo" config core.autocrlf false
  git -C "$repo" symbolic-ref HEAD refs/heads/main
  mkdir -p "$repo/tests/bin" "$repo/bin/lib" "$repo/corpus-spec"
  cp "$CPS_STUB" "$repo/bin/lib/run-all-launch.sh"
  for i in "${!CPS_F[@]}"; do
    f="${CPS_F[$i]}"
    _cps_body "$f" >"$repo/tests/bin/$f"
    _cps_spec "${CPS_BASE[$i]}" >"$repo/corpus-spec/${f%.*}"
  done
  git -C "$repo" add -A; git -C "$repo" commit -q -m base || return 1
  git -C "$repo" checkout -q -b feature
  for i in "${!CPS_F[@]}"; do
    f="${CPS_F[$i]}"
    _cps_spec "${CPS_BR[$i]}" >"$repo/corpus-spec/${f%.*}"
    [ "${CPS_CH[$i]}" != y ] || printf '# changed on branch\n' >>"$repo/tests/bin/$f"
  done
  git -C "$repo" add -A; git -C "$repo" commit -q -m head
}

_cps_shadow_files() { ls -1 "$CPS_REAL_HOME/.claude/run-all/baseline/decide-shadow" 2>/dev/null; }

# cps_run <repo> <sid> — seeds every test of the table into the failing list and runs the CLI once (no --per-test-timeout).
cps_run() {
  local repo="$1" sid="$2" i paths="" exits="" before
  for i in "${!CPS_F[@]}"; do
    paths="$paths${paths:+,}\"tests/bin/${CPS_F[$i]}\""
    [ "${CPS_EX[$i]}" = - ] || exits="$exits${exits:+,}\"tests/bin/${CPS_F[$i]}\":${CPS_EX[$i]}"
  done
  run_with_timeout 30 node "$(np "$SEED_JS")" "$AGENTS_WIN" "$sid" "[$paths]" "{$exits}" >/dev/null 2>&1 \
    || fail "fixture: cannot seed the failing list of $sid"
  before="$(_cps_shadow_files)"
  CPS_RC=0
  CPS_START=$SECONDS
  CPS_OUT="$(cd "$TMPROOT/cwd" && run_with_timeout 150 bash "$BASELINE_CLI" --session "$sid" --worktree "$(np "$repo")" 2>&1)" || CPS_RC=$?
  CPS_SECS=$((SECONDS - CPS_START))
  echo "INFO: one CLI run ${CPS_SECS}s rc=$CPS_RC tests=${#CPS_F[@]}"
  CPS_REAL_SHADOW_SAME=1
  [ "$before" = "$(_cps_shadow_files)" ] || CPS_REAL_SHADOW_SAME=0
}

# cps_assert_live — each row's BASELINE line matches the current CLI's classification (the oracle).
cps_assert_live() {
  local i rel cls det
  for i in "${!CPS_F[@]}"; do
    rel="tests/bin/${CPS_F[$i]}" cls="${CPS_LIVE[$i]%% *}" det="${CPS_LIVE[$i]#* }"
    if printf '%s\n' "$CPS_OUT" | grep -qxF "BASELINE: $cls $rel $det"; then pass "live: $rel is $cls $det"
    else fail "live: $rel should be $cls $det: $(printf '%s\n' "$CPS_OUT" | grep -E "^BASELINE: [^ ]+ $rel( |$)" | head -n 1)"; fi
  done
  if printf '%s\n' "$CPS_OUT" | grep -q '^BASELINE_SUMMARY: '; then pass "live: the CLI reached the hand-off (rc=$CPS_RC)"
  else fail "live: no BASELINE_SUMMARY (rc=$CPS_RC): $CPS_OUT"; fi
}

# cps_assert_writes — writes stay under the test's tmp.
cps_assert_writes() {
  if [ "$CPS_REAL_SHADOW_SAME" = 1 ] && [ ! -e "$HOME/.claude/run-all" ]; then
    pass "writes: nothing written to the run-all cache of the real \$HOME or the fixture \$HOME"
  else
    fail "writes: something was written to a run-all cache outside the test's tmp"
  fi
  if [ -z "$(find "$RUN_ALL_CACHE_DIR/baseline/tmp" -name '*decide-shadow*' 2>/dev/null)" ]; then
    pass "writes: no shadow temp file left in TMP_BASE"
  else
    fail "writes: a shadow temp file is left in TMP_BASE"
  fi
}

# cps_assert_shadow <label> — each table path's log line matches its expectation (match / recorded / no:<reason>).
cps_assert_shadow() {
  local i
  for i in "${!CPS_F[@]}"; do adl_expect "$1" "tests/bin/${CPS_F[$i]}" "${CPS_WANT[$i]}" "${CPS_LIVE[$i]}"; done
}

# cps_counts — counts the expected compared / no_comparison from the table into CPS_WANT_C / CPS_WANT_N.
cps_counts() {
  local w
  CPS_WANT_C=0 CPS_WANT_N=0
  for w in "${CPS_WANT[@]}"; do
    case "$w" in no:*) CPS_WANT_N=$((CPS_WANT_N + 1)) ;; *) CPS_WANT_C=$((CPS_WANT_C + 1)) ;; esac
  done
}
