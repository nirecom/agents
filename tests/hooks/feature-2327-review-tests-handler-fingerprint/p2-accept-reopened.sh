#!/usr/bin/env bash
# Tests: hooks/workflow-mark/review-tests-handler.js, hooks/workflow-state/state-io/review-tests.js
# Tags: tl2, workflow, write-code, review-tests, rereview, reopen, warnings-accepted, scope:issue-specific, pwsh-not-required

# #2482: WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED on a write_code-reopened review_tests
# restores complete with the CURRENT staged manifest; an uncomputable manifest is fail-closed.
# Sourced by feature-2327-review-tests-handler-fingerprint.sh (harness, TMPDIR, counters live there).

# TL3 gap (what this test does NOT catch):
# - a real claude -p session firing the PostToolUse hook for the ACCEPTED sentinel
# - next-step driven by live session-state resolution (no --session flag)
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

AGENTS_DIR_N="$(np "$AGENTS_DIR")"
NEXT_STEP_N="$AGENTS_DIR_N/bin/workflow/next-step"
WFMARK_N="$AGENTS_DIR_N/hooks/workflow-mark.js"
WFSTATE_N="$AGENTS_DIR_N/hooks/workflow-state"
EVIDENCE_N="$AGENTS_DIR_N/hooks/workflow-gate/review-tests-evidence.js"

export WORKFLOW_STATE_DIR="$(np "$WORKFLOW_STATE_DIR")"
export WORKFLOW_PLANS_DIR="$(np "$WORKFLOW_PLANS_DIR")"
unset CLAUDE_PROJECT_DIR
mkdir -p "$TMPDIR_BASE/cfg" "$TMPDIR_BASE/neutral" "$TMPDIR_BASE/p2-nogit"
: > "$TMPDIR_BASE/cfg/.env"
export AGENTS_CONFIG_DIR="$(np "$TMPDIR_BASE/cfg")"
NEUTRAL_N="$(np "$TMPDIR_BASE/neutral")"
P2_NOGIT_N="$(np "$TMPDIR_BASE/p2-nogit")"
export AGENTS_DIR_N WFMARK_N WFSTATE_N EVIDENCE_N NEUTRAL_N

check() { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1" "expected [$2] got [$3]"; fi; }
check_contains() { if printf '%s' "$3" | grep -qF -- "$2"; then pass "$1"; else fail "$1" "expected [$2] in: $3"; fi; }
check_not_contains() { if printf '%s' "$3" | grep -qF -- "$2"; then fail "$1" "did NOT expect [$2] in: $3"; else pass "$1"; fi; }

# Freshness answers no-tests (fresh) when 0 test files are staged, so every
# fixture stages tests/x.sh plus hooks/impl.js.

rr_repo() {
  harness_git_init "$1"
  git -C "$1" config user.email t@test.com
  git -C "$1" config user.name T
  printf 'seed\n' > "$1/README.md"
  git -C "$1" add README.md
  git -C "$1" commit -qm init
} >/dev/null 2>&1
rr_linked() { git -C "$1" worktree add -q -b "$3" "$2" >/dev/null 2>&1; }
rr_stage() {
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add -- "$2" >/dev/null 2>&1
}
rr_oid() { git -C "$1" rev-parse ":$2" 2>/dev/null; }

IFS= read -r -d '' SEED_JS <<'JS'
const fs = require("fs"), path = require("path");
const [sid, rt, wcStatus, wt] = process.argv.slice(1);
const steps = {};
for (const s of ["workflow_init","clarify_intent","research","outline","detail","branching_complete","write_tests"]) steps[s] = {status:"complete"};
steps.review_tests = JSON.parse(rt);
steps.write_code = {status: wcStatus || "pending"};
for (const s of ["run_tests","review_security","docs","review_docs","user_verification","cleanup","pre_final_report_gate","final_report"]) steps[s] = {status:"pending"};
const st = {version:1, session_id:sid, steps, closes_issues:[2482]};
if (wt) st.session_worktree = wt;
fs.writeFileSync(path.join(process.env.WORKFLOW_STATE_DIR, sid + ".json"), JSON.stringify(st));
JS

IFS= read -r -d '' SEND_JS <<'JS'
const { spawnSync } = require("child_process");
const payload = JSON.stringify({ session_id: process.env.SID, tool_name: "Bash", tool_input: { command: process.env.CMD }, cwd: process.env.CWDP });
const env = Object.assign({}, process.env);
delete env.CLAUDE_PROJECT_DIR;
const r = spawnSync("node", [process.env.WFMARK_N], { input: payload, encoding: "utf8", timeout: 30000, env, cwd: process.env.NEUTRAL_N });
process.stdout.write((r.stdout || "") + (r.stderr || ""));
JS

IFS= read -r -d '' SV_JS <<'JS'
try {
  const s = require(process.env.WFSTATE_N).readState(process.argv[1]);
  const rt = ((s && s.steps) || {}).review_tests || {};
  const files = (rt.review_scope_manifest && rt.review_scope_manifest.files) || {};
  const v = {
    status: rt.status || "none",
    reopen: rt.reopen_reason || "none",
    summary: rt.warnings_summary ? "present" : "gone",
    reason: rt.warnings_accepted_reason || "none",
    manifest: rt.review_scope_manifest ? "present" : "absent",
    impl: files["hooks/impl.js"] || "none",
    tests: files["tests/x.sh"] || "none"
  };
  process.stdout.write(String(v[process.argv[2]]));
} catch (e) { process.stdout.write("VIEW_ERROR:" + e.message); }
JS

IFS= read -r -d '' FRESH_JS <<'JS'
try {
  const ev = require(process.env.EVIDENCE_N);
  const s = require(process.env.WFSTATE_N).readState(process.argv[1]);
  const f = ev.evaluateReviewScopeFreshness(s.steps.review_tests, ev.computeReviewScopeFingerprint(process.argv[2]));
  process.stdout.write(f.fresh + ":" + f.reason);
} catch (e) { process.stdout.write("FRESH_ERROR:" + e.message); }
JS

seed_state() { run_with_timeout 60 node -e "$SEED_JS" "$1" "$2" "${3:-pending}" "${4:-}"; }
send_cmd() { SID="$1" CWDP="$2" CMD="$3" run_with_timeout 60 node -e "$SEND_JS"; }
sv() { run_with_timeout 60 node -e "$SV_JS" "$1" "$2"; }
fresh() { run_with_timeout 60 node -e "$FRESH_JS" "$1" "$2"; }
accept_cmd() { printf 'echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: %s>>"' "$1"; }
WC_CMD='echo "<<WORKFLOW_MARK_STEP_write_code_complete>>"'
REASON="user accepts remaining gaps"
OLD_MANIFEST='{"v":1,"files":{"tests/x.sh":"oldoid"}}'

# make_repo <dir>: repo with tests/x.sh and hooks/impl.js staged; sets TESTS_OID IMPL_OID.
make_repo() {
  rr_repo "$1"
  rr_stage "$1" tests/x.sh "echo x"
  rr_stage "$1" hooks/impl.js "impl"
  TESTS_OID="$(rr_oid "$1" tests/x.sh)"
  IMPL_OID="$(rr_oid "$1" hooks/impl.js)"
}
manifest_json() { printf '{"v":1,"files":{"tests/x.sh":"%s"}}' "$1"; }
# reopen_via_sentinel <sid> <repo> <extra-rt-fields>: complete + tests-only manifest,
# then the real write_code completion sentinel reopens review_tests.
reopen_via_sentinel() {
  make_repo "$2"
  seed_state "$1" "{\"status\":\"complete\",\"review_scope_manifest\":$(manifest_json "$TESTS_OID")$3}" pending
  send_cmd "$1" "$(np "$2")" "$WC_CMD" >/dev/null
}

case_begin "accepted-restores-complete-after-reopen" "hooks/workflow-mark/review-tests-handler.js"
R1="$TMPDIR_BASE/r1"; R1_N="$(np "$R1")"
reopen_via_sentinel ar1sid "$R1" ',"warnings_summary":"warnings=2"'
check "AR1-pre: write_code completion reopened review_tests" "pending" "$(sv ar1sid status)"
check "AR1-pre: reopen_reason is write-code-stale" "write-code-stale" "$(sv ar1sid reopen)"
check "AR1b-pre: freshness is stale right after the reopen" "false:stale" "$(fresh ar1sid "$R1_N")"
AR1_OUT="$(send_cmd ar1sid "$R1_N" "$(accept_cmd "$REASON")")"
check "AR1: status restored to complete" "complete" "$(sv ar1sid status)"
check "AR1: reopen_reason cleared" "none" "$(sv ar1sid reopen)"
check "AR1: manifest present" "present" "$(sv ar1sid manifest)"
check_contains "AR1: output says restored to complete" "restored to complete" "$AR1_OUT"
check "AR1b: manifest records the current impl oid" "$IMPL_OID" "$(sv ar1sid impl)"
check "AR1b-post: freshness is fresh after accept" "true:match" "$(fresh ar1sid "$R1_N")"
check "AR3: acceptance reason stored as warnings_accepted_reason" "$REASON" "$(sv ar1sid reason)"
check "AR1: warnings_summary cleared" "gone" "$(sv ar1sid summary)"
AR2_OUT="$(cd "$R1_N" && CLAUDE_PROJECT_DIR="$R1_N" run_with_timeout 60 node "$NEXT_STEP_N" --session ar1sid 2>/dev/null)"
check_contains "AR2: next-step returns an ACTION" "ACTION=" "$AR2_OUT"
check_not_contains "AR2: next skill is no longer review-tests" "NEXT_SKILL=review-tests" "$AR2_OUT"
case_end

case_begin "accepted-idempotent-second-send" "hooks/workflow-mark/review-tests-handler.js"
AR1B_OUT="$(send_cmd ar1sid "$R1_N" "$(accept_cmd "$REASON")")"
check "IDEM: status stays complete" "complete" "$(sv ar1sid status)"
check "IDEM: manifest still present" "present" "$(sv ar1sid manifest)"
check_not_contains "IDEM: no write failure reported" "failed to write state" "$AR1B_OUT"
case_end

case_begin "accepted-restores-without-warnings-summary" "hooks/workflow-state/state-io/review-tests.js"
R4="$TMPDIR_BASE/r4"; R4_N="$(np "$R4")"
reopen_via_sentinel ar4sid "$R4" ''
check "AR4-pre: reopened without any warnings_summary" "pending:write-code-stale:gone" "$(sv ar4sid status):$(sv ar4sid reopen):$(sv ar4sid summary)"
send_cmd ar4sid "$R4_N" "$(accept_cmd "$REASON")" >/dev/null
check "AR4: recovers to complete (old early return removed)" "complete" "$(sv ar4sid status)"
check "AR4: reopen_reason cleared" "none" "$(sv ar4sid reopen)"
check "AR4: manifest is current" "$IMPL_OID" "$(sv ar4sid impl)"
check "AR4: freshness is fresh after accept" "true:match" "$(fresh ar4sid "$R4_N")"
AR2B_OUT="$(cd "$R4_N" && CLAUDE_PROJECT_DIR="$R4_N" run_with_timeout 60 node "$NEXT_STEP_N" --session ar4sid 2>/dev/null)"
check_contains "AR2b: next-step returns an ACTION" "ACTION=" "$AR2B_OUT"
check_not_contains "AR2b: next skill is no longer review-tests" "NEXT_SKILL=review-tests" "$AR2B_OUT"
case_end

case_begin "accepted-clears-warnings-summary-on-reopen" "hooks/workflow-state/state-io/review-tests.js"
R5="$TMPDIR_BASE/r5"; R5_N="$(np "$R5")"
make_repo "$R5"
seed_state ar5sid "{\"status\":\"pending\",\"reopen_reason\":\"write-code-stale\",\"warnings_summary\":\"warnings=1\",\"review_scope_manifest\":$(manifest_json "$TESTS_OID")}" complete
check "AR5-pre: seeded reopened state carries warnings_summary" "pending:present" "$(sv ar5sid status):$(sv ar5sid summary)"
send_cmd ar5sid "$R5_N" "$(accept_cmd "$REASON")" >/dev/null
check "AR5: recovers to complete" "complete" "$(sv ar5sid status)"
check "AR5: warnings_summary is gone" "gone" "$(sv ar5sid summary)"
case_end

case_begin "never-reviewed-pending-is-not-promoted" "hooks/workflow-mark/review-tests-handler.js"
R6="$TMPDIR_BASE/r6"; R6_N="$(np "$R6")"
make_repo "$R6"
seed_state ar6sid '{"status":"pending"}' complete
AR6_OUT="$(send_cmd ar6sid "$R6_N" "$(accept_cmd "$REASON")")"
check "AR6: stays pending" "pending" "$(sv ar6sid status)"
check "AR6: manifest still absent" "absent" "$(sv ar6sid manifest)"
check_contains "AR6: output says nothing to accept" "nothing to accept" "$AR6_OUT"
case_end

case_begin "manifest-unavailable-is-fail-closed" "hooks/workflow-mark/review-tests-handler.js"
seed_state ar7sid "{\"status\":\"pending\",\"reopen_reason\":\"write-code-stale\",\"warnings_summary\":\"warnings=1\",\"review_scope_manifest\":$OLD_MANIFEST}" complete
AR7_OUT="$(send_cmd ar7sid "$P2_NOGIT_N" "$(accept_cmd "$REASON")")"
check "AR7: warnings_summary untouched" "present" "$(sv ar7sid summary)"
check "AR7: stays pending" "pending" "$(sv ar7sid status)"
check "AR7: reopen_reason kept" "write-code-stale" "$(sv ar7sid reopen)"
check "AR7: old manifest untouched" "oldoid" "$(sv ar7sid tests)"
check_contains "AR7: output says manifest unavailable" "manifest unavailable" "$AR7_OUT"
case_end

case_begin "metachar-reason-rejected-state-unchanged" "hooks/workflow-mark/review-tests-handler.js"
R8="$TMPDIR_BASE/r8"; R8_N="$(np "$R8")"
make_repo "$R8"
seed_state ar8sid "{\"status\":\"pending\",\"reopen_reason\":\"write-code-stale\",\"review_scope_manifest\":$OLD_MANIFEST}" complete
AR8_OUT="$(send_cmd ar8sid "$R8_N" "$(accept_cmd "accept (see notes)")")"
check_contains "AR8: advisory explains forbidden characters" "must not contain" "$AR8_OUT"
for AR8_BAD in "accept; rm" "accept | tee" "accept & more"; do
  check_contains "AR8: advisory for [$AR8_BAD]" "must not contain" "$(send_cmd ar8sid "$R8_N" "$(accept_cmd "$AR8_BAD")")"
done
check "AR8: still pending" "pending" "$(sv ar8sid status)"
check "AR8: reopen_reason kept" "write-code-stale" "$(sv ar8sid reopen)"
check "AR8: manifest untouched" "oldoid" "$(sv ar8sid tests)"
case_end

case_begin "warnings-cleared-regression-when-not-reopened" "hooks/workflow-state/state-io/review-tests.js"
R9="$TMPDIR_BASE/r9"; R9_N="$(np "$R9")"
make_repo "$R9"
seed_state ar9sid "{\"status\":\"complete\",\"warnings_summary\":\"warnings=3\",\"review_scope_manifest\":$(manifest_json "$TESTS_OID")}" complete
AR9_OUT="$(send_cmd ar9sid "$R9_N" "$(accept_cmd "$REASON")")"
check "AR9: warnings_summary cleared" "gone" "$(sv ar9sid summary)"
check "AR9: status still complete" "complete" "$(sv ar9sid status)"
check "AR9: reopen_reason stays none" "none" "$(sv ar9sid reopen)"
check_contains "AR9: output says warnings cleared" "warnings cleared" "$AR9_OUT"
case_end

# recover_case <sid> <reason> <manifest-json-or-empty>: seeded reopened state, then ACCEPTED.
recover_case() {
  local repo="$TMPDIR_BASE/$1-repo" rt="{\"status\":\"pending\",\"reopen_reason\":\"$2\""
  make_repo "$repo"
  [ -n "$3" ] && rt="$rt,\"review_scope_manifest\":$3"
  seed_state "$1" "$rt}" complete
  check "$1-pre: seeded pending with $2" "pending:$2" "$(sv "$1" status):$(sv "$1" reopen)"
  send_cmd "$1" "$(np "$repo")" "$(accept_cmd "$REASON")" >/dev/null
}

case_begin "recovers-for-write-code-missing-without-manifest" "hooks/workflow-state/state-io/review-tests.js"
recover_case armsid write-code-missing ""
check "ARM: status restored to complete" "complete" "$(sv armsid status)"
check "ARM: reopen_reason cleared" "none" "$(sv armsid reopen)"
check "ARM: manifest holds the current impl oid" "$IMPL_OID" "$(sv armsid impl)"
check "ARM: freshness is fresh" "true:match" "$(fresh armsid "$(np "$TMPDIR_BASE/armsid-repo")")"
case_end

case_begin "recovers-for-write-code-unavailable-with-old-manifest" "hooks/workflow-state/state-io/review-tests.js"
recover_case aru2sid write-code-unavailable "$OLD_MANIFEST"
check "ARU: status restored to complete" "complete" "$(sv aru2sid status)"
check "ARU: reopen_reason cleared" "none" "$(sv aru2sid reopen)"
check "ARU: manifest holds the current impl oid" "$IMPL_OID" "$(sv aru2sid impl)"
check "ARU: freshness is fresh" "true:match" "$(fresh aru2sid "$(np "$TMPDIR_BASE/aru2sid-repo")")"
case_end

case_begin "manifest-alone-without-reopen-reason-is-not-promoted" "hooks/workflow-mark/review-tests-handler.js"
R11="$TMPDIR_BASE/r11"
make_repo "$R11"
seed_state ar11sid "{\"status\":\"pending\",\"review_scope_manifest\":$OLD_MANIFEST}" complete
AR11_OUT="$(send_cmd ar11sid "$(np "$R11")" "$(accept_cmd "$REASON")")"
check "AR11: stays pending" "pending" "$(sv ar11sid status)"
check "AR11: manifest still old" "oldoid" "$(sv ar11sid tests)"
check_contains "AR11: output says nothing to accept" "nothing to accept" "$AR11_OUT"
case_end

case_begin "unknown-reopen-reason-is-not-promoted" "hooks/workflow-mark/review-tests-handler.js"
R12="$TMPDIR_BASE/r12"
make_repo "$R12"
seed_state ar12sid "{\"status\":\"pending\",\"reopen_reason\":\"something-else\",\"review_scope_manifest\":$OLD_MANIFEST}" complete
send_cmd ar12sid "$(np "$R12")" "$(accept_cmd "$REASON")" >/dev/null
check "AR12: stays pending" "pending" "$(sv ar12sid status)"
check "AR12: unknown reopen_reason kept" "something-else" "$(sv ar12sid reopen)"
check "AR12: manifest still old" "oldoid" "$(sv ar12sid tests)"
case_end

case_begin "linked-worktree-scope-is-recorded" "hooks/workflow-mark/review-tests-handler.js"
R10="$TMPDIR_BASE/r10-main"; L10="$TMPDIR_BASE/r10-linked"
rr_repo "$R10"
rr_linked "$R10" "$L10" feature/r10
rr_stage "$L10" tests/x.sh "echo x"
rr_stage "$L10" hooks/impl.js "impl"
L10_IMPL="$(rr_oid "$L10" hooks/impl.js)"
L10_N="$(np "$L10")"
seed_state ar10sid "{\"status\":\"pending\",\"reopen_reason\":\"write-code-stale\",\"review_scope_manifest\":$OLD_MANIFEST}" complete "$L10_N"
send_cmd ar10sid "$(np "$R10")" "$(accept_cmd "$REASON")" >/dev/null
check "AR10: status restored to complete" "complete" "$(sv ar10sid status)"
check "AR10: manifest holds the linked worktree impl oid" "$L10_IMPL" "$(sv ar10sid impl)"
check "AR10: fresh against the linked worktree" "true:match" "$(fresh ar10sid "$L10_N")"
case_end
