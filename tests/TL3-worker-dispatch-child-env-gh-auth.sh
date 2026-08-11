#!/usr/bin/env bash
# tests/TL3-worker-dispatch-child-env-gh-auth.sh
# Tests: bin/worker-dispatch/spawn.js, hooks/lib/worker-dispatch-registry.js
# Tags: worker-dispatch, child-env, config-path, gh-cli, auth-resolution, real-environment, TL3, scope:common
#
# TL3: fences #1719 — buildEnv() copied the right SET of env vars but the
# WRONG members, breaking gh's config-dir resolution in a way invisible below
# the real gh binary. Split from TL3-worker-dispatch-gh-contract.sh (gh's flag
# surface, gated only on "gh exists") because sharing would drag that looser
# gate down to this file's stricter auth-reachability requirement.
# Gate is a DIRECT spawnSync of gh, never dispatched, so a broken dispatcher
# can't masquerade as "not ready" and skip instead of report. gh's output is
# classified in-memory inside the probe and never written to disk.
# Both a SYNTHETIC arm (isolates the config path) and a REAL registry arm
# (issue-reconcile) are required — the synthetic one alone could go green
# while every actually-registered gh worker was broken.
# Exit contract (exit_verdict, self-checked in stage 1): FAIL>0 -> 1;
# INCONCLUSIVE!=0 or PROVEN<REQUIRED -> 77; else 0. Required-arm table and
# platform applicability live as data in ARM_TABLE (arms.sh).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Environment gate — EVALUATED here, ACTED ON only after stage 1. Exiting 77
# before stage 1 would let a broken classify()/exit_verdict()/expect_class()
# read as green-as-skipped on every ungated host, so those pure-logic deciders
# run first and unconditionally; the gate governs only the arms below them.
GATE_OK=1
GATE_REASON=""
gate_unmet() { GATE_OK=0; [ -n "$GATE_REASON" ] || GATE_REASON="$1"; }

if [ -x "$AGENTS_DIR/bin/get-config-var" ]; then
    if "$AGENTS_DIR/bin/get-config-var" --is-off RUN_TL3 off; then
        gate_unmet "RUN_TL3 is off"
    fi
else
    gate_unmet "bin/get-config-var is not executable"
fi

# Tracked by name, not folded into GATE_REASON: stage 1 needs node only for
# the classify() self-check; git is needed only for the dispatched arms.
HAVE_NODE=1; command -v node >/dev/null 2>&1 || HAVE_NODE=0
HAVE_GIT=1; command -v git >/dev/null 2>&1 || HAVE_GIT=0
[ "$HAVE_NODE" = "1" ] || gate_unmet "node is not on PATH"
[ "$HAVE_GIT" = "1" ] || gate_unmet "git is not on PATH"
command -v gh >/dev/null 2>&1 || gate_unmet "gh is not on PATH"

# One host, fixed: a bare `gh auth status` inspects every known host/account and
# fails on any single stale one, suppressing the file for an unrelated reason.
# GH_HOST only selects the host; it is pinned into every probe's env (run_probe)
# so the gate and dispatched arms can never end up asking about different hosts.
TARGET_HOST="${GH_HOST:-github.com}"

# Credentials stripped from every probe's env, gate included, so the gate and
# the dispatcher-routed arms run under IDENTICAL credential conditions.
# GH_ENTERPRISE_TOKEN/GITHUB_ENTERPRISE_TOKEN are in neither CHILD_ENV_ALLOWLIST
# nor any worker's envPassthrough, so a dispatched child can never hold them —
# leaving them in the gate's env would let it authenticate by a route no arm
# can use. GH_TOKEN/GITHUB_TOKEN are stripped for the same symmetry (arm 7).
# The probe measures the result rather than trusting this list: every probe
# emits `creds_absent`, asserted at the gate and on every dispatched arm.
STRIP_CREDS=(-u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN)

PASS=0
FAIL=0
SKIP=0
PROVEN=0        # required arms that actually OBSERVED their expected class
INCONCLUSIVE=0
REQUIRED=0      # derived from ARM_TABLE in run_arm_table(); init'd here since
                # gate-unmet paths evaluate the contract before that runs

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        pass "$name"
    else
        fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"
    fi
}

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

IS_WINDOWS=0
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1 ;; esac

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/wd-childenv-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

# Fixtures: a temp MAIN worktree (cwd for every dispatched arm), a pinned plans
# dir and workflow dir, and an empty dir used as a gh config dir with no hosts.yml.
# Only the dispatched arms need a real repo (gated on git); without git the
# directory is still created so every path below stays defined.
mk_repo() {
    local d="$1"
    mkdir -p "$d"
    [ "$HAVE_GIT" = "1" ] || return 0
    git -C "$d" init -q -b main
    git -C "$d" config user.email "test@example.com"
    git -C "$d" config user.name "Test"
    git -C "$d" config core.hooksPath /dev/null
    echo init > "$d/README.md"
    git -C "$d" add README.md 2>/dev/null
    git -C "$d" commit -q --no-verify -m initial 2>/dev/null
}

MAIN_RAW="$TMPD/mainrepo"; mk_repo "$MAIN_RAW"
PLANS_RAW="$TMPD/plans"; mkdir -p "$PLANS_RAW"
WFDIR_RAW="$TMPD/workflow"; mkdir -p "$WFDIR_RAW"
EMPTY_CFG_RAW="$TMPD/empty-gh-config"; mkdir -p "$EMPTY_CFG_RAW"

MAIN="$(nodepath "$MAIN_RAW")"
PLANS="$(nodepath "$PLANS_RAW")"
WFDIR="$(nodepath "$WFDIR_RAW")"
EMPTY_CFG="$(nodepath "$EMPTY_CFG_RAW")"

# Obvious nonsense, never a real credential — proves an undeclared parent
# variable does NOT reach a dispatched child.
FAKE_GH_TOKEN="ghp-FAKE0000-not-a-real-token"

# Sourced, not executed, so counters/fixtures/exit contract above are shared
# (rules/coding/file-split.md Pattern A — file passed the 500-line HARD limit):
#   probe-harness.sh    node probe + run_probe / pv / expect_class / trim / exit_verdict
#   stage1-deciders.sh  stage1_deciders(): classify()/exit_verdict() self-check
#   arms.sh             ARM_TABLE + run_arm_table() + run_control_arms()
TL3_PART_DIR="$(dirname "${BASH_SOURCE[0]}")/TL3-worker-dispatch-child-env-gh-auth"

# shellcheck source=./TL3-worker-dispatch-child-env-gh-auth/probe-harness.sh
. "$TL3_PART_DIR/probe-harness.sh"
# shellcheck source=./TL3-worker-dispatch-child-env-gh-auth/stage1-deciders.sh
. "$TL3_PART_DIR/stage1-deciders.sh"
# shellcheck source=./TL3-worker-dispatch-child-env-gh-auth/arms.sh
. "$TL3_PART_DIR/arms.sh"

# finish_unmet <reason> — single exit for every unmet gate (stage 1 or stage 2).
# INCONCLUSIVE is forced to 1 so the SAME self-checked exit_verdict() answers 77
# for "nothing was proved" (or 1 whenever FAIL>0, checked first inside it) —
# precedence lives in one function instead of being restated at each gate.
finish_unmet() {
    echo "SKIP: $1"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP PROVEN=$PROVEN/$REQUIRED (gate unmet)"
    exit "$(exit_verdict "$FAIL" 1 "$PROVEN" "$REQUIRED")"
}

# Stage 1 runs BEFORE every gate and outranks all of them: even an ungated,
# binary-missing, or logged-out host gets its classifier/exit-arithmetic/
# expect_class() contract checked, and a FAIL there exits 1, not a skip.
stage1_deciders

# Gate stage 1 acted on — RUN_TL3 and the binaries the arms need.
if [ "$GATE_OK" != "1" ]; then
    finish_unmet "environment gate unmet — $GATE_REASON"
fi

# Gate stage 2 — environment premise established WITHOUT the dispatcher.
# Credentials are stripped so a host authenticating purely by GH_TOKEN can't be
# mistaken for one resolving auth via a config directory; the synthetic entry
# below runs under the same condition so the two are comparable. Once this
# passes, a dispatched child that can't authenticate is a dispatcher defect.
if ! run_probe direct synthetic; then
    finish_unmet "direct (non-dispatcher) gh probe did not run to completion for $TARGET_HOST"
fi
GATE_CLASS="$(pv class)"
if [ "$GATE_CLASS" != "authenticated" ]; then
    finish_unmet "direct (non-dispatcher) gh probe is not authenticated for $TARGET_HOST — class=$GATE_CLASS status=$(pv status)"
fi
pass "gate/direct-gh-resolves-auth-without-a-token"
# Proves the gate really did authenticate credential-free, not via a token the
# dispatched arms will never see. env_site is asserted alongside it because it
# is only set by the wrapper that observed a real gh spawn — without it,
# `creds_absent` could read 1 from a child that was never started.
assert_eq "gate/runs-credential-free" "1" "$(pv creds_absent)"
assert_eq "gate/credential-check-measured-at-the-gh-child" "direct" "$(pv env_site)"

run_arm_table
run_control_arms

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP PROVEN=$PROVEN/$REQUIRED"
# Same function the exitcode/* self-checks above evaluated: the contract they
# assert is literally the contract this run obeys.
VERDICT="$(exit_verdict "$FAIL" "$INCONCLUSIVE" "$PROVEN" "$REQUIRED")"
if [ "$VERDICT" = "77" ]; then
    # Nothing disproved, but nothing proved either — claiming coverage here is
    # the failure mode this branch prevents.
    echo "SKIP: required arms did not reach a definite classification (PROVEN=$PROVEN/$REQUIRED)"
fi
exit "$VERDICT"
