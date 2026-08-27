#!/usr/bin/env bash
# tests/TL3-worker-dispatch-ssh-transport.sh
# Tests: bin/worker-dispatch/workers/commit-push/push.js, bin/worker-dispatch/workers/commit-push/gate.js, bin/worker-dispatch/spawn.js
# Tags: worker-dispatch, commit-push, ssh-agent, ssh-auth-sock, git-push, adversarial, canary, security, real-environment, TL3, scope:common
# A REAL agent-authenticated `git push` that really moves a remote ref, run
# against a repository that has planted the two execution surfaces a compromised
# repo actually gets: core.hooksPath hooks and a repo-local core.sshCommand.
# The sibling TL3-worker-dispatch-child-env-ssh-push.sh proves the socket
# ARRIVES; this file proves a push SIGNED by that agent completes, and that the
# planted code on the commit and rebase steps finds no agent to sign with.
set -u

# TL3 gap (what this test does NOT catch):
# - A real sshd: the transport is a core.sshCommand wrapper that refuses unless
#   the agent is reachable and holds a key, so agent-gating is genuine, but
#   host-key policy, OpenSSH's own -o handling and the Windows-native
#   named-pipe agent (which uses no SSH_AUTH_SOCK at all) stay unverified.
#   No sshd binary exists on the supported dev hosts, and standing one up would
#   need a privileged listener this suite must not open.
# - The pre-push hook, which inherits the socket by construction (see arms.sh).
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh.
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRANCH="feature/tl3-ssh-transport-probe"

# Exit contract: FAIL>0 -> 1; INCONCLUSIVE!=0 or PROVEN<REQUIRED -> 77; else 0.
# A gated-out or half-run host must answer 77, never 0 — "nothing was proved"
# printing as green is the failure mode this file's structure exists to prevent.
PASS=0; FAIL=0; SKIP=0; PROVEN=0; INCONCLUSIVE=0
REQUIRED=15

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"; PROVEN=$((PROVEN + 1))
    else fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

exit_verdict() {
    if [ "$1" -gt 0 ]; then echo 1
    elif [ "$2" -ne 0 ] || [ "$3" -lt "$4" ]; then echo 77
    else echo 0; fi
}

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

GATE_OK=1; GATE_REASON=""
gate_unmet() { GATE_OK=0; [ -n "$GATE_REASON" ] || GATE_REASON="$1"; }

if [ -x "$AGENTS_DIR/bin/get-config-var" ]; then
    if "$AGENTS_DIR/bin/get-config-var" --is-off RUN_TL3 off; then gate_unmet "RUN_TL3 is off"; fi
else
    gate_unmet "bin/get-config-var is not executable"
fi
for c in node git bash ssh-agent ssh-add ssh-keygen; do
    command -v "$c" >/dev/null 2>&1 || gate_unmet "$c is not on PATH"
done

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/wd-sshtransport-$$")"
mkdir -p "$TMPD"
AGENT_PID=""
cleanup() {
    [ -n "${WT_RAW:-}" ] && git -C "${MAIN_RAW:-$TMPD}" worktree remove --force "$WT_RAW" >/dev/null 2>&1
    [ -n "$AGENT_PID" ] && kill "$AGENT_PID" 2>/dev/null
    rm -rf "$TMPD"
}
trap cleanup EXIT

PLANS_RAW="$TMPD/plans"; mkdir -p "$PLANS_RAW"
WFDIR_RAW="$TMPD/workflow"; mkdir -p "$WFDIR_RAW"
PLANS="$(nodepath "$PLANS_RAW")"
WFDIR="$(nodepath "$WFDIR_RAW")"

PART_DIR="$(dirname "${BASH_SOURCE[0]}")/TL3-worker-dispatch-ssh-transport"
# shellcheck source=./TL3-worker-dispatch-ssh-transport/fixture.sh
. "$PART_DIR/fixture.sh"
# shellcheck source=./TL3-worker-dispatch-ssh-transport/arms.sh
. "$PART_DIR/arms.sh"

finish_unmet() {
    echo "SKIP: $1"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP PROVEN=$PROVEN/$REQUIRED (gate unmet)"
    exit "$(exit_verdict "$FAIL" 1 "$PROVEN" "$REQUIRED")"
}

# Stage 0 — the exit arithmetic, before anything can depend on it.
assert_eq "exitcode/failure-outranks-everything" "1" "$(exit_verdict 1 0 15 15)"
assert_eq "exitcode/gate-unmet-is-a-skip-not-a-pass" "77" "$(exit_verdict 0 1 0 15)"
assert_eq "exitcode/unproven-required-arm-is-a-skip" "77" "$(exit_verdict 0 0 14 15)"
assert_eq "exitcode/all-required-arms-proven-is-a-pass" "0" "$(exit_verdict 0 0 15 15)"
PROVEN=0

[ "$GATE_OK" = "1" ] || finish_unmet "environment gate unmet — $GATE_REASON"

# Stage 1 premise — a REAL agent holding a REAL key, established WITHOUT the
# dispatcher, so a child that cannot reach it afterwards is a dispatcher fact
# rather than a missing agent.
AGENT_OUT="$(run_with_timeout 30 ssh-agent -s 2>/dev/null)" || AGENT_OUT=""
AGENT_SOCK="$(printf '%s\n' "$AGENT_OUT" | sed -n 's/^SSH_AUTH_SOCK=\([^;]*\);.*/\1/p' | head -1)"
AGENT_PID="$(printf '%s\n' "$AGENT_OUT" | sed -n 's/^SSH_AGENT_PID=\([^;]*\);.*/\1/p' | head -1)"
[ -n "$AGENT_SOCK" ] && [ -n "$AGENT_PID" ] || finish_unmet "ssh-agent reported no socket and pid on this host"

ssh-keygen -q -t ed25519 -N "" -C tl3-ssh-transport -f "$TMPD/id_probe" </dev/null >/dev/null 2>&1 \
    || finish_unmet "ssh-keygen could not generate a probe key"
SSH_AUTH_SOCK="$AGENT_SOCK" SSH_AGENT_PID="$AGENT_PID" \
    run_with_timeout 30 ssh-add "$TMPD/id_probe" >/dev/null 2>&1 \
    || finish_unmet "the probe key could not be added to the agent"
DIRECT_RC="$(SSH_AUTH_SOCK="$AGENT_SOCK" SSH_AGENT_PID="$AGENT_PID" run_with_timeout 30 bash -c 'ssh-add -l >/dev/null 2>&1; echo $?')"
[ "$DIRECT_RC" = "0" ] || finish_unmet "the agent started for this run does not hold the probe key (ssh-add rc=$DIRECT_RC)"
pass "gate/real-agent-holds-a-real-key-without-the-dispatcher"

build_canaries
build_repos || finish_unmet "the ssh:// fixture remote could not be seeded through the canary transport"
# Non-vacuity: the seeding pushes above must have gone THROUGH the wrapper, or
# the "remote" is reachable by some path the worker could also take.
[ "${SEED_TRANSPORTS:-0}" -ge 2 ] \
    || finish_unmet "the fixture remote was reachable without the canary transport (seed transports=${SEED_TRANSPORTS:-0})"
pass "gate/hostile-repo-fixture-built"

arm_clean_push
arm_rebase_ladder

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP PROVEN=$PROVEN/$REQUIRED"
VERDICT="$(exit_verdict "$FAIL" "$INCONCLUSIVE" "$PROVEN" "$REQUIRED")"
if [ "$VERDICT" = "77" ]; then
    echo "SKIP: required arms did not reach a definite observation (PROVEN=$PROVEN/$REQUIRED)"
fi
exit "$VERDICT"
