# shellcheck shell=bash
# Tests: hooks/lib/sentinel-patterns.js, hooks/workflow-state/state-io/core.js, settings.json, hooks/workflow-gate.js, hooks/workflow-mark/mark-step-handler.js
# Tags: tl1, tl2, workflow, run-tests, docs-only, registration-sites, scope:issue-specific
# Shared fixtures + assertion helpers for tests/feature-1644-run-tests-registration-sites.sh.
# Sourced by the dispatcher — not a standalone runner.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
nrm() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
AGENTS_DIR_N="$(nrm "$AGENTS_DIR")"
export AGENTS_DIR AGENTS_DIR_N

WORKFLOW_MARK_N="$AGENTS_DIR_N/hooks/workflow-mark.js"
WORKFLOW_GATE_N="$AGENTS_DIR_N/hooks/workflow-gate.js"
WFSTATE_MODULE="$AGENTS_DIR_N/hooks/workflow-state"
# Reused read-only probe (CPR-SSOT: one fixture-state reader for all #1644 tests).
PROBE_N="$AGENTS_DIR_N/tests/feature-1644-advance-transaction/state-probe.js"
export WORKFLOW_MARK_N WORKFLOW_GATE_N WFSTATE_MODULE PROBE_N

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT
export TMPDIR_BASE

WORKFLOW_DIR="$TMPDIR_BASE/wf"
PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_DIR" "$PLANS_DIR"
# Dual-pin (#1799): pinning only one of the pair lets supervisor-emit append to
# the developer's real ~/.workflow-plans/.
export CLAUDE_WORKFLOW_DIR="$(nrm "$WORKFLOW_DIR")"
export WORKFLOW_PLANS_DIR="$(nrm "$PLANS_DIR")"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

# Empty config dir: no CONFIRM_* is inherited from the repo's .env, and
# isAgentsSessionRepo() cannot resolve it as a git tree so the gate stays
# fail-closed (enforcement ON) for the fixture repos.
CONFIG_EMPTY="$TMPDIR_BASE/cfg-empty"
mkdir -p "$CONFIG_EMPTY"
: > "$CONFIG_EMPTY/.env"
export AGENTS_CONFIG_DIR="$(nrm "$CONFIG_EMPTY")"

mk_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git init -q "$dir" >/dev/null 2>&1
  git -C "$dir" config core.hooksPath /dev/null
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "test"
}
# The two repos differ ONLY in what is staged: docs-only is the single variable.
REPO_DOCS="$TMPDIR_BASE/repo-docs"
REPO_CODE="$TMPDIR_BASE/repo-code"
mk_repo "$REPO_DOCS"
mkdir -p "$REPO_DOCS/docs"
printf 'doc\n' > "$REPO_DOCS/docs/note.md"
git -C "$REPO_DOCS" add docs/note.md >/dev/null 2>&1
mk_repo "$REPO_CODE"
mkdir -p "$REPO_CODE/hooks"
printf '// code\n' > "$REPO_CODE/hooks/thing.js"
git -C "$REPO_CODE" add hooks/thing.js >/dev/null 2>&1
REPO_DOCS_N="$(nrm "$REPO_DOCS")"
REPO_CODE_N="$(nrm "$REPO_CODE")"
export REPO_DOCS REPO_CODE REPO_DOCS_N REPO_CODE_N
cd "$TMPDIR_BASE" || exit 1

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

# #1665 inserted write_code between review_tests and run_tests. It must appear in BOTH
# lists: in STEPS_ALL so the fixture keeps enumerating every VALID_STEPS entry, and in the
# settled prefix because write_code is NOT skippable — left pending it, not run_tests,
# would be the first non-settled step and every case below would be aimed at the wrong step.
STEPS_ALL="workflow_init clarify_intent research outline detail branching_complete write_tests review_tests write_code run_tests review_security docs user_verification cleanup pre_final_report_gate final_report"
SETTLED_BEFORE_RUN_TESTS=" workflow_init clarify_intent research outline detail branching_complete write_tests review_tests write_code "

# at_run_tests <sid> — state whose first non-settled step is run_tests.
at_run_tests() {
  local sid="$1" json='{"steps":{' first=1 s st
  for s in $STEPS_ALL; do
    st="pending"
    case "$SETTLED_BEFORE_RUN_TESTS" in *" $s "*) st="complete" ;; esac
    [ $first -eq 1 ] || json="$json,"
    first=0
    json="$json\"$s\":{\"status\":\"$st\"}"
  done
  json="$json},\"closes_issues\":[1644]}"
  printf '%s' "$json" > "$WORKFLOW_DIR/${sid}.json"
}

# run_mark_hook <sid> <bash-command-string> — PostToolUse payload into workflow-mark.js.
run_mark_hook() {
  local sid="$1" cmd="$2" esc
  esc=${cmd//\\/\\\\}
  esc=${esc//\"/\\\"}
  printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"%s"}}' "$sid" "$esc" \
    | run_with_timeout node "$WORKFLOW_MARK_N" 2>&1 || true
}

# run_gate_hook <sid> <bash-command-string> — PreToolUse payload into workflow-gate.js.
run_gate_hook() {
  local sid="$1" cmd="$2" esc
  esc=${cmd//\\/\\\\}
  esc=${esc//\"/\\\"}
  printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"%s"}}' "$sid" "$esc" \
    | run_with_timeout node "$WORKFLOW_GATE_N" 2>&1 || true
}

step_status() {
  PROBE_SID="$1" PROBE_STEP="$2" PROBE_FIELD="status" \
    run_with_timeout node "$PROBE_N" field 2>/dev/null || echo "PROBE_FAIL"
}

SENTINEL_LITERAL='WORKFLOW_RUN_TESTS_NOT_NEEDED'
SENTINEL_ECHO='echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: staged set is human-facing docs only>>"'
SENTINEL_BARE='echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED>>"'
export SENTINEL_LITERAL SENTINEL_ECHO SENTINEL_BARE
