#!/usr/bin/env bash
# tests/TL3-worker-dispatch-child-env-ssh-push.sh
# Tests: bin/worker-dispatch/spawn.js, hooks/lib/worker-dispatch-registry.js
# Tags: worker-dispatch, child-env, ssh-agent, ssh-auth-sock, commit-push, auth-resolution, real-environment, TL3, scope:common, dup-group-keep:size-hard-limit
# The SSH seam, not the gh seam: commit-push is the only worker that runs
# `git push`, and over an ssh remote a live ssh-agent reached through
# SSH_AUTH_SOCK is the only thing that can authenticate it. The registry
# refuses that variable globally (a signing oracle handed to every worker's
# children), so it must arrive via commit-push's own envPassthrough.
set -u

# TL3 gap (what this test does NOT catch):
# - A genuine `git push` to a real ssh:// remote: no key is added to the test
#   agent and no sshd-backed remote is stood up, so host-key policy, git's
#   `ssh -o` handling, and OpenSSH-vs-MSYS agent-protocol mismatches stay
#   unverified. This file proves the socket ARRIVES and is REACHABLE from the
#   dispatched child (ssh-add rc=2 vs rc=0/1); a push signed by that agent, and
#   the hostile-repo canaries, live in TL3-worker-dispatch-ssh-transport.sh.
# - Windows native OpenSSH's named-pipe agent, which uses no SSH_AUTH_SOCK.
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh.
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Stage 1 (buildEnv unit cases) runs BEFORE and INDEPENDENT of the RUN_TL3
# gate: those cases are what must show the gap on an ungated host. Stage 2
# adds a REAL ssh-agent and asserts the socket reaching a dispatched child is
# not merely a matching string but an agent the child can talk to.
# Assertions read the LIVE registry, never a hardcoded expected array.
# Exit contract: FAIL>0 -> 1; INCONCLUSIVE!=0 or PROVEN<REQUIRED -> 77; else 0.
PASS=0; FAIL=0; SKIP=0; PROVEN=0; INCONCLUSIVE=0; REQUIRED=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

# exit_verdict <fail> <inconclusive> <proven> <required> -> 0 | 1 | 77
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

# Gate — EVALUATED here, ACTED ON only after stage 1, so a broken buildEnv
# contract is reported even on a host that cannot run the ssh arms.
GATE_OK=1; GATE_REASON=""
gate_unmet() { GATE_OK=0; [ -n "$GATE_REASON" ] || GATE_REASON="$1"; }

HAVE_NODE=1; command -v node >/dev/null 2>&1 || HAVE_NODE=0
HAVE_GIT=1; command -v git >/dev/null 2>&1 || HAVE_GIT=0
if [ -x "$AGENTS_DIR/bin/get-config-var" ]; then
    if "$AGENTS_DIR/bin/get-config-var" --is-off RUN_TL3 off; then gate_unmet "RUN_TL3 is off"; fi
else
    gate_unmet "bin/get-config-var is not executable"
fi
[ "$HAVE_NODE" = "1" ] || gate_unmet "node is not on PATH"
[ "$HAVE_GIT" = "1" ] || gate_unmet "git is not on PATH"
command -v bash >/dev/null 2>&1 || gate_unmet "bash is not on PATH"
command -v ssh-agent >/dev/null 2>&1 || gate_unmet "ssh-agent is not on PATH"
command -v ssh-add >/dev/null 2>&1 || gate_unmet "ssh-add is not on PATH"

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/wd-sshpush-$$")"
mkdir -p "$TMPD"
AGENT_PID=""
cleanup() { [ -n "$AGENT_PID" ] && kill "$AGENT_PID" 2>/dev/null; rm -rf "$TMPD"; }
trap cleanup EXIT

PLANS_RAW="$TMPD/plans"; mkdir -p "$PLANS_RAW"
WFDIR_RAW="$TMPD/workflow"; mkdir -p "$WFDIR_RAW"
MAIN_RAW="$TMPD/mainrepo"; mkdir -p "$MAIN_RAW"
if [ "$HAVE_GIT" = "1" ]; then
    git -C "$MAIN_RAW" init -q -b main
    git -C "$MAIN_RAW" config user.email "test@example.com"
    git -C "$MAIN_RAW" config user.name "Test"
    git -C "$MAIN_RAW" config core.hooksPath /dev/null
    echo init > "$MAIN_RAW/README.md"
    git -C "$MAIN_RAW" add README.md 2>/dev/null
    git -C "$MAIN_RAW" commit -q --no-verify -m initial 2>/dev/null
fi
MAIN="$(nodepath "$MAIN_RAW")"
PLANS="$(nodepath "$PLANS_RAW")"
WFDIR="$(nodepath "$WFDIR_RAW")"

# Obvious nonsense, never a real secret — proves an UNDECLARED parent variable
# does not reach a dispatched child (guards the fix against over-widening).
FAKE_SECRET="unrelated-FAKE0000-not-a-real-secret"

# Sourced, not executed, so counters and fixtures above are shared
# (rules/coding/file-split.md Pattern A).
TL3_PART_DIR="$(dirname "${BASH_SOURCE[0]}")/TL3-worker-dispatch-child-env-ssh-push"
# shellcheck source=./TL3-worker-dispatch-child-env-ssh-push/probe.sh
. "$TL3_PART_DIR/probe.sh"
# shellcheck source=./TL3-worker-dispatch-child-env-ssh-push/unit-cases.sh
. "$TL3_PART_DIR/unit-cases.sh"
# shellcheck source=./TL3-worker-dispatch-child-env-ssh-push/arms.sh
. "$TL3_PART_DIR/arms.sh"

finish_unmet() {
    echo "SKIP: $1"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP PROVEN=$PROVEN/$REQUIRED (gate unmet)"
    exit "$(exit_verdict "$FAIL" 1 "$PROVEN" "$REQUIRED")"
}

# Stage 0 — the exit arithmetic itself, checked before anything can depend on
# it. A gate-unmet run must answer 77, never 0: "nothing was proved" printing
# as green is the failure mode this file's whole gating structure risks.
assert_eq "exitcode/failure-outranks-everything" "1" "$(exit_verdict 1 0 6 6)"
assert_eq "exitcode/gate-unmet-is-a-skip-not-a-pass" "77" "$(exit_verdict 0 1 0 6)"
assert_eq "exitcode/unproven-required-arm-is-a-skip" "77" "$(exit_verdict 0 0 5 6)"
assert_eq "exitcode/all-required-arms-proven-is-a-pass" "0" "$(exit_verdict 0 0 6 6)"

# Stage 1 — ungated. Needs node only; a host without node says so rather than
# passing vacuously.
if [ "$HAVE_NODE" = "1" ]; then
    run_unit_cases
else
    skip "unit/* — node is not on PATH, buildEnv contract unchecked"
fi

if [ "$GATE_OK" != "1" ]; then
    finish_unmet "environment gate unmet — $GATE_REASON"
fi

# Stage 2 premise — a REAL agent, started here and killed on exit, established
# WITHOUT the dispatcher so a child that cannot reach it afterwards is a
# dispatcher defect rather than a missing agent.
AGENT_OUT="$(run_with_timeout 30 ssh-agent -s 2>/dev/null)" || AGENT_OUT=""
AGENT_SOCK="$(printf '%s\n' "$AGENT_OUT" | sed -n 's/^SSH_AUTH_SOCK=\([^;]*\);.*/\1/p' | head -1)"
AGENT_PID="$(printf '%s\n' "$AGENT_OUT" | sed -n 's/^SSH_AGENT_PID=\([^;]*\);.*/\1/p' | head -1)"
if [ -z "$AGENT_SOCK" ] || [ -z "$AGENT_PID" ]; then
    finish_unmet "ssh-agent did not report a socket and pid on this host"
fi

# ssh-add rc: 0 = agent has keys, 1 = reachable but empty, 2 = cannot connect.
# The 2-vs-not distinction is the whole reachability signal, so the premise is
# measured rather than assumed.
DIRECT_RC="$(SSH_AUTH_SOCK="$AGENT_SOCK" SSH_AGENT_PID="$AGENT_PID" run_with_timeout 30 bash -c 'ssh-add -l >/dev/null 2>&1; echo $?')"
if [ "$DIRECT_RC" = "2" ] || [ -z "$DIRECT_RC" ]; then
    finish_unmet "the ssh-agent started for this run is not reachable directly (ssh-add rc=$DIRECT_RC)"
fi
pass "gate/real-ssh-agent-is-reachable-without-the-dispatcher"

run_arm_table

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP PROVEN=$PROVEN/$REQUIRED"
VERDICT="$(exit_verdict "$FAIL" "$INCONCLUSIVE" "$PROVEN" "$REQUIRED")"
if [ "$VERDICT" = "77" ]; then
    echo "SKIP: required arms did not reach a definite observation (PROVEN=$PROVEN/$REQUIRED)"
fi
exit "$VERDICT"
