#!/usr/bin/env bash
# tests/hooks/stdin-read-failure-policy.sh
# Tests: hooks/block-dotenv.js, hooks/bash-guard.js, hooks/enforce-system-ops.js, hooks/scan-outbound.js, bin/scan-offensive, hooks/preuse-auto-approve.js, hooks/rtk-rewrite.js, hooks/workflow-mark.js, hooks/supervisor-guard.js, hooks/stop-premature-stop-guard.js, hooks/show-plan-link.js, hooks/workflow-gate.js, hooks/enforce-worktree.js, hooks/block-credentials.js, hooks/block-shell-config.js, hooks/block-history-direct.js, hooks/block-memory-direct.js, hooks/block-tests-direct.js, hooks/block-subagent-sentinels.js, hooks/auto-branch-guard.js, hooks/enforce-issue-close.js, hooks/block-clearance-token-write.js
# Tags: TL1, hook, stdin, read-stdin, read-error, ebadf, fault-injection, fail-close, fail-open, scope:common, pwsh-not-required
# Stdin read-failure policy (#1810 S11). fd 0 is opened write-only, so every
# read of it fails with EBADF. Security hooks must fail closed with the shared
# readFailureReason text; fail-open hooks pass through with their declared
# stderr (exactly one diagnostic line, or none for passthrough / display hooks).

set -uo pipefail
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }

TMPD="$(make_tmp)"
trap 'cd /; rm -rf "$TMPD"' EXIT
harness_isolate "$TMPD"
export CLAUDE_WORKFLOW_DIR="$(np "$CLAUDE_WORKFLOW_DIR")"
export WORKFLOW_PLANS_DIR="$(np "$WORKFLOW_PLANS_DIR")"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE SYSTEM_OPS_APPROVED 2>/dev/null || true
unset ANTHROPIC_API_KEY ENFORCE_WORKTREE ENFORCE_WORKTREE_EXCLUDE 2>/dev/null || true
mkdir -p "$TMPD/transcripts" "$TMPD/neutral"
export CLAUDE_TRANSCRIPT_BASE_DIR="$(np "$TMPD/transcripts")"
printf '%s\n' "__cli_test_sentinel__" > "$TMPD/blocklist.txt"
export SCAN_OFFENSIVE_BLOCKLIST="$(np "$TMPD/blocklist.txt")"

REPO="$TMPD/repo"
git init -q -b main "$REPO"
git -C "$REPO" config core.hooksPath /dev/null
git -C "$REPO" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m init
export CLAUDE_PROJECT_DIR="$(np "$REPO")"

HOOKS="$(np "$AGENTS_DIR/hooks")"
cd "$TMPD/neutral" || exit 1

# ebadf <script> [args...] -> OUT / ERR / RC with fd 0 opened write-only.
ebadf() {
    run_with_timeout 60 node "$@" 0>"$TMPD/fd0-sink.txt" >"$TMPD/r.out" 2>"$TMPD/r.err"
    RC=$?
    OUT="$(cat "$TMPD/r.out")"
    ERR="$(cat "$TMPD/r.err")"
}
ctx() { echo "rc=$RC out=${OUT:0:200} err=${ERR:0:200}"; }
reason() { echo "[$1] stdin read-error (EBADF): hook input unreadable; blocking (fail-close)"; }
blocked() { [[ "$OUT" == *'"decision":"block"'* || "$OUT" == *'"permissionDecision":"deny"'* ]]; }

case_begin "block-dotenv-read-error-blocks" "hooks/block-dotenv.js"
ebadf "$HOOKS/block-dotenv.js"
if blocked && [[ "$OUT$ERR" == *"$(reason block-dotenv)"* ]]; then pass "block-dotenv/blocks"; else fail "block-dotenv/blocks" "$(ctx)"; fi
case_end

case_begin "bash-guard-read-error-denies" "hooks/bash-guard.js"
ebadf "$HOOKS/bash-guard.js"
if blocked && [[ "$OUT$ERR" == *"$(reason bash-guard)"* ]]; then pass "bash-guard/denies"; else fail "bash-guard/denies" "$(ctx)"; fi
case_end

case_begin "enforce-system-ops-read-error-exit-2" "hooks/enforce-system-ops.js"
ebadf "$HOOKS/enforce-system-ops.js"
if [[ "$RC" == 2 && "$OUT$ERR" == *"$(reason enforce-system-ops)"* ]]; then pass "enforce-system-ops/exit-2"; else fail "enforce-system-ops/exit-2" "$(ctx)"; fi
case_end

case_begin "enforce-system-ops-env-bypass-before-read" "hooks/enforce-system-ops.js"
export SYSTEM_OPS_APPROVED=1
ebadf "$HOOKS/enforce-system-ops.js"
unset SYSTEM_OPS_APPROVED
if [[ "$RC" == 0 ]] && ! blocked; then pass "enforce-system-ops/approved-exit-0"; else fail "enforce-system-ops/approved-exit-0" "$(ctx)"; fi
case_end

case_begin "scan-outbound-read-error-blocks" "hooks/scan-outbound.js"
ebadf "$HOOKS/scan-outbound.js"
if blocked && [[ "$OUT$ERR" == *"$(reason scan-outbound)"* ]]; then pass "scan-outbound/blocks"; else fail "scan-outbound/blocks" "$(ctx)"; fi
case_end

case_begin "scan-offensive-stdin-read-error-exit-3" "bin/scan-offensive"
ebadf "$(np "$AGENTS_DIR/bin/scan-offensive")" --stdin lbl
if [[ "$RC" == 3 && "$ERR" == *"$(reason scan-offensive)"* ]]; then pass "scan-offensive/exit-3"; else fail "scan-offensive/exit-3" "$(ctx)"; fi
case_end

# expect_decision_block <hook>: the decision-shaped fail-close rows of the S2 table.
expect_decision_block() {
    ebadf "$HOOKS/$1.js"
    if [[ "$RC" == 0 ]] && blocked && [[ "$OUT" == *"$(reason "$1")"* ]]; then pass "$1/blocks"; else fail "$1/blocks" "$(ctx)"; fi
}

case_begin "block-credentials-read-error-blocks" "hooks/block-credentials.js"
expect_decision_block block-credentials
case_end

case_begin "block-shell-config-read-error-blocks" "hooks/block-shell-config.js"
expect_decision_block block-shell-config
case_end

case_begin "block-history-direct-read-error-blocks" "hooks/block-history-direct.js"
expect_decision_block block-history-direct
case_end

case_begin "block-memory-direct-read-error-blocks" "hooks/block-memory-direct.js"
expect_decision_block block-memory-direct
case_end

case_begin "block-tests-direct-read-error-blocks" "hooks/block-tests-direct.js"
expect_decision_block block-tests-direct
case_end

case_begin "block-subagent-sentinels-read-error-blocks" "hooks/block-subagent-sentinels.js"
expect_decision_block block-subagent-sentinels
case_end

case_begin "auto-branch-guard-read-error-blocks" "hooks/auto-branch-guard.js"
expect_decision_block auto-branch-guard
case_end

case_begin "block-clearance-token-write-read-error-blocks" "hooks/block-clearance-token-write.js"
expect_decision_block block-clearance-token-write
case_end

case_begin "block-clearance-token-write-json-invalid-approves" "hooks/block-clearance-token-write.js"
OUT="$(printf 'not json' | run_with_timeout 60 node "$HOOKS/block-clearance-token-write.js" 2>"$TMPD/r.err")"
RC=$?
ERR="$(cat "$TMPD/r.err")"
want="[block-clearance-token-write] stdin json-invalid (8 bytes, SyntaxError): check skipped (fail-open)"
if [[ "$RC" == 0 && "$OUT" == *'"decision":"approve"'* && "$ERR" == "$want" ]]; then
    pass "block-clearance-token-write/json-invalid-approves"
else
    fail "block-clearance-token-write/json-invalid-approves" "$(ctx)"
fi
case_end

case_begin "enforce-issue-close-read-error-exit-2" "hooks/enforce-issue-close.js"
ebadf "$HOOKS/enforce-issue-close.js"
if [[ "$RC" == 2 && "$ERR" == *"$(reason enforce-issue-close)"* ]]; then pass "enforce-issue-close/exit-2"; else fail "enforce-issue-close/exit-2" "$(ctx)"; fi
case_end

# The workflow-off marker bypasses a readable protected hit (control) but never
# the read-error block: that path does not go through blockOrBypass.
case_begin "block-history-direct-read-error-ignores-workflow-off-marker" "hooks/block-history-direct.js"
export CLAUDE_SESSION_ID="srf-workflow-off-fixture"
: > "$CLAUDE_WORKFLOW_DIR/$CLAUDE_SESSION_ID.workflow-off"
printf '{"session_id":"%s","tool_name":"Write","tool_input":{"file_path":"docs/history.md","content":"x"}}' "$CLAUDE_SESSION_ID" > "$TMPD/hist-ev.json"
ctl="$(run_with_timeout 60 node "$HOOKS/block-history-direct.js" < "$TMPD/hist-ev.json" 2>/dev/null)"
if [[ "$ctl" == *'"decision":"approve"'* ]]; then pass "block-history-direct/marker-control-bypasses"; else fail "block-history-direct/marker-control-bypasses" "ctl=${ctl:0:200}"; fi
expect_decision_block block-history-direct
rm -f "$CLAUDE_WORKFLOW_DIR/$CLAUDE_SESSION_ID.workflow-off"
unset CLAUDE_SESSION_ID
case_end

# Passthrough: no allow / deny decision is emitted and stderr stays empty.
case_begin "preuse-auto-approve-read-error-passthrough" "hooks/preuse-auto-approve.js"
ebadf "$HOOKS/preuse-auto-approve.js"
if [[ "$RC" == 0 && -z "$ERR" && "$OUT" != *permissionDecision* && "$OUT" != *'"decision"'* ]]; then
    pass "preuse-auto-approve/passthrough"
else
    fail "preuse-auto-approve/passthrough" "$(ctx)"
fi
case_end

case_begin "rtk-rewrite-read-error-passthrough" "hooks/rtk-rewrite.js"
ebadf "$HOOKS/rtk-rewrite.js"
if [[ "$RC" == 0 && -z "$ERR" && "$OUT" != *permissionDecision* && "$OUT" != *updatedInput* ]]; then
    pass "rtk-rewrite/passthrough"
else
    fail "rtk-rewrite/passthrough" "$(ctx)"
fi
case_end

case_begin "workflow-mark-read-error-one-diagnostic" "hooks/workflow-mark.js"
ebadf "$HOOKS/workflow-mark.js"
want="[workflow-mark] stdin read-error (EBADF): step mark not recorded (fail-open)"
if [[ "$RC" == 0 && "$ERR" == "$want" ]] && ! blocked; then pass "workflow-mark/fail-open-exact-stderr"; else fail "workflow-mark/fail-open-exact-stderr" "$(ctx)"; fi
case_end

case_begin "supervisor-guard-read-error-one-diagnostic" "hooks/supervisor-guard.js"
ebadf "$HOOKS/supervisor-guard.js"
want="[supervisor-guard] stdin read-error (EBADF): supervisor guard skipped (fail-open)"
if [[ "$RC" == 0 && "$ERR" == "$want" ]] && ! blocked; then pass "supervisor-guard/fail-open-exact-stderr"; else fail "supervisor-guard/fail-open-exact-stderr" "$(ctx)"; fi
case_end

case_begin "stop-premature-stop-guard-read-error-one-diagnostic" "hooks/stop-premature-stop-guard.js"
ebadf "$HOOKS/stop-premature-stop-guard.js"
lines=0
[[ -n "$ERR" ]] && lines="$(grep -c '' <<< "$ERR")"
if [[ "$RC" == 0 && "$lines" == 1 ]] && ! blocked \
    && [[ "$ERR" =~ ^\[stop-premature-stop-guard\]\ stdin\ read-error\ \(EBADF\):\ .+\ \(fail-open\)$ ]]; then
    pass "stop-premature-stop-guard/fail-open-one-line"
else
    fail "stop-premature-stop-guard/fail-open-one-line" "lines=$lines $(ctx)"
fi
case_end

case_begin "show-plan-link-read-error-silent" "hooks/show-plan-link.js"
ebadf "$HOOKS/show-plan-link.js"
if [[ "$RC" == 0 && -z "$ERR" ]] && ! blocked; then pass "show-plan-link/silent-fail-open"; else fail "show-plan-link/silent-fail-open" "$(ctx)"; fi
case_end

case_begin "workflow-gate-read-error-blocks" "hooks/workflow-gate.js"
ebadf "$HOOKS/workflow-gate.js"
if blocked; then pass "workflow-gate/blocks"; else fail "workflow-gate/blocks" "$(ctx)"; fi
case_end

case_begin "enforce-worktree-read-error-blocks" "hooks/enforce-worktree.js"
cd "$REPO" || exit 1
export ENFORCE_WORKTREE=on
ebadf "$HOOKS/enforce-worktree.js"
if blocked && [[ "$OUT" == *"$(reason enforce-worktree)"* ]]; then pass "enforce-worktree/blocks"; else fail "enforce-worktree/blocks" "$(ctx)"; fi
case_end

# The sid comes from CLAUDE_SESSION_ID only: there is no input to read it from.
case_begin "enforce-worktree-read-error-worktree-off-marker-passes" "hooks/enforce-worktree.js"
export CLAUDE_SESSION_ID="srf-worktree-off-fixture"
: > "$CLAUDE_WORKFLOW_DIR/$CLAUDE_SESSION_ID.worktree-off"
ebadf "$HOOKS/enforce-worktree.js"
if [[ "$RC" == 0 ]] && ! blocked; then pass "enforce-worktree/marker-pass-through"; else fail "enforce-worktree/marker-pass-through" "$(ctx)"; fi
rm -f "$CLAUDE_WORKFLOW_DIR/$CLAUDE_SESSION_ID.worktree-off"
unset CLAUDE_SESSION_ID ENFORCE_WORKTREE
cd "$TMPD/neutral" || exit 1
case_end

# Valid JSON that is not an object must take each hook's json-invalid verdict
# instead of crashing on input.tool_name (TypeError, exit 1 = fail-open).
# json_null <script>: OUT / ERR / RC for a JSON `null` stdin.
json_null() {
    OUT="$(printf 'null' | run_with_timeout 60 node "$1" 2>"$TMPD/r.err")"
    RC=$?
    ERR="$(cat "$TMPD/r.err")"
}

case_begin "workflow-gate-json-null-blocks" "hooks/workflow-gate.js"
json_null "$HOOKS/workflow-gate.js"
if [[ "$RC" == 0 && "$ERR" != *TypeError* ]] && blocked && [[ "$OUT" == *"failed to parse hook input"* ]]; then
    pass "workflow-gate/json-null-blocks"
else
    fail "workflow-gate/json-null-blocks" "$(ctx)"
fi
case_end

case_begin "enforce-worktree-json-null-fail-open-diagnostic" "hooks/enforce-worktree.js"
cd "$REPO" || exit 1
export ENFORCE_WORKTREE=on
json_null "$HOOKS/enforce-worktree.js"
want="[enforce-worktree] stdin json-invalid (4 bytes, TypeError): worktree check skipped (fail-open)"
if [[ "$RC" == 0 && "$ERR" == "$want" ]] && ! blocked; then
    pass "enforce-worktree/json-null-same-as-json-invalid"
else
    fail "enforce-worktree/json-null-same-as-json-invalid" "$(ctx)"
fi
unset ENFORCE_WORKTREE
cd "$TMPD/neutral" || exit 1
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
