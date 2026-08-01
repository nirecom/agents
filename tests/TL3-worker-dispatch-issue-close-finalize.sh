#!/usr/bin/env bash
# tests/TL3-worker-dispatch-issue-close-finalize.sh
# Tests: bin/worker-dispatch/workers/issue-close-finalize.js, bin/worker-dispatch/anchor.js, skills/issue-close-finalize/scripts/run-initial.sh
# Tags: worker-dispatch, issue-close-finalize, real-environment, anchor-resolution, main-worktree, TL3, scope:issue-specific
#
# Issue #1673 — TL3, one real seam: a real `phase=initial` dispatch from the real
# main worktree, with the real ACD / main-root anchors and the real run-initial.sh
# child process. Everything the TL2 files can the stub over — anchor derivation,
# the child actually starting, the KEY=VALUE stdout of a real bash script
# crossing the process boundary — is exercised here for real.
#
# Safety: the issue number is deliberately unresolvable, so run-initial.sh stops
# at its pre-flight/triage step. Steps 4-6 (sub-issue gate, parent body update,
# G.5 prepare) are the only mutating ones and are never reached. Nothing on the
# forge is created, closed, or edited.
#
# Gate: RUN_TL3=on, a real `gh` on PATH, and a resolvable main worktree.
# Exits 77 (SKIP) otherwise.
#
# TL3 gap (what even this test does NOT catch):
#   - The happy path of a real close: it would mutate live issues, so it stays
#     manual. tests/feature-1673-finalize-multipass.sh covers the transitions
#     with the seam canned.
#   - The operator's real PLANS_DIR (pinned to a temp dir here so a real session's
#     state files are never touched).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -x "$AGENTS_DIR/bin/get-config-var" ] || exit 77
"$AGENTS_DIR/bin/get-config-var" --is-off RUN_TL3 off && exit 77
command -v gh >/dev/null 2>&1 || exit 77
command -v git >/dev/null 2>&1 || exit 77

DISPATCH_JS="$AGENTS_DIR/bin/worker-dispatch.js"
[ -f "$DISPATCH_JS" ] || exit 77

MAIN_ROOT="$(git -C "$AGENTS_DIR" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1)"
[ -n "$MAIN_ROOT" ] || exit 77
[ -d "$MAIN_ROOT" ] || exit 77

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

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
PLANS_RAW="$TMPD/plans"; mkdir -p "$PLANS_RAW"
PLANS="$(nodepath "$PLANS_RAW")"
MAIN="$(nodepath "$MAIN_ROOT")"

SID="tl3icf"
# Out of any plausible issue range: triage cannot resolve it, so run-initial.sh
# returns STATUS=failed before reaching any mutating step.
UNRESOLVABLE=999999999
STATE_RAW="$PLANS_RAW/$SID-finalize-state-$UNRESOLVABLE.json"
STATE="$(nodepath "$STATE_RAW")"
BIND_RAW="$PLANS_RAW/$SID-finalize-binding-$UNRESOLVABLE.json"
PAYLOAD_RAW="$PLANS_RAW/$SID-worker-issue-close-finalize-1.json"

printf '%s' "{\"phase\":\"initial\",\"issue_number\":$UNRESOLVABLE,\"root_issue_number\":$UNRESOLVABLE,\"owner_repo\":\"nirecom/agents\",\"state_file_path\":\"$STATE\",\"main_worktree_path\":\"$MAIN\",\"session_id\":\"$SID\",\"artifact_dir\":\"$PLANS\"}" > "$PAYLOAD_RAW"

DRC=0
DOUT="$(run_with_timeout 180 env "WORKFLOW_PLANS_DIR=$PLANS" \
    node "$(nodepath "$DISPATCH_JS")" issue-close-finalize "$MAIN" "$(nodepath "$PAYLOAD_RAW")" 2>&1)" || DRC=$?

field_of() {
    local v
    v="$(printf '%s\n' "$DOUT" | sed -n "s/^$1: //p" | head -1)"
    v="${v%\"}"; v="${v#\"}"
    printf '%s' "$v"
}

# (a) the dispatcher completes and renders the status triple — never a crash
assert_eq "tl3/exit0" "0" "$DRC"
case "$(field_of status)" in
    failed|init_done) pass "tl3/status-in-vocabulary" ;;
    *) fail "tl3/status-in-vocabulary" "status='$(field_of status)' out='$DOUT'" ;;
esac

# (b) an unresolvable issue must NOT leave a state file behind
assert_eq "tl3/no-state-on-failure" "0" "$([ -f "$STATE_RAW" ] && [ "$(field_of status)" = "failed" ] && echo 1 || echo 0)"
assert_eq "tl3/no-binding-on-failure" "0" "$([ -f "$BIND_RAW" ] && [ "$(field_of status)" = "failed" ] && echo 1 || echo 0)"

# (c) the summary carries the child's own first line, not a generic message —
# proof the real child's stdout crossed the boundary and was parsed
if [ -n "$(field_of summary)" ]; then
    pass "tl3/summary-non-empty"
else
    fail "tl3/summary-non-empty" "out='$DOUT'"
fi

# (d) the run never touched a real session's plans dir
assert_eq "tl3/plans-dir-isolated" "1" \
    "$(ls "$PLANS_RAW" | grep -cv "^$SID-" | { read -r n; [ "$n" -eq 0 ] && echo 1 || echo 0; })"

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
