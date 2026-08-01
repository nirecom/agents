#!/usr/bin/env bash
# tests/TL3-worker-dispatch-commit-push.sh
# Tests: bin/worker-dispatch.js, bin/worker-dispatch/workers/commit-push.js, bin/worker-dispatch/spawn.js, hooks/workflow-gate.js
# Tags: worker-dispatch, commit-push, workflow-gate, real-git, TL3, run-e2e, scope:issue-specific
#
# Issue #1673 D1 — real-environment seam for the gate reproduction.
#
# The sibling TL2 tests (feature-1673-commit-push-gate.sh, -gate-envdir.sh) stub
# bin/worker-dispatch/spawn.js, so they prove the worker ASKS the gate the right
# question and reacts to the answer — but every verdict they see is one the test
# itself wrote. This file removes the stub: a real dispatcher spawns a real
# hooks/workflow-gate.js child, which reads a real state directory, and real git
# commits either land in a real repository or do not.
#
# That is the one thing no amount of TL2 can establish: that moving `git commit`
# and `git push` off the Bash tool and into a dispatcher child still leaves the
# workflow gate standing in front of them. The TL2 stub would report success even
# if the child could never reach the gate binary at all.
#
# Deliberately narrow: one blocked run and one allowed run, on a local bare
# remote. No GitHub, no `gh`, no network.
#
# TL3 gap (what even this test does NOT cover):
#   - The real PreToolUse invocation path. Claude Code feeds the gate its payload
#     over stdin from the tool layer; here the worker constructs that payload.
#     A divergence between the two shapes is only caught by TL4.
#   - `gh pr create` against real GitHub (both scenarios set enforce_worktree=off
#     so step 8 short-circuits before the PR path).
#   - bin/open-pr-url.js opening a real browser.
set -u

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

[ -x "$AGENTS_DIR/bin/get-config-var" ] || exit 77
"$AGENTS_DIR/bin/get-config-var" --is-off RUN_TL3 off && exit 77
command -v git >/dev/null 2>&1 || exit 77
command -v node >/dev/null 2>&1 || exit 77

DISPATCH="$AGENTS_DIR/bin/worker-dispatch.js"
GATE="$AGENTS_DIR/hooks/workflow-gate.js"
WORKER="$AGENTS_DIR/bin/worker-dispatch/workers/commit-push.js"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

for f in "$DISPATCH" "$GATE"; do
    [ -f "$f" ] || { fail "prerequisite" "missing $f"; echo "Total: PASS=$PASS FAIL=$FAIL"; exit 1; }
done
if [ ! -f "$WORKER" ]; then
    fail "prerequisite/worker-module" "implementation missing: bin/worker-dispatch/workers/commit-push.js (#1673 not yet implemented)"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit 1
fi

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/tl3-cp1673-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD" 2>/dev/null || true' EXIT

BRANCH="feature/1673-tl3"

# --- real repo family: bare remote + main worktree + linked worktree ---------
git init -q --bare "$TMPD/remote.git"
git init -q -b main "$TMPD/main"
git -C "$TMPD/main" config user.email "tl3@example.com"
git -C "$TMPD/main" config user.name "TL3"
git -C "$TMPD/main" config commit.gpgsign false
git -C "$TMPD/main" remote add origin "$TMPD/remote.git"
printf 'seed\n' > "$TMPD/main/README.md"
git -C "$TMPD/main" add README.md
git -C "$TMPD/main" commit -q --no-verify -m "seed"
git -C "$TMPD/main" push -q -u origin main
git -C "$TMPD/main" worktree add -q -b "$BRANCH" "$TMPD/wt" main
git -C "$TMPD/wt" config user.email "tl3@example.com"
git -C "$TMPD/wt" config user.name "TL3"
git -C "$TMPD/wt" config commit.gpgsign false

MAIN_ROOT="$(cd "$TMPD/main" && pwd)"
WT="$(cd "$TMPD/wt" && pwd)"

# stage_change <text> — a real staged edit for the worker to commit
stage_change() {
    printf '%s\n' "$1" >> "$WT/README.md"
    git -C "$WT" add README.md
}

# write_state <dir> <sid> <verification-status>
write_state() {
    mkdir -p "$1"
    node -e '
      const fs = require("fs");
      const [, file, status] = process.argv;
      const step = { status: "complete" };
      fs.writeFileSync(file, JSON.stringify({
        steps: {
          workflow_init: step, clarify_intent: step, make_outline_plan: step,
          make_detail_plan: step, write_tests: step, review_tests: step,
          write_code: step, run_tests: step, review_security: step,
          docs: step, user_verification: { status },
        },
      }));
    ' "$(nodepath "$1/$2.json")" "$3"
}

PLANS="$TMPD/plans"
mkdir -p "$PLANS"

# run_worker <payload-json-file> <state-dir> — echoes "<exit-code>|<stdout>"
run_worker() {
    local out rc=0
    out="$(run_with_timeout 120 env \
        "CLAUDE_WORKFLOW_DIR=$(nodepath "$2")" \
        "WORKFLOW_PLANS_DIR=$(nodepath "$PLANS")" \
        "ENFORCE_WORKTREE=off" \
        "AGENTS_CONFIG_DIR=$(nodepath "$AGENTS_DIR")" \
        node "$(nodepath "$DISPATCH")" commit-push "$(nodepath "$MAIN_ROOT")" \
        "$(nodepath "$1")" 2>&1)" || rc=$?
    printf '%s|%s' "$rc" "$out"
}

write_payload() {
    node -e '
      const fs = require("fs");
      const [, file, wt, branch, sid, msg] = process.argv;
      fs.writeFileSync(file, JSON.stringify({
        commit_message: msg,
        branch,
        worktree_path: wt,
        session_id: sid,
        enforce_worktree: "off",
        closes_issues: [],
      }));
    ' "$(nodepath "$1")" "$WT" "$BRANCH" "$2" "$3"
}

status_of() { printf '%s' "$1" | grep -oE '"?status"?[": ]+[a-z_]+' | head -1 | grep -oE '[a-z_]+$'; }

# ===========================================================================
# Scenario 1 — the gate really blocks: no state file for this session
#
# workflow-gate.js fails closed on missing state. If the gate never ran, or ran
# without CLAUDE_WORKFLOW_DIR reaching it, the commit lands and this fails.
# ===========================================================================
scenario_blocked() {
    local before after res rc out
    mkdir -p "$TMPD/state-blocked"   # deliberately empty: no <sid>.json
    stage_change "blocked-run"
    before="$(git -C "$WT" rev-parse HEAD)"
    write_payload "$TMPD/pay-blocked.json" "tl3sidblocked" "test: must not be committed"
    res="$(run_worker "$TMPD/pay-blocked.json" "$TMPD/state-blocked")"
    rc="${res%%|*}"; out="${res#*|}"
    assert_eq "blocked/status" "gate_blocked" "$(status_of "$out")"
    after="$(git -C "$WT" rev-parse HEAD)"
    assert_eq "blocked/head-unchanged" "$before" "$after"
    assert_eq "blocked/remote-has-no-branch" "" \
        "$(git -C "$TMPD/remote.git" rev-parse --verify -q "refs/heads/$BRANCH" 2>/dev/null || true)"
    [ "$rc" != "0" ] && pass "blocked/nonzero-exit" || fail "blocked/nonzero-exit" "exit code was 0"
    # Leave the tree clean for scenario 2.
    git -C "$WT" reset -q --hard HEAD
}

# ===========================================================================
# Scenario 2 — the gate really allows: a complete state file for this session
# ===========================================================================
scenario_allowed() {
    local before after res rc out
    write_state "$TMPD/state-ok" "tl3sidok" "complete"
    stage_change "allowed-run"
    before="$(git -C "$WT" rev-parse HEAD)"
    write_payload "$TMPD/pay-ok.json" "tl3sidok" "test: real commit through the dispatcher"
    res="$(run_worker "$TMPD/pay-ok.json" "$TMPD/state-ok")"
    rc="${res%%|*}"; out="${res#*|}"
    assert_eq "allowed/status" "pushed" "$(status_of "$out")"
    assert_eq "allowed/exit0" "0" "$rc"
    after="$(git -C "$WT" rev-parse HEAD)"
    if [ "$before" != "$after" ]; then pass "allowed/commit-landed"
    else fail "allowed/commit-landed" "HEAD did not move: $after"; fi
    assert_eq "allowed/commit-message" "test: real commit through the dispatcher" \
        "$(git -C "$WT" log -1 --pretty=%s)"
    assert_eq "allowed/remote-received-branch" "$after" \
        "$(git -C "$TMPD/remote.git" rev-parse --verify -q "refs/heads/$BRANCH" 2>/dev/null || true)"
}

scenario_blocked
scenario_allowed

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
