#!/usr/bin/env bash
# tests/feature-1812-worker-dispatch-ssh-agent-pid-absence.sh
# Tests: bin/worker-dispatch/workers/commit-push/push.js, bin/worker-dispatch/spawn.js, hooks/lib/worker-dispatch-registry.js
# Tags: worker-dispatch, commit-push, ssh-agent-pid, ssh-auth-sock, git-push, credential-scope, canary, security, TL2, scope:issue-specific
#
# Issue #1812 — SSH_AGENT_PID is DELIBERATELY not propagated. commit-push
# declares SSH_AUTH_SOCK and nothing else of the pair; the omission is stated at
# hooks/lib/worker-dispatch-registry.js (commit-push envPassthrough): the ssh
# client authenticates off the socket alone, and the PID only adds the agent's
# lifecycle handle — `kill`-able, and enough to drive `ssh-agent -k`.
set -u

# So a later review round reads this as settled rather than as missing coverage:
# the rows below are ABSENCE proofs by design. Adding SSH_AGENT_PID to
# envPassthrough to make them "propagate" would reverse the least-privilege
# decision, not complete it — outline.md's "as needed" qualifier is what scopes
# the pair, and the socket is what is needed.
if command -v timeout >/dev/null 2>&1 && [ -z "${_WD1812_AGENTPID_INNER:-}" ]; then
    _WD1812_AGENTPID_INNER=1 timeout 300 bash "$0" "$@"
    exit $?
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRANCH="feature/1812-agentpid-probe"

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

# TL3 gap (what this offline test does NOT catch):
# - A real ssh-agent and a real sshd: the transport is a core.sshCommand wrapper,
#   so OpenSSH's own env handling and the Windows named-pipe agent (which uses no
#   SSH_AUTH_SOCK at all) stay unverified.
# - Whether a leaked SSH_AGENT_PID would really let planted code kill the agent.
# tests/TL3-worker-dispatch-ssh-transport.sh is the real-agent tier.
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh.

for tool in git node; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "SKIP: $tool is not on PATH"
        echo ""
        echo "Total: PASS=0 FAIL=0 SKIP=1"
        exit 77
    fi
done

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/wd1812-agentpid-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

PLANS_RAW="$TMPD/plans"; mkdir -p "$PLANS_RAW"
WFDIR_RAW="$TMPD/workflow"; mkdir -p "$WFDIR_RAW"

# Planted, never real: no ssh-agent runs in this file. The socket path points at
# nothing and the PID is not a live process, which is the point — what is
# measured is which child RECEIVES the two names, not what they unlock.
FAKE_SSH_SOCK="/tmp/fake-1812-agent.sock"
FAKE_AGENT_PID="181299"

# One socket, two spellings: MSYS rewrites a POSIX path on the way into a
# Windows-native child, so the value a canary prints is host-dependent while the
# claim ("it is OUR socket, verbatim") is not.
FAKE_SSH_SOCK_WIN="$(nodepath "$FAKE_SSH_SOCK")"
assert_sock() {
    local name="$1" got="$2"
    if [ "$got" = "$FAKE_SSH_SOCK" ] || [ "$got" = "$FAKE_SSH_SOCK_WIN" ]; then pass "$name"
    else fail "$name" "want=$FAKE_SSH_SOCK (or $FAKE_SSH_SOCK_WIN) got=$(printf '%q' "$got")"; fi
}

# shellcheck source=./feature-1812-worker-dispatch-ssh-agent-pid-absence/fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/feature-1812-worker-dispatch-ssh-agent-pid-absence/fixture.sh"

build_canaries
build_probe
if ! build_repos; then
    fail "0/fixture-built" "the ssh:// transport fixture could not be seeded"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit 1
fi
pass "0/fixture-built"

# Control (protection-fix-tests.md Pattern 2, inverted): a git call made from a
# parent that holds BOTH names, with no dispatcher in between. It proves the
# canary can SEE an SSH_AGENT_PID — without it every absence row below could be
# passing because the observer is blind.
: > "$CANARY_LOG"
run_with_timeout 60 env "SSH_AUTH_SOCK=$FAKE_SSH_SOCK" "SSH_AGENT_PID=$FAKE_AGENT_PID" \
    git -C "$WT_RAW" fetch -q origin "$BRANCH" >/dev/null 2>&1
assert_eq "C1/canary-can-observe-an-agent-pid-when-one-is-present" \
    "$FAKE_AGENT_PID" "$(canary_field transport-upload agentpid)"
assert_sock "C1/canary-can-observe-the-socket-when-one-is-present" "$(canary_field transport-upload sock)"

if ! force_divergence; then
    fail "0/divergence-forced" "the second clone could not push a divergent commit"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit 1
fi
pass "0/divergence-forced"

: > "$CANARY_LOG"
POUT=""
POUT="$(run_with_timeout 240 env \
    -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u GH_TOKEN -u GITHUB_TOKEN \
    "SSH_AUTH_SOCK=$FAKE_SSH_SOCK" "SSH_AGENT_PID=$FAKE_AGENT_PID" \
    "WORKFLOW_PLANS_DIR=$(nodepath "$PLANS_RAW")" \
    "CLAUDE_WORKFLOW_DIR=$(nodepath "$WFDIR_RAW")" \
    node "$(nodepath "$PROBE_JS")" "$(nodepath "$AGENTS_DIR")" \
    "$(nodepath "$MAIN_RAW")" "$(nodepath "$WT_RAW")" "$BRANCH" 2>&1)" || true
pv() { printf '%s\n' "$POUT" | sed -n "s|^$1=||p" | head -1; }

if [ -n "$(pv probe_error)" ] || [ -z "$(pv push_status)" ]; then
    fail "1/real-push.js-ran-to-completion" "$(printf '%s' "$POUT" | tr '\n' ' ' | cut -c1-400)"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit 1
fi
pass "1/real-push.js-ran-to-completion"

# Non-vacuity anchor: the ladder really made the rejected-push / fetch / rebase /
# re-push round trip, so the absence rows below are about children that ran.
assert_eq "1/ladder-completed-the-push" "ok" "$(pv push_status)"
if [ "$(pv git_calls)" -ge 4 ]; then
    pass "1/ladder-drove-the-full-push-fetch-rebase-repush-sequence"
else
    fail "1/ladder-drove-the-full-push-fetch-rebase-repush-sequence" "argv=$(pv git_argv)"
fi

# 2 — the network legs. push.js asks for exactly ["SSH_AUTH_SOCK"] on both, and
# what the transport child actually received is what is read back here.
assert_sock "2/push-transport-received-the-socket" "$(canary_field transport-receive sock)"
assert_eq "2/push-transport-received-no-agent-pid" "<unset>" "$(canary_field transport-receive agentpid)"
assert_sock "2/fetch-transport-received-the-socket" "$(canary_field transport-upload sock)"
assert_eq "2/fetch-transport-received-no-agent-pid" "<unset>" "$(canary_field transport-upload agentpid)"

# The retry push after the replay: the SECOND receive-pack call is a different
# child from the first, and the scope must not have widened along the way.
if [ "$(canary_count transport-receive)" -ge 2 ]; then
    assert_eq "2/retry-push-transport-received-no-agent-pid" "<unset>" "$(canary_field transport-receive agentpid 2)"
    assert_sock "2/retry-push-transport-received-the-socket" "$(canary_field transport-receive sock 2)"
else
    fail "2/retry-push-transport-received-no-agent-pid" "only $(canary_count transport-receive) receive-pack call(s)"
    fail "2/retry-push-transport-received-the-socket" "only $(canary_count transport-receive) receive-pack call(s)"
fi

# 3 — the local replay leg, which runs repo-controlled hooks and takes the EMPTY
# scope: neither name may reach it.
if [ "$(canary_count pre-rebase)" -ge 1 ]; then
    assert_eq "3/rebase-replay-hook-saw-no-socket" "<unset>" "$(canary_field pre-rebase sock)"
    assert_eq "3/rebase-replay-hook-saw-no-agent-pid" "<unset>" "$(canary_field pre-rebase agentpid)"
else
    fail "3/rebase-replay-hook-saw-no-socket" "pre-rebase never fired: $(tr '\n' ';' < "$CANARY_LOG")"
    fail "3/rebase-replay-hook-saw-no-agent-pid" "pre-rebase never fired"
fi

# 4 — the sanctioned blast radius. pre-push is a child of the very push that must
# hold the socket, so it inherits the socket by construction; the PID is the half
# that stays out even there, which is the whole content of the omission.
if [ "$(canary_count pre-push)" -ge 1 ]; then
    assert_sock "4/pre-push-hook-inherits-the-socket-by-construction" "$(canary_field pre-push sock)"
    assert_eq "4/pre-push-hook-still-sees-no-agent-pid" "<unset>" "$(canary_field pre-push agentpid)"
else
    fail "4/pre-push-hook-still-sees-no-agent-pid" "pre-push never fired: $(tr '\n' ';' < "$CANARY_LOG")"
fi

# 5 — no child anywhere in the run recorded the PID, name-agnostically over the
# whole canary log rather than over the handful of observers named above.
if grep -q "agentpid=$FAKE_AGENT_PID" "$CANARY_LOG"; then
    fail "5/no-child-in-the-whole-ladder-received-the-agent-pid" "$(grep -n "agentpid=$FAKE_AGENT_PID" "$CANARY_LOG" | tr '\n' ';')"
else
    pass "5/no-child-in-the-whole-ladder-received-the-agent-pid"
fi

# 6 — the declaration that makes 2-5 structural rather than incidental: the entry
# is the ceiling envScope narrows within, so no call site can opt the PID back in.
assert_eq "6/commit-push-declares-the-socket" "true" "$(pv declares_auth_sock)"
assert_eq "6/commit-push-does-not-declare-the-agent-pid" "false" "$(pv declares_agent_pid)"
assert_eq "6/agent-pid-is-not-in-the-global-child-allowlist" "false" "$(pv allowlists_agent_pid)"

# SKIPPED: asserting the pre-push hook is starved of the SOCKET too.
# Because: it is a child of the push that must hold it — no test-layer change
# makes that false; row 4 pins the residual instead.
# L3 gap: a repo whose pre-push hook signs arbitrary data through the agent is
# inside the sanctioned push blast radius.

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
