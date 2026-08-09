#!/usr/bin/env bash
# Tests: hooks/workflow-mark/not-needed-handlers.js, hooks/workflow-mark/mark-step-handler.js, hooks/workflow-state/evidence-resolver.js, hooks/workflow-gate.js, hooks/workflow-gate/staged-evidence.js, bin/workflow/next-step, hooks/lib/sentinel-patterns.js
# Tags: tl2, workflow, run-tests, docs-only, skip-sentinel, classifier, workflow-gate, scope:issue-specific, pwsh-not-required
#
# #1644 review gap C1 (HIGH) — normal + classifier + integration coverage for the
# NEW run_tests docs-only skip. Sibling file tests/feature-1644-run-tests-docs-only.sh
# owns the hint/first-write cases (D1-D6); this file deliberately extends past them:
#   - the AUDIT PAYLOAD of a real sentinel write (skip_reason + provenance/origin),
#     not merely the resulting status;
#   - byte-for-byte state immutability on the rejected (code-staged) verdict,
#     which a status-only assertion cannot prove;
#   - hasCompletionEvidence AFTER a recorded skip (D6 probes it before one);
#   - the PERSISTED status of the --advance --status skipped door (D5b asserts
#     only the stdout ADVANCED line);
#   - the H1 TOCTOU integration: staged set grows to include code AFTER the skip
#     was legitimately recorded, and the real commit gate must stop honoring it.
#
# TL3 gap (what this test does NOT catch):
# - Whether Claude Code's live PreToolUse dispatch actually routes a `git commit`
#   Bash call into hooks/workflow-gate.js (registration is asserted statically in
#   tests/feature-1644-run-tests-registration-sites.sh, not through a real session).
# - Whether the permission layer auto-approves the RUN_TESTS_NOT_NEEDED echo
#   literal in a real dialog.
# - Whether /run-tests SKILL.md emits the sentinel when the model reaches its
#   docs-only branch.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.

set -uo pipefail

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nrm() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
AGENTS_DIR_N="$(nrm "$AGENTS_DIR")"

NEXT_STEP_N="$AGENTS_DIR_N/bin/workflow/next-step"
WORKFLOW_MARK_N="$AGENTS_DIR_N/hooks/workflow-mark.js"
GATE_HOOK_N="$AGENTS_DIR_N/hooks/workflow-gate.js"
WFSTATE_MODULE="$AGENTS_DIR_N/hooks/workflow-state"
# Reused read-only probe (CPR-SSOT: one fixture-state reader for all #1644 tests).
PROBE_N="$AGENTS_DIR_N/tests/feature-1644-advance-transaction/state-probe.js"
export WFSTATE_MODULE

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

WORKFLOW_DIR="$TMPDIR_BASE/wf"
PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_DIR" "$PLANS_DIR"
# Dual-pin (#1799): pinning only one of the pair lets supervisor-emit append to
# the developer's real ~/.workflow-plans/.
export CLAUDE_WORKFLOW_DIR="$(nrm "$WORKFLOW_DIR")"
export WORKFLOW_PLANS_DIR="$(nrm "$PLANS_DIR")"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

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
# Three fixture repos. REPO_DOCS / REPO_CODE differ ONLY in what is staged.
# REPO_MIX starts docs-only and grows a staged code file mid-test — that growth
# is the H1 TOCTOU scenario under test.
REPO_DOCS="$TMPDIR_BASE/repo-docs"
REPO_CODE="$TMPDIR_BASE/repo-code"
REPO_MIX="$TMPDIR_BASE/repo-mix"
mk_repo "$REPO_DOCS"
mkdir -p "$REPO_DOCS/docs"
printf 'doc\n' > "$REPO_DOCS/docs/note.md"
git -C "$REPO_DOCS" add docs/note.md >/dev/null 2>&1
mk_repo "$REPO_CODE"
mkdir -p "$REPO_CODE/hooks"
printf '// code\n' > "$REPO_CODE/hooks/thing.js"
git -C "$REPO_CODE" add hooks/thing.js >/dev/null 2>&1
mk_repo "$REPO_MIX"
mkdir -p "$REPO_MIX/docs" "$REPO_MIX/hooks"
printf 'doc\n' > "$REPO_MIX/docs/note.md"
printf '// code\n' > "$REPO_MIX/hooks/later.js"
git -C "$REPO_MIX" add docs/note.md >/dev/null 2>&1
REPO_DOCS_N="$(nrm "$REPO_DOCS")"
REPO_CODE_N="$(nrm "$REPO_CODE")"
REPO_MIX_N="$(nrm "$REPO_MIX")"
# Neutral CWD: hooks that call `git rev-parse` must not resolve the real repo.
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

STEPS_ALL="workflow_init clarify_intent research outline detail branching_complete write_tests review_tests run_tests review_security docs user_verification cleanup pre_final_report_gate final_report"

# State whose first non-settled step is run_tests.
at_run_tests() {
  local sid="$1" json='{"steps":{' first=1 s st
  for s in $STEPS_ALL; do
    st="pending"
    case " workflow_init clarify_intent research outline detail branching_complete write_tests review_tests " in
      *" $s "*) st="complete" ;;
    esac
    [ $first -eq 1 ] || json="$json,"
    first=0
    json="$json\"$s\":{\"status\":\"$st\"}"
  done
  json="$json},\"closes_issues\":[1644]}"
  printf '%s' "$json" > "$WORKFLOW_DIR/${sid}.json"
}

# Commit-gate-ready state: every gated step settled EXCEPT run_tests, so the gate's
# verdict isolates run_tests as the single variable (review_tests=skipped takes the
# non-BUGFIX skip branch of review-tests-checker.js).
gate_ready() {
  local sid="$1" json='{"steps":{' first=1 s st
  for s in $STEPS_ALL; do
    case "$s" in
      run_tests) st="pending" ;;
      review_tests) st="skipped" ;;
      *) st="complete" ;;
    esac
    [ $first -eq 1 ] || json="$json,"
    first=0
    json="$json\"$s\":{\"status\":\"$st\"}"
  done
  json="$json},\"closes_issues\":[1644]}"
  printf '%s' "$json" > "$WORKFLOW_DIR/${sid}.json"
}

NS_OUT=""; NS_ERR=""; NS_RC=0
run_ns_in() {
  local dir="$1" errf="$TMPDIR_BASE/ns.err"
  shift
  NS_RC=0
  NS_OUT="$(cd "$dir" && run_with_timeout node "$NEXT_STEP_N" "$@" 2>"$errf")" || NS_RC=$?
  NS_ERR="$(cat "$errf" 2>/dev/null || echo "")"
}
run_mark_hook() {
  local sid="$1" cmd="$2" esc
  esc=${cmd//\\/\\\\}
  esc=${esc//\"/\\\"}
  printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"%s"}}' "$sid" "$esc" \
    | run_with_timeout node "$WORKFLOW_MARK_N" 2>&1 || true
}
# Real PreToolUse payload for a `git -C <repo> commit` Bash call. `-C` is Tier 1 of
# resolveRepoDir, so the gate judges the fixture repo deterministically.
run_gate_commit() {
  local sid="$1" repo="$2"
  printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"git -C %s commit -m \\"x\\"","cwd":"%s"}}' \
    "$sid" "$repo" "$repo" \
    | run_with_timeout node "$GATE_HOOK_N" 2>/dev/null || true
}
step_field() {
  PROBE_SID="$1" PROBE_STEP="$2" PROBE_FIELD="$3" \
    run_with_timeout node "$PROBE_N" field 2>/dev/null || echo "PROBE_FAIL"
}
step_lastevent() {
  PROBE_SID="$1" PROBE_STEP="$2" \
    run_with_timeout node "$PROBE_N" lastevent 2>/dev/null || echo "PROBE_FAIL"
}
raw_state() { cat "$WORKFLOW_DIR/${1}.json" 2>/dev/null || echo "MISSING"; }
evidence_run_tests() {
  local sid="$1" repo="$2"
  WFSTATE_MODULE="$WFSTATE_MODULE" EV_SID="$sid" EV_REPO="$repo" run_with_timeout node -e '
const { hasCompletionEvidence } = require(process.env.WFSTATE_MODULE + "/evidence-resolver");
process.stdout.write(String(hasCompletionEvidence("run_tests", process.env.EV_SID, { repoDir: process.env.EV_REPO })));
' 2>/dev/null || echo "PROBE_FAIL"
}

SENTINEL='echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: staged set is human-facing docs only>>"'

# --- C1-1: real sentinel through the real hook, docs-only staged ---------------
# Normal case. Beyond "status == skipped" (sibling D3), the recorded audit payload
# is pinned: a declared skip must be distinguishable from an observed completion.
export CLAUDE_PROJECT_DIR="$REPO_DOCS_N"
at_run_tests c1
MARK_OUT="$(run_mark_hook c1 "$SENTINEL")"
check "C1-1 docs-only: run_tests recorded skipped" '"skipped"' "$(step_field c1 run_tests status)"
check "C1-1 docs-only: skip_reason persisted verbatim" \
  '"staged set is human-facing docs only"' "$(step_field c1 run_tests skip_reason)"
check "C1-1 docs-only: event carries declared/mark-step provenance" \
  '{"provenance":"declared","origin":"mark-step"}' "$(step_lastevent c1 run_tests)"
check_not_contains "C1-1 docs-only: hook emits no rejection message" "rejected" "$MARK_OUT"

# --- C1-2: classifier counterpart — code staged, sentinel must be refused ------
# The state file is compared byte-for-byte before/after. A handler that wrote
# first and validated second would still pass a status-only assertion because the
# status happens to be re-written to the same value elsewhere.
export CLAUDE_PROJECT_DIR="$REPO_CODE_N"
at_run_tests c2
STATE_BEFORE="$(raw_state c2)"
MARK_OUT="$(run_mark_hook c2 "$SENTINEL")"
STATE_AFTER="$(raw_state c2)"
check "C1-2 code staged: run_tests stays pending" '"pending"' "$(step_field c2 run_tests status)"
check "C1-2 code staged: state file byte-for-byte unchanged" "$STATE_BEFORE" "$STATE_AFTER"
check_contains "C1-2 code staged: hook explains the docs-only refusal" \
  "the staged set is not human-facing docs only" "$MARK_OUT"
check_contains "C1-2 code staged: refusal names the sentinel" "WORKFLOW_RUN_TESTS_NOT_NEEDED" "$MARK_OUT"
check "C1-2 code staged: no skip_reason written" 'null' "$(step_field c2 run_tests skip_reason)"

# --- C1-3: a recorded skip is NOT completion evidence -------------------------
# describeEvidence may explain the docs-only route, but hasCompletionEvidence must
# stay false even once the skip is on record — otherwise a skip would silently
# satisfy every evidence-driven consumer (reconcileEffectiveState, mark-step).
export CLAUDE_PROJECT_DIR="$REPO_DOCS_N"
check "C1-3 after a valid skip: hasCompletionEvidence(run_tests) still false" \
  "false" "$(evidence_run_tests c1 "$REPO_DOCS_N")"

# --- C1-4: the --advance door persists the same verdict -----------------------
# Sibling D5b asserts the stdout ADVANCED line only; the durable record is what
# every later consumer reads, so it is pinned here.
export CLAUDE_PROJECT_DIR="$REPO_DOCS_N"
at_run_tests c4
run_ns_in "$REPO_DOCS_N" --session c4 --advance --step run_tests --status skipped \
  --skip-reason "only human-facing docs are staged"
check "C1-4 advance: exit 0" "0" "$NS_RC"
check "C1-4 advance: run_tests persisted as skipped" '"skipped"' "$(step_field c4 run_tests status)"
check "C1-4 advance: skip_reason persisted" \
  '"only human-facing docs are staged"' "$(step_field c4 run_tests skip_reason)"
check "C1-4 advance: hasCompletionEvidence(run_tests) still false" \
  "false" "$(evidence_run_tests c4 "$REPO_DOCS_N")"

# --- C1-5: integration — staged set grows to code AFTER a legitimate skip ------
# H1 TOCTOU. The skip was proven docs-only when recorded; nothing demotes it in
# state, so the commit gate must re-verify the CURRENT staged set and block.
export CLAUDE_PROJECT_DIR="$REPO_MIX_N"
gate_ready c5
MARK_OUT="$(run_mark_hook c5 "$SENTINEL")"
check "C1-5 setup: skip legitimately recorded while docs-only" \
  '"skipped"' "$(step_field c5 run_tests status)"
# Baseline: still docs-only → the gate honors the skip (without this the block
# below could pass for any unrelated reason).
GATE_OUT="$(run_gate_commit c5 "$REPO_MIX_N")"
check_contains "C1-5a docs-only staged: commit gate approves" '"approve"' "$GATE_OUT"
check_not_contains "C1-5a docs-only staged: commit gate does not block" '"block"' "$GATE_OUT"

git -C "$REPO_MIX" add hooks/later.js >/dev/null 2>&1
GATE_OUT="$(run_gate_commit c5 "$REPO_MIX_N")"
check_contains "C1-5b code staged after skip: commit gate blocks" '"block"' "$GATE_OUT"
check_contains "C1-5b code staged after skip: block names run_tests" "run_tests" "$GATE_OUT"

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
