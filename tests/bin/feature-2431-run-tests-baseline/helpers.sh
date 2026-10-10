# shellcheck shell=bash
# tests/bin/feature-2431-run-tests-baseline/helpers.sh
# Tests: bin/run-tests-baseline
# Tags: run-tests, baseline, helpers, scope:issue-specific, pwsh-not-required, TL2
# Shared setup for the feature-2431-run-tests-baseline dispatcher.
# Sourced by the dispatcher; never run standalone.

set -uo pipefail

_HELPERS_SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
AGENTS_WIN="$(if command -v cygpath >/dev/null 2>&1; then cygpath -m "$_HELPERS_SCRIPT_CHECKOUT_ROOT"; else echo "$_HELPERS_SCRIPT_CHECKOUT_ROOT"; fi)"
np() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

LEDGER_LIB="$_HELPERS_SCRIPT_CHECKOUT_ROOT/bin/lib/run-tests-baseline-ledger.sh"
WORKTREE_LIB="$_HELPERS_SCRIPT_CHECKOUT_ROOT/bin/lib/run-tests-baseline-worktree.sh"
EXEC_LIB="$_HELPERS_SCRIPT_CHECKOUT_ROOT/bin/lib/run-tests-baseline-exec.sh"
HOMEREF_LIB="$_HELPERS_SCRIPT_CHECKOUT_ROOT/bin/lib/run-tests-baseline-homeref.sh"
TLR_LIB="$_HELPERS_SCRIPT_CHECKOUT_ROOT/bin/lib/test-language-registry.sh"
MARKER_JS="$_HELPERS_SCRIPT_CHECKOUT_ROOT/hooks/lib/baseline-checkout-marker.js"
BASELINE_CLI="$_HELPERS_SCRIPT_CHECKOUT_ROOT/bin/run-tests-baseline"
EVIDENCE_CLI="$_HELPERS_SCRIPT_CHECKOUT_ROOT/bin/workflow/run-tests-baseline-evidence"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPROOT="$(mktemp -d)"
[[ -n "$TMPROOT" && -d "$TMPROOT" ]] || { echo "cannot create a temp root" >&2; exit 1; }
readonly TMPROOT
# OWN_CACHE_DIR: the decoy cache the dispatcher made for the harness when no launcher gave one.
trap 'chmod -R u+rwx "$TMPROOT" >/dev/null 2>&1 || true; rm -rf "$TMPROOT"; [[ -z "${OWN_CACHE_DIR:-}" ]] || rm -rf "$OWN_CACHE_DIR"' EXIT

# Workflow isolation (rules/test/fixture-isolation.md).
WF_DIR="$TMPROOT/workflow-state"
PLANS_DIR="$TMPROOT/plans"
mkdir -p "$WF_DIR" "$PLANS_DIR"
export WORKFLOW_STATE_DIR="$(np "$WF_DIR")"
export WORKFLOW_PLANS_DIR="$(np "$PLANS_DIR")"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
# No process started here reads the developer's home (Node on Windows reads USERPROFILE).
mkdir -p "$TMPROOT/home" || exit 1
HOME="$(np "$TMPROOT/home")"
export HOME USERPROFILE="$HOME"

# Baseline cache in a temp dir so the real ~/.claude/run-all is never touched.
export RUN_ALL_CACHE_DIR="$TMPROOT/run-all-cache"
mkdir -p "$RUN_ALL_CACHE_DIR"

run_with_timeout() { bash "$_HELPERS_SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" "$@"; }

# rtb_call <timeout> <lib> <fn> [args...] — a lib function runs in a child bash,
# because run-with-timeout execs a program and shell functions do not cross exec.
rtb_call() {
  local t="$1" lib="$2"; shift 2
  run_with_timeout "$t" bash -c '. "$1" || exit 98; shift; "$@"' rtb_call "$lib" "$@"
}

# homeref_call <path...> — rtb_has_home_ref in a child bash with the registry loaded; returns its rc
# (0 = reference or undeterminable, 1 = none outside comment lines; 98 = a lib could not be sourced).
# HOMEREF_PATH_PREFIX, when set, is put on PATH only after the registry loads, so a stub shadows
# awk/find for the helper alone and never for run-with-timeout or tlr_load.
homeref_call() {
  run_with_timeout 60 bash -c '. "$1" || exit 98; . "$2" || exit 98; tlr_load || exit 97; shift 2; [ -z "${HOMEREF_PATH_PREFIX:-}" ] || PATH="$HOMEREF_PATH_PREFIX:$PATH"; rtb_has_home_ref "$@"' homeref_call "$TLR_LIB" "$HOMEREF_LIB" "$@"
}

# ledger_call <cache-dir> <cwd> <fn> [args...] — ledger lib call with a pinned cache dir.
ledger_call() {
  local cache="$1" cwd="$2"; shift 2
  (cd "$cwd" && export RUN_ALL_CACHE_DIR="$cache" && rtb_call 30 "$LEDGER_LIB" "$@")
}

# rtb_cli_run <cache> <worktree> <sid> [--per-test-timeout N] — plan CLI interface
# `--session <sid> --worktree <path>`; sets RTB_CLI_RC and RTB_CLI_OUT (stdout+stderr).
rtb_cli_run() {
  local cache="$1" repo="$2" sid="$3"; shift 3
  local -a extra=("$@")
  [ "${#extra[@]}" -gt 0 ] || extra=(--per-test-timeout 10)
  RTB_CLI_RC=0
  RTB_CLI_OUT="$(cd "$TMPROOT" && export RUN_ALL_CACHE_DIR="$cache" && run_with_timeout 120 \
    bash "$BASELINE_CLI" --session "$sid" --worktree "$repo" "${extra[@]}" 2>&1)" \
    || RTB_CLI_RC=$?
}

# mk_fixture_repo — git repo with main@base + feature@HEAD, so merge-base resolves
# RESOLVED against `main` (bin/resolve-merge-base.sh layer 2). Prints the base SHA.
mk_fixture_repo() {
  local repo="$1"
  git init -q "$repo"
  git -C "$repo" config core.hooksPath /dev/null
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name Test
  git -C "$repo" config commit.gpgsign false
  git -C "$repo" config core.autocrlf false
  git -C "$repo" symbolic-ref HEAD refs/heads/main
  mkdir -p "$repo/tests/bin"

  # Test that always fails at base → preexisting.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$repo/tests/bin/test-preexisting.sh"
  # Test that always passes at base → broken (fails at HEAD, passes at base).
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/tests/bin/test-broken.sh"
  # Test that sleeps → timeout-at-base with short per-test-timeout.
  printf '#!/usr/bin/env bash\nsleep 9999\n' > "$repo/tests/bin/test-sleep.sh"
  # Test with $HOME/.claude reference → home-claude-ref (detection before exec).
  printf '#!/usr/bin/env bash\necho "$HOME/.claude/settings"\nexit 1\n' \
    > "$repo/tests/bin/test-homeref.sh"
  # Test that exits 77 → skip-at-base.
  printf '#!/usr/bin/env bash\nexit 77\n' > "$repo/tests/bin/test-skip.sh"
  chmod +x "$repo/tests/bin/"*.sh

  git -C "$repo" add tests/
  git -C "$repo" commit -q -m "base"
  local base_sha
  base_sha="$(git -C "$repo" rev-parse HEAD)"

  # Feature branch with one more commit (HEAD).
  git -C "$repo" checkout -q -b feature
  printf 'head\n' > "$repo/head.txt"
  git -C "$repo" add head.txt
  git -C "$repo" commit -q -m "head"

  printf '%s\n' "$base_sha"
}

# seed_failing <sid> <test-path...>
# Seeds run_tests=pending with run_outcome=fail and failing_tests=[...].
seed_failing() {
  local sid="$1"; shift
  local test_list=()
  while [ "$#" -gt 0 ]; do test_list+=("\"$1\""); shift; done
  local tests_json="[$(printf '%s,' "${test_list[@]}" | sed 's/,$//')]"

  local seed_js
  seed_js="$TMPROOT/seed-$$.js"
  cat > "$seed_js" << 'JSCODE'
"use strict";
const agents = process.argv[2];
const sid    = process.argv[3];
const tests  = JSON.parse(process.argv[4]);
try {
  const { appendEvents } = require(agents + "/hooks/workflow-state/state-io/events");
  appendEvents(sid, [
    { kind: "step_status", step: "run_tests", status: "pending",
      provenance: "observed", origin: "run-tests-hook" },
    { kind: "step_annotation", step: "run_tests", key: "run_outcome", value: "fail",
      provenance: "observed", origin: "run-tests-hook" },
    { kind: "step_annotation", step: "run_tests", key: "failing_tests", value: tests,
      provenance: "observed", origin: "run-tests-hook" }
  ]);
} catch (e) {
  process.stderr.write("seed-err: " + e.message + "\n");
  process.exit(1);
}
JSCODE
  run_with_timeout 20 node "$(np "$seed_js")" "$AGENTS_WIN" "$sid" "$tests_json" >/dev/null 2>&1 || true
  rm -f "$seed_js"
}

# read_step_field <sid> <step> <field>
read_step_field() {
  local probe_js="$TMPROOT/probe-$$.js"
  cat > "$probe_js" << 'JSCODE'
"use strict";
try {
  const s = require(process.argv[2] + "/hooks/workflow-state").readState(process.argv[3]);
  const e = s && s.steps && s.steps[process.argv[4]];
  const v = e ? e[process.argv[5]] : undefined;
  process.stdout.write(v === undefined || v === null ? "(absent)" : JSON.stringify(v));
} catch (err) { process.stdout.write("(absent)"); }
JSCODE
  run_with_timeout 15 node "$(np "$probe_js")" "$AGENTS_WIN" "$1" "$2" "$3" 2>/dev/null \
    || echo "(absent)"
  rm -f "$probe_js"
}
