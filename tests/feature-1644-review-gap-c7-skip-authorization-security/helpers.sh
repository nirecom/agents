# shellcheck shell=bash
# Tests: hooks/workflow-state/plan-skip-allowance.js, hooks/lib/plan-confirm-flag.js, hooks/lib/load-env.js, bin/workflow/next-step
# Tags: tl2, workflow, security, skip-authorization, confirm-tests, scope:issue-specific
# Shared fixtures + assertion helpers for
# tests/feature-1644-review-gap-c7-skip-authorization-security.sh.
# Sourced by the dispatcher — not a standalone runner.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
nrm() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
AGENTS_DIR_N="$(nrm "$AGENTS_DIR")"
NEXT_STEP="$AGENTS_DIR_N/bin/workflow/next-step"
WFSTATE_MODULE="$AGENTS_DIR_N/hooks/workflow-state"; export WFSTATE_MODULE
# CPR-SSOT: the one fixture-state reader shared by every #1644 test file.
PROBE="$AGENTS_DIR_N/tests/feature-1644-advance-transaction/state-probe.js"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 -- expected [$2] got [$3]"; fi; }
check_contains() {
  if printf '%s' "$3" | grep -qF -- "$2"; then pass "$1"; else fail "$1 -- expected [$2] in: $3"; fi
}
check_not_contains() {
  if printf '%s' "$3" | grep -qF -- "$2"; then fail "$1 -- did NOT expect [$2] in: $3"; else pass "$1"; fi
}
run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout 120 "$@"
  else perl -e 'alarm 120; exec @ARGV' -- "$@"; fi
}

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT
WORKFLOW_DIR="$TMPDIR_BASE/wf"; PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_DIR" "$PLANS_DIR"
# Pinned as a PAIR (#1799): a lone CLAUDE_WORKFLOW_DIR still lets supervisor-emit
# append to the developer's real ~/.workflow-plans.
export CLAUDE_WORKFLOW_DIR="$(nrm "$WORKFLOW_DIR")"
export WORKFLOW_PLANS_DIR="$(nrm "$PLANS_DIR")"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
# The ambient CONFIRM_TESTS must never decide any case here — every case pins the
# value in its OWN fixture .env, and the env var is cleared so a leaked export
# from the developer's shell cannot flip a verdict (test-design.md
# "Config-dependent branches", origin #1133).
unset CONFIRM_TESTS

# --- config fixtures: one per value under test ------------------------------
mk_cfg() { local d="$TMPDIR_BASE/$1"; mkdir -p "$d"; printf '%s' "$2" > "$d/.env"; nrm "$d"; }
CFG_OFF="$(mk_cfg cfg-off 'CONFIRM_TESTS=off
')"
CFG_ON="$(mk_cfg cfg-on 'CONFIRM_TESTS=on
')"
CFG_UNSET="$(mk_cfg cfg-unset '')"
CFG_UPPER="$(mk_cfg cfg-upper 'CONFIRM_TESTS=OFF
')"
CFG_PAD="$(mk_cfg cfg-pad 'CONFIRM_TESTS=   off
')"
CFG_PAD_QUOTED="$(mk_cfg cfg-pad-quoted 'CONFIRM_TESTS=" off "
')"

# --- repo fixtures ----------------------------------------------------------
mk_repo() {
  local dir="$1"; mkdir -p "$dir"
  git init -q "$dir" >/dev/null 2>&1
  git -C "$dir" config core.hooksPath /dev/null
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "test"
}
# The PROTECTED repo: a normal code change is staged, so neither the write_tests
# nor the run_tests skip may be authorized from it.
REPO_CODE="$TMPDIR_BASE/repo-code"; mk_repo "$REPO_CODE"
mkdir -p "$REPO_CODE/hooks"; printf '// code\n' > "$REPO_CODE/hooks/thing.js"
git -C "$REPO_CODE" add hooks/thing.js >/dev/null 2>&1
# The ATTACKER-CONTROLLED repo: docs-only staged set. Pointing CLAUDE_PROJECT_DIR
# here is the forgery the run_tests door must ignore.
REPO_DOCS="$TMPDIR_BASE/repo-docs"; mk_repo "$REPO_DOCS"
mkdir -p "$REPO_DOCS/docs"; printf 'doc\n' > "$REPO_DOCS/docs/note.md"
git -C "$REPO_DOCS" add docs/note.md >/dev/null 2>&1
REPO_CODE_N="$(nrm "$REPO_CODE")"; REPO_DOCS_N="$(nrm "$REPO_DOCS")"
cd "$TMPDIR_BASE" || exit 1
export CLAUDE_PROJECT_DIR="$REPO_CODE_N"
export AGENTS_CONFIG_DIR="$CFG_UNSET"

STEPS_ALL="workflow_init clarify_intent research outline detail branching_complete write_tests review_tests write_code run_tests review_security docs user_verification cleanup pre_final_report_gate final_report"
make_state() {
  local sid="$1" complete="$2" json='{"steps":{' first=1 s st
  for s in $STEPS_ALL; do
    st="pending"; case " $complete " in *" $s "*) st="complete" ;; esac
    [ $first -eq 1 ] || json="$json,"; first=0
    json="$json\"$s\":{\"status\":\"$st\"}"
  done
  printf '%s' "$json},\"closes_issues\":[1644]}" > "$WORKFLOW_DIR/${sid}.json"
}
at_write_tests() { make_state "$1" "workflow_init clarify_intent research outline detail branching_complete"; }
at_run_tests()   { make_state "$1" "workflow_init clarify_intent research outline detail branching_complete write_tests review_tests"; }

probe() {
  PROBE_SID="$1" PROBE_STEP="$2" PROBE_FIELD="${4:-}" \
    run_with_timeout node "$PROBE" "$3" 2>/dev/null || echo "PROBE_FAIL"
}
step_status() { probe "$1" "$2" field status; }
state_bytes() { cat "$WORKFLOW_DIR/${1}.json" 2>/dev/null | tr -d '\r'; }
# Protected-resource fingerprint: staged/unstaged status PLUS a full listing, so
# a refusal that quietly created or rewrote a file is caught even when git would
# not report it (ignored paths, mode-only changes).
repo_fingerprint() {
  local d="$1"
  git -C "$d" status --porcelain
  (cd "$d" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort)
}

OUT=""; ERR=""; RC=0
# run_ns <cwd> <config-dir> <project-dir> [ENV=VAL ...] -- <argv...>
# Inline ENV=VAL pairs are applied to the CHILD's environment only — that is
# precisely the forgery shape under test, so they are passed the same way a
# model-issued Bash command would type them.
run_ns() {
  local cwd="$1" cfg="$2" proj="$3"; shift 3
  local -a envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift || true
  local errf="$TMPDIR_BASE/ns.err"
  RC=0
  OUT="$(cd "$cwd" && env AGENTS_CONFIG_DIR="$cfg" CLAUDE_PROJECT_DIR="$proj" \
    ${envs[@]+"${envs[@]}"} \
    node "$NEXT_STEP" "$@" 2>"$errf")" || RC=$?
  ERR="$(cat "$errf" 2>/dev/null || echo "")"
}
action_lines() { printf '%s\n' "$OUT" | grep -c '^ACTION=' || true; }

REASON="the change is documentation only, no test surface exists"
STATE_BEFORE=""; REPO_BEFORE=""

# assert_refused <label> <sid> <step>  — Pattern 1 negative assertion bundle.
# Requires STATE_BEFORE / REPO_BEFORE to have been captured before the call.
assert_refused() {
  local label="$1" sid="$2" step="$3"
  check "$label: exit 3 (skip refused by policy)" 3 "$RC"
  check "$label: no ADVANCED= line" "" "$(printf '%s' "$OUT" | grep -o 'ADVANCED=' || true)"
  check "$label: no ACTION= block" 0 "$(action_lines)"
  check "$label: the step is still pending" '"pending"' "$(step_status "$sid" "$step")"
  check "$label: the state file is byte-for-byte unchanged" "$STATE_BEFORE" "$(state_bytes "$sid")"
  check "$label: the protected repo is untouched" "$REPO_BEFORE" "$(repo_fingerprint "$REPO_CODE")"
}
