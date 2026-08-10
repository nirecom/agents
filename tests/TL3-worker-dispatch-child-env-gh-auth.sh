#!/usr/bin/env bash
# tests/TL3-worker-dispatch-child-env-gh-auth.sh
# Tests: bin/worker-dispatch/spawn.js, hooks/lib/worker-dispatch-registry.js
# Tags: worker-dispatch, child-env, config-path, gh-cli, auth-resolution, real-environment, TL3, scope:common
#
# TL3 — one real seam: the env buildEnv() assembles, measured by the real `gh`
# binary resolving its OWN config directory. #1719 was invisible to every layer
# below this one because buildEnv() copies strings correctly; what it got wrong
# was WHICH strings, and only gh can answer whether the surviving set still
# names the config directory the parent reads.
#
# Why not tests/TL3-worker-dispatch-gh-contract.sh: that file's concern is gh's
# FLAG SURFACE and its gate is "does a gh binary exist". This file's concern is
# AUTH REACHABILITY and its gate is "can this host resolve auth for the target
# host through a config directory". Sharing a file would drag the flag-surface
# coverage down to the stricter gate on every host that is not logged in.
#
# Gate and subject are deliberately separate. The gate is a DIRECT
# child_process.spawnSync of gh — the dispatcher is not involved. Gating on a
# dispatched result would let the very regression this file exists to catch read
# as "the environment is not ready" and skip instead of report.
#
# ProgramData / PROGRAMDATA are out of scope here: they serve Windows OpenSSH
# known-hosts resolution, not gh's config chain, so no gh probe can move on
# them. The structural and behavioural layers fence those two.
#
# Secrecy: gh runs only inside the node probe, whose stdout/stderr are piped into
# the probe process, classified IN MEMORY, and discarded. Nothing but a
# classification token and a numeric exit code crosses back into this shell, and
# no gh output is ever written to disk.
#
# Both a SYNTHETIC entry and a REAL registry entry are exercised, and both are
# required. The synthetic entry (envPassthrough: []) isolates the config path,
# but on its own it would let the file go green while every actually-registered
# gh worker was broken — the registry entry is what the operator really runs, so
# it carries its own required arm rather than an optional one.
#
# Arm table (required arms are the ones counted into PROVEN):
#   stage1  classify() + exit_verdict() on SYNTHETIC inputs   ALWAYS runs, gate
#                                                             or no gate; a FAIL
#                                                             here exits 1
#   gate    direct spawnSync, no dispatcher              required to proceed
#                                                        (else 77, unless FAIL)
#   1       dispatch, synthetic, inherited env           REQUIRED  authenticated
#   2       dispatch, synthetic, GH_CONFIG_DIR=<empty>   REQUIRED  unauthenticated
#   3       dispatch, synthetic, XDG_CONFIG_HOME=<empty> REQUIRED  unauthenticated
#   4       dispatch, synthetic, APPDATA=<empty>         REQUIRED on Windows only
#   5       direct, fake GH_TOKEN                        control, premise for arm 6
#   6       dispatch, synthetic, fake GH_TOKEN           optional  authenticated
#   7       dispatch, REAL issue-reconcile entry         REQUIRED  authenticated
#
# Arms 1-4 and 7 are DATA: one row each in ARM_TABLE, driven by a single loop,
# with the platform applicability of arm 4 carried in a column rather than in a
# hand-written branch. REQUIRED is derived by counting the applicable required
# rows, so it can never disagree with the table.
#
# Exit contract (exit_verdict(), self-checked on synthetic counters in stage 1),
# in strict precedence order:
#   1. FAIL > 0                                   -> 1
#   2. INCONCLUSIVE != 0 or PROVEN < REQUIRED     -> 77
#   3. otherwise                                  -> 0
# A failing deterministic assert outranks EVERY gate: no gate — not RUN_TL3, not
# a missing binary, not an unauthenticated host — may short-circuit past it. An
# all-inconclusive run must never read as a pass either.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------------------------------------------------------------------------
# Environment gate — EVALUATED here, ACTED ON only after stage 1.
#
# An `exit 77` at this point is the false-green path: it would let a broken
# classify(), a broken exit_verdict() or a broken expect_class() leave the whole
# file reading green-as-skipped on every ungated or unauthenticated host, which
# is precisely where those three deciders are load-bearing. They are pure logic
# — no gh, no network, no login — so they run first and unconditionally, and the
# gate governs only the environment-dependent arms below them.
# ---------------------------------------------------------------------------
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

# node and git are tracked by name rather than folded into GATE_REASON alone:
# stage 1 needs node for the classify() self-check (and only for that), and the
# git fixtures below exist solely for the dispatched arms.
HAVE_NODE=1; command -v node >/dev/null 2>&1 || HAVE_NODE=0
HAVE_GIT=1; command -v git >/dev/null 2>&1 || HAVE_GIT=0
[ "$HAVE_NODE" = "1" ] || gate_unmet "node is not on PATH"
[ "$HAVE_GIT" = "1" ] || gate_unmet "git is not on PATH"
command -v gh >/dev/null 2>&1 || gate_unmet "gh is not on PATH"

# One host, fixed. A bare `gh auth status` inspects every known host and account
# and exits non-zero if any single stale account is broken, which would suppress
# the whole file for a reason that has nothing to do with the dispatcher.
#
# An ambient GH_HOST only SELECTS which host this run is about; it is then pinned
# back into the env of EVERY probe below (see run_probe), so the gate and the
# dispatched arms can never end up asking about different hosts because one of
# them inherited a value the other did not.
TARGET_HOST="${GH_HOST:-github.com}"

# Credentials stripped from the parent env of every probe — gate included.
#
# The gate is a DIRECT spawn and the arms go through the dispatcher, so the
# comparison between them only means anything if both run under IDENTICAL
# credential conditions. GH_ENTERPRISE_TOKEN / GITHUB_ENTERPRISE_TOKEN are on
# this list because they appear in NEITHER CHILD_ENV_ALLOWLIST NOR any worker's
# envPassthrough (checked against hooks/lib/worker-dispatch-registry.js): a
# dispatched child can never hold them, so leaving them in the gate's env would
# let the gate authenticate by a route no arm can use and make every arm look
# like a dispatcher defect. GH_TOKEN / GITHUB_TOKEN are declared by the forge
# workers, and are stripped for the same symmetry reason — see arm 7.
#
# The probe measures the result rather than trusting this list: every probe
# emits `creds_absent`, asserted at the gate and on every dispatched arm.
STRIP_CREDS=(-u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN)

PASS=0
FAIL=0
SKIP=0
# PROVEN counts required arms that actually OBSERVED their expected class.
PROVEN=0
INCONCLUSIVE=0
# Derived from ARM_TABLE in run_arm_table(). Initialised here because the
# gate-unmet paths report and evaluate the contract before that ever runs.
REQUIRED=0

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

# ---------------------------------------------------------------------------
# Fixtures: a temp MAIN worktree (cwd for every dispatched arm), a pinned plans
# dir and workflow dir, and one empty directory used as a gh config dir that
# demonstrably holds no hosts.yml.
# ---------------------------------------------------------------------------
# Only the dispatched arms need a real repo, and those are gated on git anyway.
# Without git the directory is still created so every path below stays defined.
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

# Obvious nonsense, never a real credential. Used only to prove that an
# undeclared parent variable does NOT reach a dispatched child.
FAKE_GH_TOKEN="ghp-FAKE0000-not-a-real-token"

# ---------------------------------------------------------------------------
# Parts. Sourced, not executed: they define the probe harness and the stage
# bodies in THIS shell, so the counters, the fixtures and the exit contract
# above are shared rather than re-derived (rules/coding/file-split.md Pattern A
# — this file passed the 500-line HARD limit once the #1719 classifier
# self-checks and the arm table arrived).
#
#   probe-harness.sh    the node probe (all modes) + run_probe / pv /
#                       expect_class / trim / exit_verdict
#   stage1-deciders.sh  stage1_deciders(): classify() and exit_verdict() on
#                       synthetic inputs, checked before any gh runs
#   arms.sh             ARM_TABLE + run_arm_table() + run_control_arms()
# ---------------------------------------------------------------------------
TL3_PART_DIR="$(dirname "${BASH_SOURCE[0]}")/TL3-worker-dispatch-child-env-gh-auth"

# shellcheck source=./TL3-worker-dispatch-child-env-gh-auth/probe-harness.sh
. "$TL3_PART_DIR/probe-harness.sh"
# shellcheck source=./TL3-worker-dispatch-child-env-gh-auth/stage1-deciders.sh
. "$TL3_PART_DIR/stage1-deciders.sh"
# shellcheck source=./TL3-worker-dispatch-child-env-gh-auth/arms.sh
. "$TL3_PART_DIR/arms.sh"

# finish_unmet <reason> — the single exit for every unmet gate, stage 1 gate and
# stage 2 gate alike.
#
# INCONCLUSIVE is forced to 1, so the SAME self-checked exit_verdict() the normal
# path uses answers 77 for "nothing was proved" — and 1 whenever FAIL > 0,
# because that check comes first inside it. Precedence therefore lives in one
# function rather than being restated (and possibly contradicted) at each gate.
finish_unmet() {
    echo "SKIP: $1"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP PROVEN=$PROVEN/$REQUIRED (gate unmet)"
    exit "$(exit_verdict "$FAIL" 1 "$PROVEN" "$REQUIRED")"
}

# Stage 1 runs BEFORE every gate on purpose, and its result outranks all of them:
# a host that is ungated, missing a binary, or simply not logged in still gets
# its classifier, its exit arithmetic and its expect_class() contract checked,
# and a FAIL among them exits 1 rather than being converted into a skip.
stage1_deciders

# ===========================================================================
# Gate stage 1 acted on — RUN_TL3 and the binaries the arms need.
# ===========================================================================
if [ "$GATE_OK" != "1" ]; then
    finish_unmet "environment gate unmet — $GATE_REASON"
fi

# ===========================================================================
# Gate stage 2 — the environment premise, established WITHOUT the dispatcher.
#
# Credentials are stripped so that a host authenticating purely by GH_TOKEN
# cannot be mistaken for a host that resolves auth through a config directory.
# The synthetic entry below runs under the same condition, so the two are
# comparable. Once this passes, a dispatched child that cannot authenticate is a
# dispatcher defect, not an unready machine.
# ===========================================================================
if ! run_probe direct synthetic; then
    finish_unmet "direct (non-dispatcher) gh probe did not run to completion for $TARGET_HOST"
fi
GATE_CLASS="$(pv class)"
if [ "$GATE_CLASS" != "authenticated" ]; then
    finish_unmet "direct (non-dispatcher) gh probe is not authenticated for $TARGET_HOST — class=$GATE_CLASS status=$(pv status)"
fi
pass "gate/direct-gh-resolves-auth-without-a-token"
# The gate really did run credential-free, so "the gate authenticated" cannot
# mean "the gate had a token the dispatched arms will never be given".
#
# Measured on the env object handed to spawnSync for the gh child at THIS
# site — the direct one, which passes the probe's own env straight through.
# env_site is asserted alongside it because it is only ever set by the wrapper
# that observed a real gh spawn: without it, `creds_absent` could read 1 from a
# child that was never started.
assert_eq "gate/runs-credential-free" "1" "$(pv creds_absent)"
assert_eq "gate/credential-check-measured-at-the-gh-child" "direct" "$(pv env_site)"

run_arm_table
run_control_arms

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP PROVEN=$PROVEN/$REQUIRED"
# The same function the exitcode/* self-checks above evaluated, so the contract
# they assert is literally the contract this run obeys.
VERDICT="$(exit_verdict "$FAIL" "$INCONCLUSIVE" "$PROVEN" "$REQUIRED")"
if [ "$VERDICT" = "77" ]; then
    # Nothing was disproved, but nothing was proved either. Claiming coverage
    # here is the failure mode this branch exists to prevent.
    echo "SKIP: required arms did not reach a definite classification (PROVEN=$PROVEN/$REQUIRED)"
fi
exit "$VERDICT"
