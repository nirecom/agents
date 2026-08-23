#!/usr/bin/env bash
# tests/feature-1812-worker-dispatch-env-scope.sh
# Tests: bin/worker-dispatch/spawn.js, bin/worker-dispatch/workers/commit-push.js, bin/worker-dispatch/workers/commit-push/pr.js, bin/worker-dispatch/workers/doc-append.js
# Tags: worker-dispatch, spawn, env-scope, credential-scope, ssh-auth-sock, gh-token, security, TL2, scope:issue-specific
#
# Issue #1812 / #1744 — PER-CALL credential scope. Declaring SSH_AUTH_SOCK
# (commit-push) and GH_TOKEN/GITHUB_TOKEN (doc-append) in envPassthrough handed
# them to EVERY child the worker spawns; spawn.js's opt-in 4th buildEnv
# parameter `envScope` (run()'s opts.envScope) narrows that set per call.
set -u

# No pre-existing test passes an envScope at all, so only the unchanged
# full-set path was covered. Three groups close that:
#   A  buildEnv(entry, anchors, extraEnv, envScope) itself.
#   B  commit-push's call sites — which argv carries SSH_AUTH_SOCK.
#   C  doc-append's single call site — compose carries the tokens, the
#      history/changelog modes carry nothing.
#   D  a REAL child process started by the real spawn.run() — the seam A and
#      B/C leave between them (see feature-1812-.../group-real-child.sh).
if command -v timeout >/dev/null 2>&1 && [ -z "${_WD1812_ENVSCOPE_INNER:-}" ]; then
    _WD1812_ENVSCOPE_INNER=1 timeout 300 bash "$0" "$@"
    exit $?
fi

# B and C are behavioural, not source greps: the real worker runs under the real
# dispatcher with only the process boundary canned, and both stubs
# (tests/feature-1673-commit-push-lib/gate-spawn-stub.js,
# tests/feature-1643-worker-dispatch-lib/spawn-stub.js) record opts.envScope per
# intercepted spawn — so each assertion is on what the worker really asked for.
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# TL3 gap (what this TL2 test does NOT catch):
#   - Whether a real `git push` child still reaches a real ssh-agent through the
#     narrowed env — the scope is asserted, not the resulting authentication.
#     tests/TL3-worker-dispatch-child-env-ssh-push/ covers that tier.
#   - Whether a real `gh` child authenticates from the scoped GH_TOKEN
#     (tests/TL3-worker-dispatch-child-env-gh-doc-append/).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.
DISPATCH_JS="$AGENTS_DIR/bin/worker-dispatch.js"
SPAWN_JS="$AGENTS_DIR/bin/worker-dispatch/spawn.js"
CP_PRELOAD="$AGENTS_DIR/tests/feature-1673-commit-push-lib/gate-spawn-stub.js"
DA_PRELOAD="$AGENTS_DIR/tests/feature-1643-worker-dispatch-lib/spawn-stub.js"

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

for f in "$DISPATCH_JS" "$SPAWN_JS" "$CP_PRELOAD" "$DA_PRELOAD"; do
    if [ ! -f "$f" ]; then
        fail "0/prerequisite" "missing $f"
        echo ""
        echo "Total: PASS=$PASS FAIL=$FAIL"
        exit 1
    fi
done

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/wd1812-envscope-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

MAIN_RAW="$TMPD/mainrepo"
mkdir -p "$MAIN_RAW"
git -C "$MAIN_RAW" init -q -b main >/dev/null 2>&1
git -C "$MAIN_RAW" config user.email "test@example.com"
git -C "$MAIN_RAW" config user.name "Test"
git -C "$MAIN_RAW" config core.hooksPath /dev/null
echo init > "$MAIN_RAW/README.md"
git -C "$MAIN_RAW" add README.md >/dev/null 2>&1
git -C "$MAIN_RAW" commit -q --no-verify -m initial >/dev/null 2>&1
LINKED_RAW="$TMPD/linked-wt"
git -C "$MAIN_RAW" worktree add -q -b feature/1812-probe "$LINKED_RAW" >/dev/null 2>&1
printf '## BugsFound\n- (none)\n' > "$LINKED_RAW/WORKTREE_NOTES.md"

# Both halves of the plans/workflow pair land in the temp tree
# (rules/test/fixture-isolation.md): pinning only one leaks supervisor appends
# into the developer's real ~/.workflow-plans.
PLANS_RAW="$TMPD/plans"; mkdir -p "$PLANS_RAW"
WFDIR_RAW="$TMPD/workflow"; mkdir -p "$WFDIR_RAW"

MAIN="$(nodepath "$MAIN_RAW")"
CWD="$(nodepath "$LINKED_RAW")"
NOTES="$(nodepath "$LINKED_RAW/WORKTREE_NOTES.md")"
PLANS="$(nodepath "$PLANS_RAW")"
WFDIR="$(nodepath "$WFDIR_RAW")"
CANNED="$TMPD/canned.json"
CALLLOG="$TMPD/calls.jsonl"
SID="wd1812-envscope-session"

# Credentials and the socket path are planted in the PARENT env of every probe
# and dispatch below: "which child sees it" is only a real question when the
# parent really holds it. The values are obvious nonsense and never leave this
# process — no real `gh`, `git` or ssh-agent child runs in this file.
FAKE_GH_TOKEN="ghp-FAKE1812-not-a-real-token"
FAKE_GITHUB_TOKEN="github-pat-FAKE1812-not-a-real-token"
FAKE_SSH_SOCK="/tmp/fake-1812-agent.sock"
FAKE_AWS_SECRET="AKIAFAKE1812-not-a-real-secret"

DOUT=""; DRC=0
write_payload() { printf '%s' "$2" > "$PLANS_RAW/$1.json"; nodepath "$PLANS_RAW/$1.json"; }
field_of() {
    local v
    v="$(printf '%s\n' "$DOUT" | sed -n "s/^$1: //p" | head -1)"
    v="${v%\"}"; v="${v#\"}"
    printf '%s' "$v"
}

# dispatch <worker> <preload> <canned-json> <payload-path>
dispatch() {
    printf '%s' "$3" > "$CANNED"
    : > "$CALLLOG"
    DRC=0
    DOUT="$(run_with_timeout 120 env \
        "WORKFLOW_PLANS_DIR=$PLANS" "CLAUDE_WORKFLOW_DIR=$WFDIR" \
        "GH_TOKEN=$FAKE_GH_TOKEN" "GITHUB_TOKEN=$FAKE_GITHUB_TOKEN" \
        "SSH_AUTH_SOCK=$FAKE_SSH_SOCK" \
        "WD_SPAWN_MODULE=$(nodepath "$SPAWN_JS")" \
        "WD_CANNED=$(nodepath "$CANNED")" \
        "WD_CALL_LOG=$(nodepath "$CALLLOG")" \
        node -r "$(nodepath "$2")" "$(nodepath "$DISPATCH_JS")" \
        "$1" "$MAIN" "$4" 2>/dev/null)" || DRC=$?
}

# Parts. Sourced, not executed (rules/coding/file-split.md Pattern A): they
# define the group functions in THIS shell so they share the counters, the
# fixtures and the dispatch helper above.
PART_DIR="$(dirname "${BASH_SOURCE[0]}")/feature-1812-worker-dispatch-env-scope"

# shellcheck source=./feature-1812-worker-dispatch-env-scope/group-buildenv.sh
. "$PART_DIR/group-buildenv.sh"
# shellcheck source=./feature-1812-worker-dispatch-env-scope/group-call-sites.sh
. "$PART_DIR/group-call-sites.sh"
# shellcheck source=./feature-1812-worker-dispatch-env-scope/group-push-ladder.sh
. "$PART_DIR/group-push-ladder.sh"
# shellcheck source=./feature-1812-worker-dispatch-env-scope/group-real-child.sh
. "$PART_DIR/group-real-child.sh"

group_a
group_b
group_b2
group_b4_keywords
group_b4_unrelated
group_b4_fetch_failure
group_b4_conflict
group_b4_rebase_failure
group_b4_exhaustion_via_ladder
group_b3
group_c
group_d

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
