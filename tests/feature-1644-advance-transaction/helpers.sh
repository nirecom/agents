# shellcheck shell=bash
# Tests: bin/workflow/next-step, bin/workflow/lib/next-step/advance.js, hooks/workflow-state/record-step-verdict.js
# Tags: tl2, workflow, next-step, advance, scope:issue-specific
# Shared fixtures + assertion helpers for tests/feature-1644-advance-transaction.sh.
# Sourced by the dispatcher — not a standalone runner.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
nrm() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
AGENTS_DIR_N="$(nrm "$AGENTS_DIR")"

NEXT_STEP_N="$AGENTS_DIR_N/bin/workflow/next-step"
WORKFLOW_MARK_N="$AGENTS_DIR_N/hooks/workflow-mark.js"
WFSTATE_MODULE="$AGENTS_DIR_N/hooks/workflow-state"
PROBE_N="$AGENTS_DIR_N/tests/feature-1644-advance-transaction/state-probe.js"
export WFSTATE_MODULE

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

WORKFLOW_DIR="$TMPDIR_BASE/wf"
PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_DIR" "$PLANS_DIR"

# Plans-dir isolation (#1799): CLAUDE_WORKFLOW_DIR and WORKFLOW_PLANS_DIR are
# pinned as a PAIR so supervisor-emit never appends to the developer's real
# ~/.workflow-plans/. Exported once here so every child node inherits them.
export CLAUDE_WORKFLOW_DIR="$(nrm "$WORKFLOW_DIR")"
export WORKFLOW_PLANS_DIR="$(nrm "$PLANS_DIR")"

# The parent Claude Code session exports these; leaving them set would make the
# CLI resolve the LIVE session and mutate its real state file.
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

# Config-dependent branches (CONFIRM_*) must be pinned per case, never inherited
# from the repo's .env. An empty fixture config dir makes readDefaultEnvFile()
# and loadDefaultEnv() see NO CONFIRM_* at all; cases that need one write their
# own .env into a dedicated dir.
CONFIG_EMPTY="$TMPDIR_BASE/cfg-empty"
mkdir -p "$CONFIG_EMPTY"
: > "$CONFIG_EMPTY/.env"
CONFIG_EMPTY_N="$(nrm "$CONFIG_EMPTY")"
export AGENTS_CONFIG_DIR="$CONFIG_EMPTY_N"

# Neutral CWD: a throwaway git repo, so hooks that shell out to `git rev-parse`
# resolve the fixture and never the real worktree.
FIXTURE_REPO="$TMPDIR_BASE/repo"
mkdir -p "$FIXTURE_REPO"
git init -q "$FIXTURE_REPO" >/dev/null 2>&1
git -C "$FIXTURE_REPO" config core.hooksPath /dev/null
export CLAUDE_PROJECT_DIR="$(nrm "$FIXTURE_REPO")"
cd "$FIXTURE_REPO" || exit 1

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then pass "$desc"
  else fail "$desc -- expected [$expected] got [$actual]"; fi
}
check_contains() {
  local desc="$1" needle="$2" hay="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then pass "$desc"
  else fail "$desc -- expected [$needle] in: $hay"; fi
}
check_not_contains() {
  local desc="$1" needle="$2" hay="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then fail "$desc -- did NOT expect [$needle] in: $hay"
  else pass "$desc"; fi
}

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout 120 "$@"
  else perl -e 'alarm 120; exec @ARGV' -- "$@"; fi
}

# --- fixture builders -------------------------------------------------------
STEPS_ALL="workflow_init clarify_intent research outline detail branching_complete write_tests review_tests run_tests review_security docs user_verification cleanup pre_final_report_gate final_report"

# make_state <sid> "<space separated complete steps>" [extra-top-level-json]
make_state() {
  local sid="$1" complete="$2" extra="${3:-}" json='{"steps":{' first=1 s st
  for s in $STEPS_ALL; do
    st="pending"
    case " $complete " in *" $s "*) st="complete" ;; esac
    [ $first -eq 1 ] || json="$json,"
    first=0
    json="$json\"$s\":{\"status\":\"$st\"}"
  done
  json="$json},\"closes_issues\":[1644]$extra}"
  printf '%s' "$json" > "$WORKFLOW_DIR/${sid}.json"
}

# Fixture shorthands. The named step is the first non-settled one, i.e. currentStep.
at_research()  { make_state "$1" "workflow_init clarify_intent" "${2:-}"; }
at_outline()   { make_state "$1" "workflow_init clarify_intent research" "${2:-}"; }
at_wfinit()    { make_state "$1" "research" "${2:-}"; }

# --- runners ----------------------------------------------------------------
NS_OUT=""; NS_ERR=""; NS_RC=0
# run_ns <args...> — invoke bin/workflow/next-step, capturing stdout/stderr/rc.
run_ns() {
  local errf="$TMPDIR_BASE/ns.err"
  NS_RC=0
  NS_OUT="$(run_with_timeout node "$NEXT_STEP_N" "$@" 2>"$errf")" || NS_RC=$?
  NS_ERR="$(cat "$errf" 2>/dev/null || echo "")"
}

# run_mark_hook <sid> <bash-command-string> — feed workflow-mark.js a PostToolUse payload.
run_mark_hook() {
  local sid="$1" cmd="$2" esc
  esc=${cmd//\\/\\\\}
  esc=${esc//\"/\\\"}
  printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"%s"}}' "$sid" "$esc" \
    | run_with_timeout node "$WORKFLOW_MARK_N" >/dev/null 2>&1 || true
}

# --- state probes -----------------------------------------------------------
probe() {
  local mode="$1" sid="$2" step="${3:-}" field="${4:-}"
  PROBE_SID="$sid" PROBE_STEP="$step" PROBE_FIELD="$field" \
    run_with_timeout node "$PROBE_N" "$mode" 2>/dev/null || echo "PROBE_FAIL"
}
step_status() { probe field "$1" "$2" status; }
step_entry()  { probe entry "$1" "$2"; }
step_audit()  { probe lastevent "$1" "$2"; }
step_sub()    { probe sub "$1" "$2" "$3"; }

# Count of `ACTION=` lines in the captured stdout — the plan's exit 2/3 contract
# is "not a single ACTION line", so the assertion is on the count, not presence.
action_line_count() { printf '%s\n' "$NS_OUT" | grep -c '^ACTION=' || true; }

lock_files_present() { ls "$WORKFLOW_DIR"/*.lock >/dev/null 2>&1 && echo yes || echo no; }
