#!/usr/bin/env bash
# tests/hooks/stdin-large-input-hooks.sh
# Tests: hooks/block-dotenv.js, hooks/scan-outbound.js, bin/scan-offensive, hooks/enforce-system-ops.js, hooks/bash-guard.js, hooks/workflow-mark.js, hooks/stop-final-report-guard.js, hooks/workflow-gate.js, hooks/enforce-worktree.js
# Tags: TL1, hook, stdin, read-stdin, large-input, chunked-read, fail-close, scope:common, pwsh-not-required
# Hook stdin past the first read chunk (#1810 S10 + S8 check 1): inputs larger
# than 4096 and 65536 bytes put the decisive field AFTER the padding, through a
# Git Bash pipe and a Node spawnSync pipe. Each expectation differs from what a
# corrupted / truncated read produces (json-invalid fail-open or fail-close).

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
unset CLAUDE_CODE_SESSION_ID SYSTEM_OPS_APPROVED 2>/dev/null || true
unset ANTHROPIC_API_KEY ENFORCE_WORKTREE_EXCLUDE 2>/dev/null || true
mkdir -p "$TMPD/transcripts" "$TMPD/neutral"
export CLAUDE_TRANSCRIPT_BASE_DIR="$(np "$TMPD/transcripts")"

# Hard-hit term reused from the scan-offensive CLI fixture (feature-990).
printf '%s\n' "__cli_test_sentinel__" > "$TMPD/blocklist.txt"
export SCAN_OFFENSIVE_BLOCKLIST="$(np "$TMPD/blocklist.txt")"

REPO="$TMPD/repo"
git init -q -b main "$REPO"
git -C "$REPO" config core.hooksPath /dev/null
git -C "$REPO" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m init
export CLAUDE_PROJECT_DIR="$(np "$REPO")"

HOOKS="$(np "$AGENTS_DIR/hooks")"
SUITE="$(np "$AGENTS_DIR/tests/hooks/stdin-large-input-hooks")"
NEUTRAL="$(np "$TMPD/neutral")"
PAYLOAD="$TMPD/payload.json"
SIZES=(5000 70000)
ROUTES=(bash-pipe spawnsync)
cd "$TMPD/neutral" || exit 1

# feed <route> <script> [args...] -> sets OUT / ERR / RC from $PAYLOAD.
feed() {
    local route="$1"; shift
    if [[ "$route" == bash-pipe ]]; then
        cat "$PAYLOAD" | run_with_timeout 60 node "$@" >"$TMPD/r.out" 2>"$TMPD/r.err"
        RC=${PIPESTATUS[1]}
    else
        run_with_timeout 60 node "$SUITE/drive.js" "$(np "$PAYLOAD")" "$(np "$TMPD/r")" "$@"
        RC="$(cat "$TMPD/r.rc" 2>/dev/null || echo missing)"
    fi
    OUT="$(cat "$TMPD/r.out")"
    ERR="$(cat "$TMPD/r.err")"
}
build() { node "$SUITE/payload.js" "$1" "$2" "$(np "$PAYLOAD")" "${3:-}"; }
no_stdin_diag() { ! grep -Eq 'stdin (json-invalid|read-error)' <<< "$1"; }
ctx() { echo "rc=$RC out=${OUT:0:160} err=${ERR:0:160}"; }

case_begin "block-dotenv-trailing-cat-env-blocks" "hooks/block-dotenv.js"
for n in "${SIZES[@]}"; do for r in "${ROUTES[@]}"; do
    build dotenv "$n"; feed "$r" "$HOOKS/block-dotenv.js"
    if [[ "$OUT" == *'"decision":"block"'* ]]; then pass "block-dotenv/$n/$r"; else fail "block-dotenv/$n/$r" "$(ctx)"; fi
done; done
case_end

case_begin "scan-outbound-offensive-term-past-padding-blocks" "hooks/scan-outbound.js"
for n in "${SIZES[@]}"; do for r in "${ROUTES[@]}"; do
    build outbound "$n" "$NEUTRAL/out-$n-$r.txt"; feed "$r" "$HOOKS/scan-outbound.js"
    if [[ "$OUT" == *'"decision":"block"'* && "$OUT" == *"Offensive content detected"* ]]; then
        pass "scan-outbound/$n/$r"
    else
        fail "scan-outbound/$n/$r" "$(ctx)"
    fi
done; done
case_end

case_begin "scan-offensive-stdin-term-past-padding-hard-hit" "bin/scan-offensive"
for n in "${SIZES[@]}"; do for r in "${ROUTES[@]}"; do
    node -e 'process.stdout.write("p".repeat(+process.argv[1]) + " __cli_test_sentinel__ end\n")' "$n" >"$PAYLOAD"
    feed "$r" "$(np "$AGENTS_DIR/bin/scan-offensive")" --stdin lbl
    if [[ "$RC" == 1 && "$ERR" == *"[offensive-hard] __cli_test_sentinel__"* ]]; then
        pass "scan-offensive/$n/$r"
    else
        fail "scan-offensive/$n/$r" "$(ctx)"
    fi
done; done
case_end

case_begin "enforce-system-ops-trailing-winget-exit-2" "hooks/enforce-system-ops.js"
for n in "${SIZES[@]}"; do for r in "${ROUTES[@]}"; do
    build sysops "$n"; feed "$r" "$HOOKS/enforce-system-ops.js"
    if [[ "$RC" == 2 && "$ERR" == *"enforce-system-ops: blocked"* ]]; then pass "enforce-system-ops/$n/$r"; else fail "enforce-system-ops/$n/$r" "$(ctx)"; fi
done; done
case_end

case_begin "bash-guard-trailing-forbidden-literal-denies" "hooks/bash-guard.js"
for n in "${SIZES[@]}"; do for r in "${ROUTES[@]}"; do
    build bashguard "$n"; feed "$r" "$HOOKS/bash-guard.js"
    if [[ "$OUT" == *'"decision":"block"'* ]]; then pass "bash-guard/$n/$r"; else fail "bash-guard/$n/$r" "$(ctx)"; fi
done; done
case_end

case_begin "workflow-mark-user-verified-past-padding-recorded" "hooks/workflow-mark.js"
for n in "${SIZES[@]}"; do for r in "${ROUTES[@]}"; do
    sid="sil-mark-$n-$r"
    build mark "$n" "$sid"; feed "$r" "$HOOKS/workflow-mark.js"
    st="$(node "$SUITE/step-status.js" "$(np "$AGENTS_DIR")" "$sid" user_verification)"
    if [[ "$st" == complete ]] && no_stdin_diag "$ERR"; then pass "workflow-mark/$n/$r"; else fail "workflow-mark/$n/$r" "status=$st $(ctx)"; fi
done; done
case_end

case_begin "stop-final-report-guard-large-input-no-diagnostic" "hooks/stop-final-report-guard.js"
for n in "${SIZES[@]}"; do for r in "${ROUTES[@]}"; do
    build stop "$n" "sil-stop-$n-$r"; feed "$r" "$HOOKS/stop-final-report-guard.js"
    if [[ "$RC" == 0 ]] && no_stdin_diag "$ERR"; then pass "stop-final-report-guard/$n/$r"; else fail "stop-final-report-guard/$n/$r" "$(ctx)"; fi
done; done
case_end

# S8 check 1: workflow-gate / enforce-worktree also at 1MB, plus the 0-byte
# json-invalid branch (gate: fail-safe block; worktree: pass-through + diagnostic).
GATE_SIZES=(5000 70000 1048576)

case_begin "workflow-gate-large-read-approves" "hooks/workflow-gate.js"
for n in "${GATE_SIZES[@]}"; do for r in "${ROUTES[@]}"; do
    build gate "$n" "$NEUTRAL/read-target.txt"; feed "$r" "$HOOKS/workflow-gate.js"
    if [[ "$OUT" == *'"decision":"approve"'* ]] && no_stdin_diag "$ERR"; then pass "workflow-gate/$n/$r"; else fail "workflow-gate/$n/$r" "$(ctx)"; fi
done; done
for r in "${ROUTES[@]}"; do
    build gate 0; feed "$r" "$HOOKS/workflow-gate.js"
    if [[ "$OUT" == *'"decision":"block"'* ]]; then pass "workflow-gate/0/$r"; else fail "workflow-gate/0/$r" "$(ctx)"; fi
done
case_end

case_begin "enforce-worktree-large-main-write-blocks" "hooks/enforce-worktree.js"
cd "$REPO" || exit 1
export ENFORCE_WORKTREE=on
for n in "${GATE_SIZES[@]}"; do for r in "${ROUTES[@]}"; do
    build worktree "$n" "$(np "$REPO")/f.txt"; feed "$r" "$HOOKS/enforce-worktree.js"
    if [[ "$OUT" == *'"decision":"block"'* ]] && no_stdin_diag "$ERR"; then pass "enforce-worktree/$n/$r"; else fail "enforce-worktree/$n/$r" "$(ctx)"; fi
done; done
for r in "${ROUTES[@]}"; do
    build worktree 0; feed "$r" "$HOOKS/enforce-worktree.js"
    if [[ "$OUT" != *'"decision":"block"'* && "$ERR" == *"[enforce-worktree] stdin json-invalid"* ]]; then
        pass "enforce-worktree/0/$r"
    else
        fail "enforce-worktree/0/$r" "want pass-through + json-invalid diagnostic; $(ctx)"
    fi
done
unset ENFORCE_WORKTREE
cd "$TMPD/neutral" || exit 1
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
