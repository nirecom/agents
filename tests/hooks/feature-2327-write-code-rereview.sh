#!/usr/bin/env bash
# Tests: hooks/workflow-state/review-tests-reopen.js, hooks/workflow-state/record-step-verdict.js, hooks/workflow-mark/mark-step-handler.js, bin/workflow/lib/next-step/advance-shared.js, bin/workflow/lib/next-step/state-ops.js, hooks/workflow-state/state-io/review-tests.js
# Tags: tl2, workflow, write-code, review-tests, rereview, reopen, scope:issue-specific, pwsh-not-required
#
# #2327 stage 3: write_code complete → review_tests reopen.
# Covers: 3 entry points (sentinel / --advance / --mark); no-reopen cases;
# fail-closed (unavailable/missing); C2 trust boundary; next-step behavior
# after reopen; idempotency; negative control; reopen failure diagnostic.

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not available";  exit 77; }

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
np() { cygpath -m "$1" 2>/dev/null || printf '%s\n' "$1"; }
SCRIPT_CHECKOUT_ROOT_N="$(np "$SCRIPT_CHECKOUT_ROOT")"
NEXT_STEP_N="$SCRIPT_CHECKOUT_ROOT_N/bin/workflow/next-step"
WORKFLOW_MARK_N="$SCRIPT_CHECKOUT_ROOT_N/hooks/workflow-mark.js"
WFSTATE_MODULE="$SCRIPT_CHECKOUT_ROOT_N/hooks/workflow-state"; export WFSTATE_MODULE

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT
WORKFLOW_DIR="$TMPDIR_BASE/wf"
PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_DIR" "$PLANS_DIR"
export WORKFLOW_STATE_DIR="$(np "$WORKFLOW_DIR")"
export WORKFLOW_PLANS_DIR="$(np "$PLANS_DIR")"
unset CLAUDE_CODE_SESSION_ID

CONFIG_EMPTY="$TMPDIR_BASE/cfg"
mkdir -p "$CONFIG_EMPTY"
: > "$CONFIG_EMPTY/.env"
export AGENTS_MAIN_ROOT="$(np "$CONFIG_EMPTY")"

export NEXT_STEP_N WORKFLOW_MARK_N SCRIPT_CHECKOUT_ROOT_N TMPDIR_BASE

# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 -- expected [$2] got [$3]"; fi; }
check_contains() { if printf '%s' "$3" | grep -qF -- "$2"; then pass "$1"; else fail "$1 -- expected [$2] in: $3"; fi; }
check_not_contains() { if printf '%s' "$3" | grep -qF -- "$2"; then fail "$1 -- did NOT expect [$2] in: $3"; else pass "$1"; fi; }
check_nonzero() { if [ "$2" -ne 0 ]; then pass "$1"; else fail "$1 -- expected nonzero exit, got 0"; fi; }
run_with_timeout() { if command -v timeout >/dev/null 2>&1; then timeout 60 "$@"; else perl -e 'alarm 60; exec @ARGV' -- "$@"; fi; }
export -f pass fail check check_contains check_not_contains check_nonzero run_with_timeout

# --- shared fixtures (p1-p6) ---
# Freshness answers no-tests (fresh) whenever 0 test files are staged, so every
# fixture meant to reopen stages tests/x.sh. A standalone `git init` repo is a
# main worktree, which the advance entry replaces with the session worktree —
# fixtures that must be read from their own cwd are linked worktrees.

# rr_repo <dir>: git repo with one seed commit and hooks disabled.
rr_repo() {
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" config user.email t@test.com
  git -C "$1" config user.name T
  git -C "$1" config core.hooksPath /dev/null
  printf 'seed\n' > "$1/README.md"
  git -C "$1" add README.md
  git -C "$1" commit -qm init
} >/dev/null 2>&1

# rr_linked <main> <linked> <branch>: linked worktree of <main>.
rr_linked() { git -C "$1" worktree add -q -b "$3" "$2" >/dev/null 2>&1; }

# rr_stage <repo> <relpath> <content>
rr_stage() {
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add -- "$2" >/dev/null 2>&1
}

# rr_oid <repo> <relpath>: staged blob oid.
rr_oid() { git -C "$1" rev-parse ":$2" 2>/dev/null; }

# rr_state <sid> <review_tests-json> [write_code-json] [session_worktree]
# Legacy v1 seed; steps before review_tests complete, after write_code pending.
rr_state() {
  node -e '
const fs = require("fs"), path = require("path");
const [sid, rt, wc, wt] = process.argv.slice(1);
const steps = {};
for(const s of ["workflow_init","clarify_intent","research","outline","detail","branching_complete","write_tests"]) steps[s] = {status:"complete"};
steps.review_tests = JSON.parse(rt);
steps.write_code = wc ? JSON.parse(wc) : {status:"pending"};
for(const s of ["run_tests","review_security","docs","review_docs","user_verification","cleanup","pre_final_report_gate","final_report"]) steps[s] = {status:"pending"};
const st = {version:1, session_id:sid, steps, closes_issues:[2327]};
if(wt) st.session_worktree = wt;
fs.writeFileSync(path.join(process.env.WORKFLOW_STATE_DIR, sid + ".json"), JSON.stringify(st));
' "$1" "$2" "${3:-}" "${4:-}"
}

# rr_view <sid>: projected write_code / review_tests fields as one JSON line.
rr_view() {
  node -e '
try {
  const s = require(process.argv[1] + "/hooks/workflow-state").readState(process.argv[2]);
  const st = (s && s.steps) || {};
  const wc = st.write_code || {}, rt = st.review_tests || {};
  process.stdout.write(JSON.stringify({
    wc_status: wc.status || null,
    wc_manifest: wc.write_code_scope_manifest === undefined ? null : wc.write_code_scope_manifest,
    rt_status: rt.status || null,
    rt_reopen: rt.reopen_reason || null,
    rt_manifest: rt.review_scope_manifest ? "kept" : "gone",
    run_tests: (st.run_tests || {}).status || null
  }));
}
catch (e) { process.stdout.write("VIEW_ERROR:" + e.message); }
' "$SCRIPT_CHECKOUT_ROOT_N" "$1" 2>/dev/null
}

# rr_notice <kind> <detail>: formatReviewTestsReopenNotice output, or a marker
# that no real output contains (so check_contains fails pre-implementation).
rr_notice() {
  node -e '
try {
  const m = require(process.argv[1] + "/hooks/workflow-state/review-tests-reopen.js");
  const n = m.formatReviewTestsReopenNotice({kind: process.argv[2], detail: process.argv[3]});
  process.stdout.write(typeof n === "string" && n ? n : "NOTICE_EMPTY");
}
catch (e) { process.stdout.write("NOTICE_UNAVAILABLE"); }
' "$SCRIPT_CHECKOUT_ROOT_N" "$1" "$2" 2>/dev/null
}

SCRIPT_DIR="$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-2327-write-code-rereview"

case_begin "state-io-rereview" "hooks/workflow-state/state-io/review-tests.js"
# shellcheck source=./feature-2327-write-code-rereview/p1-state-io.sh
. "$SCRIPT_DIR/p1-state-io.sh"
case_end

case_begin "reopen-module" "hooks/workflow-state/review-tests-reopen.js"
# shellcheck source=./feature-2327-write-code-rereview/p2-reopen.sh
. "$SCRIPT_DIR/p2-reopen.sh"
case_end

case_begin "sentinel-entry" "hooks/workflow-mark/mark-step-handler.js"
# shellcheck source=./feature-2327-write-code-rereview/p3-sentinel.sh
. "$SCRIPT_DIR/p3-sentinel.sh"
case_end

case_begin "advance-entry" "bin/workflow/lib/next-step/advance-shared.js"
# shellcheck source=./feature-2327-write-code-rereview/p4-advance.sh
. "$SCRIPT_DIR/p4-advance.sh"
case_end

case_begin "mark-entry" "bin/workflow/lib/next-step/state-ops.js"
# shellcheck source=./feature-2327-write-code-rereview/p5-mark.sh
. "$SCRIPT_DIR/p5-mark.sh"
case_end

case_begin "verdict-and-edge" "hooks/workflow-state/record-step-verdict.js"
# shellcheck source=./feature-2327-write-code-rereview/p6-verdict.sh
. "$SCRIPT_DIR/p6-verdict.sh"
case_end

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
