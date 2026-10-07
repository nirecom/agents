#!/usr/bin/env bash
# Tests: hooks/lib/sentinel-patterns.js, hooks/workflow-mark/not-needed-handlers.js, hooks/workflow-state/state-io/core.js, bin/workflow/lib/next-step/verdict.js, hooks/workflow-state/evidence-resolver.js, hooks/workflow-gate/staged-evidence.js, bin/workflow/next-step
# Tags: tl2, workflow, run-tests, docs-only, skip-sentinel, scope:issue-specific, pwsh-not-required, docs, evidence, write-code
# #1644 D1-D6: run_tests docs-only skip path; "safety net" cases fail on a half-landed skip.
# #2327 WCD-7: docs evidence excludes files staged by write_code (write_code_scope_manifest).
# TL3 gap: live permission auto-approval of the sentinel and SKILL.md RNT-5 emission —
# checked at WORKFLOW_USER_VERIFIED preflight (bin/check-verification-gate.sh skill-orchestration).

set -uo pipefail

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
nrm() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
AGENTS_DIR_N="$(nrm "$AGENTS_DIR")"
# Sourced before the local helpers so they (e.g. run_with_timeout without a seconds arg) win.
# shellcheck source=tests/lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"

NEXT_STEP_N="$AGENTS_DIR_N/bin/workflow/next-step"
WORKFLOW_MARK_N="$AGENTS_DIR_N/hooks/workflow-mark.js"
WFSTATE_MODULE="$AGENTS_DIR_N/hooks/workflow-state"
# Reused read-only probe (CPR-SSOT: one fixture-state reader for all #1644 tests).
PROBE_N="$AGENTS_DIR_N/tests/bin/feature-1644-advance-transaction/state-probe.js"
export WFSTATE_MODULE

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

WORKFLOW_DIR="$TMPDIR_BASE/wf"
PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_DIR" "$PLANS_DIR"
# Dual-pin (#1799): pinning only one of the pair lets supervisor-emit append to
# the developer's real ~/.workflow-plans/.
export WORKFLOW_STATE_DIR="$(nrm "$WORKFLOW_DIR")"
export WORKFLOW_PLANS_DIR="$(nrm "$PLANS_DIR")"
unset CLAUDE_CODE_SESSION_ID

CONFIG_EMPTY="$TMPDIR_BASE/cfg-empty"
mkdir -p "$CONFIG_EMPTY"
: > "$CONFIG_EMPTY/.env"
export AGENTS_CONFIG_DIR="$(nrm "$CONFIG_EMPTY")"

# Two fixture repos differing ONLY in what is staged — the docs-only predicate is
# the single variable under test, so nothing else may differ between them.
mk_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git init -q "$dir" >/dev/null 2>&1
  git -C "$dir" config core.hooksPath /dev/null
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "test"
}
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

STEPS_ALL="workflow_init clarify_intent research outline detail branching_complete write_tests review_tests write_code run_tests review_security docs user_verification cleanup pre_final_report_gate final_report"
# State whose first non-settled step is run_tests.
# #1665: write_code sits between review_tests and run_tests and is NOT skippable, so it has
# to be part of the settled prefix below — otherwise the first non-settled step is
# write_code and every case here would be probing the wrong step.
at_run_tests() {
  local sid="$1" json='{"steps":{' first=1 s st
  for s in $STEPS_ALL; do
    st="pending"
    case " workflow_init clarify_intent research outline detail branching_complete write_tests review_tests write_code " in
      *" $s "*) st="complete" ;;
    esac
    [ $first -eq 1 ] || json="$json,"
    first=0
    json="$json\"$s\":{\"status\":\"$st\"}"
  done
  json="$json},\"closes_issues\":[1644]}"
  printf '%s' "$json" > "$WORKFLOW_DIR/${sid}.json"
}

NS_OUT=""; NS_ERR=""; NS_RC=0
run_ns() {
  local errf="$TMPDIR_BASE/ns.err"
  NS_RC=0
  NS_OUT="$(run_with_timeout node "$NEXT_STEP_N" "$@" 2>"$errf")" || NS_RC=$?
  NS_ERR="$(cat "$errf" 2>/dev/null || echo "")"
}
# H2 hardening: the run_tests docs-only skip check (record-step-verdict.js
# resolveTrustedRepoDirForRunTestsSkip) resolves the repo via `git rev-parse
# --show-toplevel` from the real process cwd — it no longer trusts
# CLAUDE_PROJECT_DIR alone. Cases that exercise that specific predicate must
# run the CLI with its cwd actually inside the fixture repo.
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
    | run_with_timeout node "$WORKFLOW_MARK_N" >/dev/null 2>&1 || true
}
step_status() {
  PROBE_SID="$1" PROBE_STEP="$2" PROBE_FIELD="status" \
    run_with_timeout node "$PROBE_N" field 2>/dev/null || echo "PROBE_FAIL"
}
action_line_count() { printf '%s\n' "$NS_OUT" | grep -c '^ACTION=' || true; }

SENTINEL='echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: staged set is human-facing docs only>>"'

# --- D1: docs-only surfaces the skip hint -----------------------------------
# RED until verdict.js gains the run_tests branch in its skipHint block.
export CLAUDE_PROJECT_DIR="$REPO_DOCS_N"
at_run_tests d1
run_ns --session d1
check_contains "D1 docs-only: SKIP_HINT names the run_tests sentinel" \
  "SKIP_HINT=WORKFLOW_RUN_TESTS_NOT_NEEDED" "$NS_OUT"
check_contains "D1 docs-only: verdict still schedules run_tests" "REASON='run_tests'" "$NS_OUT"

# --- D2: non-docs-only must NOT surface it ----------------------------------
# SAFETY NET (green pre-implementation): the CPR-ORTH counterpart of D1. It is
# the case that fails if the hint is emitted unconditionally.
export CLAUDE_PROJECT_DIR="$REPO_CODE_N"
at_run_tests d2
run_ns --session d2
check_not_contains "D2 non-docs-only: no run_tests SKIP_HINT" \
  "SKIP_HINT=WORKFLOW_RUN_TESTS_NOT_NEEDED" "$NS_OUT"

# --- D3: the sentinel handler records the skip under docs-only --------------
# RED until not-needed-handlers.js gains the branch AND core.js SKIPPABLE_STEPS
# gains "run_tests" (the write is refused without it).
export CLAUDE_PROJECT_DIR="$REPO_DOCS_N"
at_run_tests d3
run_mark_hook d3 "$SENTINEL"
check "D3 docs-only: RUN_TESTS_NOT_NEEDED records run_tests as skipped" \
  '"skipped"' "$(step_status d3 run_tests)"

# --- D4: the handler refuses under non-docs-only ----------------------------
# The rejection must leave the state untouched — a handler that writes first and
# validates second would pass a message-only assertion.
export CLAUDE_PROJECT_DIR="$REPO_CODE_N"
at_run_tests d4
run_mark_hook d4 "$SENTINEL"
check "D4 non-docs-only: RUN_TESTS_NOT_NEEDED leaves run_tests pending" \
  '"pending"' "$(step_status d4 run_tests)"

# --- D5: --advance --status skipped is gated by the same predicate ----------
# CLAUDE_PROJECT_DIR is set to match the fixture but the check under test
# resolves the repo from the real process cwd (H2 hardening) — run_ns_in
# actually cd's the subprocess into REPO_CODE_N so the refusal is proven for
# the right reason (non-docs-only staged set), not merely a not-a-repo fallback.
export CLAUDE_PROJECT_DIR="$REPO_CODE_N"
at_run_tests d5
run_ns_in "$REPO_CODE_N" --session d5 --advance --step run_tests --status skipped --skip-reason "docs only"
check "D5 non-docs-only: --advance --status skipped exits 3" "3" "$NS_RC"
check "D5 non-docs-only: exit 3 emits no ACTION line" "0" "$(action_line_count)"
check "D5 non-docs-only: state unchanged" '"pending"' "$(step_status d5 run_tests)"

# D5b is the symmetric accept side: without it D5 passes trivially forever.
export CLAUDE_PROJECT_DIR="$REPO_DOCS_N"
at_run_tests d5b
run_ns_in "$REPO_DOCS_N" --session d5b --advance --step run_tests --status skipped --skip-reason "staged set is docs only"
check "D5b docs-only: --advance --status skipped exits 0" "0" "$NS_RC"
check_contains "D5b docs-only: ADVANCED line names run_tests skipped" \
  "ADVANCED=run_tests status=skipped" "$NS_OUT"

# --- D6: docs-only grants explicability, never completion authority ---------
# SAFETY NET (green pre-implementation): describeEvidence may learn to explain
# the docs-only route, but hasCompletionEvidence must stay false — a docs-only
# staged set is not evidence that the test suite ran.
export CLAUDE_PROJECT_DIR="$REPO_DOCS_N"
at_run_tests d6
EV_OUT="$(WFSTATE_MODULE="$WFSTATE_MODULE" REPO_D="$REPO_DOCS_N" run_with_timeout node -e '
const { hasCompletionEvidence } = require(process.env.WFSTATE_MODULE + "/evidence-resolver");
process.stdout.write(String(hasCompletionEvidence("run_tests", "d6", { repoDir: process.env.REPO_D })));
' 2>/dev/null)"
check "D6 docs-only: hasCompletionEvidence(run_tests) stays false" "false" "$EV_OUT"

# --- WCD-7: docs evidence excludes write_code-staged files (#2327 C1) -------
# The D-cases pin CLAUDE_PROJECT_DIR; WCD-7 passes repoDir explicitly instead.
unset CLAUDE_PROJECT_DIR

case_begin "evidence-resolver" "hooks/workflow-state/evidence-resolver.js"

# WCD-7 fixture: staged skills/SKILL.md; snapshot includes that file (it was impl work)
REPO_WCD="$TMPDIR_BASE/repo-wcd"
mk_repo "$REPO_WCD"
mkdir -p "$REPO_WCD/skills"
printf 'skill content\n' > "$REPO_WCD/skills/SKILL.md"
git -C "$REPO_WCD" add skills/SKILL.md >/dev/null 2>&1
SKILL_OID="$(git -C "$REPO_WCD" rev-parse :skills/SKILL.md 2>/dev/null || echo "unknown")"
REPO_WCD_N="$(nrm "$REPO_WCD")"

node -e "
const fs = require('fs'), path = require('path');
const steps = {};
for (const s of ['workflow_init','clarify_intent','research','outline','detail',
    'branching_complete','write_tests','review_tests','write_code']) {
  steps[s] = {status:'complete'};
}
steps.write_code.write_code_scope_manifest = {
  v:1, files:{'skills/SKILL.md':'$SKILL_OID'}
};
for (const s of ['run_tests','review_security','docs','review_docs',
    'user_verification','cleanup','pre_final_report_gate','final_report']) {
  steps[s] = {status:'pending'};
}
fs.writeFileSync(path.join(process.env.WORKFLOW_STATE_DIR, 'wcd7.json'),
  JSON.stringify({steps,closes_issues:[2327]}));
" 2>/dev/null

# WCD-7a: staged doc file in snapshot → excluded → evidence false
WCD7A_OUT="$(WFSTATE_MODULE="$WFSTATE_MODULE" REPO_WCD_N="$REPO_WCD_N" run_with_timeout node -e '
try {
  const { hasCompletionEvidence } = require(process.env.WFSTATE_MODULE + "/evidence-resolver");
  process.stdout.write(String(hasCompletionEvidence("docs", "wcd7", { repoDir: process.env.REPO_WCD_N })));
} catch(e) { process.stdout.write("ERROR:" + e.message); }
' 2>/dev/null)"
check "WCD-7a: staged doc in snapshot → excluded → evidence false" "false" "$WCD7A_OUT"

# WCD-7b: positive control — staged docs/x.md NOT in snapshot → evidence true
REPO_WCD2="$TMPDIR_BASE/repo-wcd2"
mk_repo "$REPO_WCD2"
mkdir -p "$REPO_WCD2/docs"
printf 'real doc\n' > "$REPO_WCD2/docs/x.md"
git -C "$REPO_WCD2" add docs/x.md >/dev/null 2>&1
REPO_WCD2_N="$(nrm "$REPO_WCD2")"

node -e "
const fs = require('fs'), path = require('path');
const steps = {};
for (const s of ['workflow_init','clarify_intent','research','outline','detail',
    'branching_complete','write_tests','review_tests','write_code']) {
  steps[s] = {status:'complete'};
}
steps.write_code.write_code_scope_manifest = {v:1, files:{'hooks/impl.js':'oid1'}};
for (const s of ['run_tests','review_security','docs','review_docs',
    'user_verification','cleanup','pre_final_report_gate','final_report']) {
  steps[s] = {status:'pending'};
}
fs.writeFileSync(path.join(process.env.WORKFLOW_STATE_DIR, 'wcd7b.json'),
  JSON.stringify({steps,closes_issues:[2327]}));
" 2>/dev/null

WCD7B_OUT="$(WFSTATE_MODULE="$WFSTATE_MODULE" REPO_WCD2_N="$REPO_WCD2_N" run_with_timeout node -e '
try {
  const { hasCompletionEvidence } = require(process.env.WFSTATE_MODULE + "/evidence-resolver");
  process.stdout.write(String(hasCompletionEvidence("docs", "wcd7b", { repoDir: process.env.REPO_WCD2_N })));
} catch(e) { process.stdout.write("ERROR:" + e.message); }
' 2>/dev/null)"
check "WCD-7b: staged doc NOT in snapshot → not excluded → evidence true" "true" "$WCD7B_OUT"

# WCD-7c: no snapshot → no exclusion → backward-compatible (evidence true)
REPO_WCD3="$TMPDIR_BASE/repo-wcd3"
mk_repo "$REPO_WCD3"
mkdir -p "$REPO_WCD3/docs"
printf 'real doc\n' > "$REPO_WCD3/docs/y.md"
git -C "$REPO_WCD3" add docs/y.md >/dev/null 2>&1
REPO_WCD3_N="$(nrm "$REPO_WCD3")"

node -e "
const fs = require('fs'), path = require('path');
const steps = {};
for (const s of ['workflow_init','clarify_intent','research','outline','detail',
    'branching_complete','write_tests','review_tests','write_code']) {
  steps[s] = {status:'complete'};
}
// No write_code_scope_manifest
for (const s of ['run_tests','review_security','docs','review_docs',
    'user_verification','cleanup','pre_final_report_gate','final_report']) {
  steps[s] = {status:'pending'};
}
fs.writeFileSync(path.join(process.env.WORKFLOW_STATE_DIR, 'wcd7c.json'),
  JSON.stringify({steps,closes_issues:[2327]}));
" 2>/dev/null

WCD7C_OUT="$(WFSTATE_MODULE="$WFSTATE_MODULE" REPO_WCD3_N="$REPO_WCD3_N" run_with_timeout node -e '
try {
  const { hasCompletionEvidence } = require(process.env.WFSTATE_MODULE + "/evidence-resolver");
  process.stdout.write(String(hasCompletionEvidence("docs", "wcd7c", { repoDir: process.env.REPO_WCD3_N })));
} catch(e) { process.stdout.write("ERROR:" + e.message); }
' 2>/dev/null)"
check "WCD-7c: no snapshot → no exclusion → backward-compat → evidence true" "true" "$WCD7C_OUT"

# WCD-7e: snapshot {v:1, unavailable:true} → fail-closed → evidence false
REPO_WCD4="$TMPDIR_BASE/repo-wcd4"
mk_repo "$REPO_WCD4"
mkdir -p "$REPO_WCD4/skills"
printf 'skill2\n' > "$REPO_WCD4/skills/X.md"
git -C "$REPO_WCD4" add skills/X.md >/dev/null 2>&1
REPO_WCD4_N="$(nrm "$REPO_WCD4")"

node -e "
const fs = require('fs'), path = require('path');
const steps = {};
for (const s of ['workflow_init','clarify_intent','research','outline','detail',
    'branching_complete','write_tests','review_tests','write_code']) {
  steps[s] = {status:'complete'};
}
steps.write_code.write_code_scope_manifest = {v:1, unavailable:true};
for (const s of ['run_tests','review_security','docs','review_docs',
    'user_verification','cleanup','pre_final_report_gate','final_report']) {
  steps[s] = {status:'pending'};
}
fs.writeFileSync(path.join(process.env.WORKFLOW_STATE_DIR, 'wcd7e.json'),
  JSON.stringify({steps,closes_issues:[2327]}));
" 2>/dev/null

WCD7E_OUT="$(WFSTATE_MODULE="$WFSTATE_MODULE" REPO_WCD4_N="$REPO_WCD4_N" run_with_timeout node -e '
try {
  const { hasCompletionEvidence } = require(process.env.WFSTATE_MODULE + "/evidence-resolver");
  process.stdout.write(String(hasCompletionEvidence("docs", "wcd7e", { repoDir: process.env.REPO_WCD4_N })));
} catch(e) { process.stdout.write("ERROR:" + e.message); }
' 2>/dev/null)"
check "WCD-7e: unavailable:true snapshot → fail-closed → evidence false" "false" "$WCD7E_OUT"

# WCD-7f: malformed snapshot JSON → fail-closed → evidence false
node -e "
const fs = require('fs'), path = require('path');
const steps = {};
for (const s of ['workflow_init','clarify_intent','research','outline','detail',
    'branching_complete','write_tests','review_tests','write_code']) {
  steps[s] = {status:'complete'};
}
steps.write_code.write_code_scope_manifest = 'not-valid-json{{{';
for (const s of ['run_tests','review_security','docs','review_docs',
    'user_verification','cleanup','pre_final_report_gate','final_report']) {
  steps[s] = {status:'pending'};
}
fs.writeFileSync(path.join(process.env.WORKFLOW_STATE_DIR, 'wcd7f.json'),
  JSON.stringify({steps,closes_issues:[2327]}));
" 2>/dev/null

WCD7F_OUT="$(WFSTATE_MODULE="$WFSTATE_MODULE" REPO_WCD4_N="$REPO_WCD4_N" run_with_timeout node -e '
try {
  const { hasCompletionEvidence } = require(process.env.WFSTATE_MODULE + "/evidence-resolver");
  process.stdout.write(String(hasCompletionEvidence("docs", "wcd7f", { repoDir: process.env.REPO_WCD4_N })));
} catch(e) { process.stdout.write("ERROR:" + e.message); }
' 2>/dev/null)"
check "WCD-7f: malformed snapshot JSON → fail-closed → evidence false" "false" "$WCD7F_OUT"

case_end

case_begin "staged-evidence" "hooks/workflow-gate/staged-evidence.js"

# WCD-7d: hasStagedDocChanges(repoDir) without 2nd arg still works
WCD7D_OUT="$(WFSTATE_MODULE="$WFSTATE_MODULE" REPO_WCD2_N="$REPO_WCD2_N" run_with_timeout node -e '
try {
  const { hasStagedDocChanges } = require(process.env.WFSTATE_MODULE + "/../workflow-gate/staged-evidence");
  process.stdout.write(String(hasStagedDocChanges(process.env.REPO_WCD2_N)));
} catch(e) { process.stdout.write("ERROR:" + e.message); }
' 2>/dev/null)"
check "WCD-7d: hasStagedDocChanges(repoDir) without opts arg unchanged (true for docs repo)" "true" "$WCD7D_OUT"

# WCD-7g: hasStagedDocChanges with writeCodeSnapshot excludes matched file
WCD7G_OUT="$(WFSTATE_MODULE="$WFSTATE_MODULE" REPO_WCD_N="$REPO_WCD_N" SKILL_OID="$SKILL_OID" run_with_timeout node -e '
try {
  const { hasStagedDocChanges } = require(process.env.WFSTATE_MODULE + "/../workflow-gate/staged-evidence");
  const snapshot = {v:1, files:{"skills/SKILL.md": process.env.SKILL_OID}};
  const r = hasStagedDocChanges(process.env.REPO_WCD_N, {writeCodeSnapshot: snapshot});
  process.stdout.write(String(r));
} catch(e) { process.stdout.write("ERROR:" + e.message); }
' 2>/dev/null)"
check "WCD-7g: hasStagedDocChanges with snapshot excludes matched file → false" "false" "$WCD7G_OUT"

# WCD-7h: hasStagedDocChanges with snapshot excludes impl file but real doc still triggers
REPO_WCD5="$TMPDIR_BASE/repo-wcd5"
mk_repo "$REPO_WCD5"
mkdir -p "$REPO_WCD5/docs" "$REPO_WCD5/skills"
printf 'real\n' > "$REPO_WCD5/docs/z.md"
printf 'impl\n' > "$REPO_WCD5/skills/S.md"
git -C "$REPO_WCD5" add docs/z.md skills/S.md >/dev/null 2>&1
S_OID="$(git -C "$REPO_WCD5" rev-parse :skills/S.md 2>/dev/null || echo "unknown")"
REPO_WCD5_N="$(nrm "$REPO_WCD5")"

WCD7H_OUT="$(WFSTATE_MODULE="$WFSTATE_MODULE" REPO_WCD5_N="$REPO_WCD5_N" S_OID="$S_OID" run_with_timeout node -e '
try {
  const { hasStagedDocChanges } = require(process.env.WFSTATE_MODULE + "/../workflow-gate/staged-evidence");
  const snapshot = {v:1, files:{"skills/S.md": process.env.S_OID}};
  const r = hasStagedDocChanges(process.env.REPO_WCD5_N, {writeCodeSnapshot: snapshot});
  process.stdout.write(String(r));
} catch(e) { process.stdout.write("ERROR:" + e.message); }
' 2>/dev/null)"
check "WCD-7h: snapshot excludes S.md but docs/z.md still triggers → true" "true" "$WCD7H_OUT"

case_end

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
