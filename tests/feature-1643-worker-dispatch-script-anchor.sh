#!/usr/bin/env bash
# tests/feature-1643-worker-dispatch-script-anchor.sh
# Tests: bin/worker-dispatch/spawn.js, hooks/lib/worker-dispatch-registry.js, bin/worker-dispatch/workers/test-runner.js, bin/worker-dispatch/capability.js
# Tags: worker-dispatch, script-anchor, family-worktree, spawn, registry, regression, TL2, scope:issue-specific
#
# Issue #1643 — the SCRIPT anchor vocabulary (which root a declared script
# resolves against), as distinct from the TRUST anchors covered by
# tests/feature-1643-worker-dispatch-anchor.sh (that suite asserts ACD/MAIN_ROOT
# cannot be moved by caller input; this one asserts which of those roots a given
# script is measured from, and that cwd is proven before it can act as a root).
#
# The regression this file fences:
#   tests/run-all.sh derives its test directory from BASH_SOURCE, not from the
#   process cwd. While `test-runner`'s runAll script carried anchor "main-root",
#   a dispatch from a LINKED worktree resolved main's copy of the script and ran
#   MAIN's suite while reporting success — i.e. it verified the wrong tree. The
#   fix moves that one script to the "family-worktree" anchor, which resolves
#   against the cwd only AFTER assertCwdInFamily has proven it a family member.
#
# This file is a DISPATCHER. It owns the shared helpers, the fixtures and the
# counters; the group bodies live in the sibling directory of the same name and
# are sourced below (rules/coding/file-split.md Pattern A — the file passed the
# 500-line HARD limit once the #1719 buildEnv groups arrived). Every part runs in
# this shell, so PASS/FAIL and the fixture paths are shared, not re-derived.
#
#   feature-1643-worker-dispatch-script-anchor/
#     probe-harness.sh      the node probe (all modes) + the runners that plant
#                           a parent env for it
#     groups-anchor.sh      A registry / B+D resolveScript / C cwd containment /
#                           E timeout bound / F end-to-end discriminator
#     group-env-scope.sh    G buildEnv membership, both directions
#     group-env-branches.sh H missing-value branch / I value edge cases /
#                           J idempotency
#     group-child-env.sh    K real-subprocess child env (leak sentinel)
#     group-env-longvalue.sh L value-length extremes across the real subprocess
#                           boundary
#
# Groups:
#   A registry — SCRIPT_ANCHORS is the exported vocabulary; no worker may declare
#     an anchor outside it; test-runner/runAll is family-worktree, NOT main-root.
#   B resolveScript — family-worktree resolves under the passed cwd, main-root
#     under main-root, and the two differ when cwd is a linked worktree.
#   C cwd containment — scriptExists returns null and run() throws for an
#     out-of-family cwd, and run() rejects the cwd BEFORE resolving the script.
#   D anchorRoot — an unknown anchor token, and family-worktree with no cwd,
#     both yield an unresolvable-anchor error (anchorRoot returned null).
#   E timeout_seconds bound — 21600 accepted, 21601 rejected, default still 120.
#   F end-to-end discriminator — a real dispatch whose linked worktree and main
#     worktree carry DIFFERENT tests/run-all.sh must run the linked one.
#   G buildEnv child-env scope, both directions — GH_TOKEN / GITHUB_TOKEN reach
#     only the sanctioned forge workers' children (what makes the family-worktree
#     anchor of group A safe to keep), while the config-location vars reach EVERY
#     worker's children (#1719).
#   H buildEnv missing-value branch — an allowlisted var the parent does not hold
#     must be ABSENT from the child env, never materialized as "undefined" or "".
#   I config-path value edge cases — empty, single-character, nonexistent,
#     spaced, non-ASCII, shell-metacharacter and 8192-character values survive
#     byte-for-byte, unexpanded and unrun.
#   J buildEnv idempotency — two identical calls agree, and neither the allowlist
#     nor the worker's envPassthrough is mutated by calling it.
#   K real-subprocess child env — groups G–J all assert on buildEnv's RETURN
#     VALUE, which leaves the wiring between it and spawnSync unmeasured: a
#     regression to `env: process.env` inside run() keeps every one of them
#     green while handing the operator's whole environment to the dispatched
#     child. K plants an undeclared sentinel in the parent, dispatches a REAL
#     child through run(), and asks the child what it can see — with an
#     allowlisted var and a declared-passthrough arm as the paired positives.
#   L value-length extremes at that same real boundary — group I proves a
#     1-character and an 8192-character config path survive buildEnv, but length
#     only starts to matter once the value has to cross into a real child
#     (Windows caps a single variable near 32767 chars). L plants each extreme,
#     dispatches through run(), and has the child rebuild the expected bytes
#     from a rule rather than from what it received.
#
# TL3 gap (what this TL2 test does NOT catch):
#   - A real /run-tests skill invocation writing the payload and dispatching in
#     one turn against the operator's real agents checkout.
#   - Real linked worktrees behind NTFS junctions or bind mounts, where realpath
#     canonicalization of the family list behaves differently from temp fixtures.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISPATCH_JS="$AGENTS_DIR/bin/worker-dispatch.js"
SPAWN_JS="$AGENTS_DIR/bin/worker-dispatch/spawn.js"
REGISTRY_JS="$AGENTS_DIR/hooks/lib/worker-dispatch-registry.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        pass "$name"
    else
        fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"
    fi
}

# assert_ne <name> <unwanted> <got>  — negative assertion (regression fence)
assert_ne() {
    local name="$1" bad="$2" got="$3"
    if [ "$bad" != "$got" ]; then
        pass "$name"
    else
        fail "$name — got the forbidden value $(printf '%q' "$bad")"
    fi
}

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

impl_missing() {
    if [ -f "$2" ]; then return 1; fi
    fail "$1 — implementation missing: $3"
    return 0
}

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/wd-scriptanchor-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

mk_repo() {
    local d="$1"
    mkdir -p "$d"
    git -C "$d" init -q -b main
    git -C "$d" config user.email "test@example.com"
    git -C "$d" config user.name "Test"
    git -C "$d" config core.hooksPath /dev/null
    echo init > "$d/README.md"
    git -C "$d" add README.md 2>/dev/null
    git -C "$d" commit -q --no-verify -m initial 2>/dev/null
}

# ---------------------------------------------------------------------------
# Fixtures: a real main worktree + a real linked worktree (the family), an
# unrelated repo, and a plain directory. Main and linked carry tests/run-all.sh
# with DIFFERENT marker text — that difference is the whole discriminator.
# ---------------------------------------------------------------------------
MAIN_RAW="$TMPD/mainrepo"; mk_repo "$MAIN_RAW"
mkdir -p "$MAIN_RAW/tests"
printf '#!/usr/bin/env bash\necho "Results: MAIN-SUITE 1 passed"\nexit 0\n' > "$MAIN_RAW/tests/run-all.sh"
chmod +x "$MAIN_RAW/tests/run-all.sh"
git -C "$MAIN_RAW" add tests/run-all.sh 2>/dev/null
git -C "$MAIN_RAW" commit -q --no-verify -m "add run-all" 2>/dev/null

LINKED_RAW="$TMPD/linked-wt"
git -C "$MAIN_RAW" worktree add -q -b feature/script-anchor-probe "$LINKED_RAW" >/dev/null 2>&1
printf '#!/usr/bin/env bash\necho "Results: LINKED-SUITE 1 passed"\nexit 0\n' > "$LINKED_RAW/tests/run-all.sh"
chmod +x "$LINKED_RAW/tests/run-all.sh"

ALT_RAW="$TMPD/altrepo"; mk_repo "$ALT_RAW"
mkdir -p "$ALT_RAW/tests"
printf '#!/usr/bin/env bash\necho "Results: ALT-SUITE"\nexit 0\n' > "$ALT_RAW/tests/run-all.sh"

OUTSIDE_RAW="$TMPD/outside"; mkdir -p "$OUTSIDE_RAW/tests"
printf '#!/usr/bin/env bash\necho "Results: OUTSIDE-SUITE"\nexit 0\n' > "$OUTSIDE_RAW/tests/run-all.sh"

# Both halves of the plans/workflow pair are pinned into the temp tree, never one
# of the two: rules/test/fixture-isolation.md — a probe that pins only one leaks
# supervisor appends into the developer's real ~/.workflow-plans.
PLANS_RAW="$TMPD/plans"; mkdir -p "$PLANS_RAW"
WFDIR_RAW="$TMPD/workflow"; mkdir -p "$WFDIR_RAW"

MAIN="$(nodepath "$MAIN_RAW")"
LINKED="$(nodepath "$LINKED_RAW")"
ALT="$(nodepath "$ALT_RAW")"
OUTSIDE="$(nodepath "$OUTSIDE_RAW")"
PLANS="$(nodepath "$PLANS_RAW")"
WFDIR="$(nodepath "$WFDIR_RAW")"

# ---------------------------------------------------------------------------
# Parts. Sourced, not executed: they define the group functions and the probe
# harness in THIS shell so they share the counters and the fixtures above.
# ---------------------------------------------------------------------------
PART_DIR="$(dirname "${BASH_SOURCE[0]}")/feature-1643-worker-dispatch-script-anchor"

# shellcheck source=./feature-1643-worker-dispatch-script-anchor/probe-harness.sh
. "$PART_DIR/probe-harness.sh"
# shellcheck source=./feature-1643-worker-dispatch-script-anchor/groups-anchor.sh
. "$PART_DIR/groups-anchor.sh"
# shellcheck source=./feature-1643-worker-dispatch-script-anchor/group-env-scope.sh
. "$PART_DIR/group-env-scope.sh"
# shellcheck source=./feature-1643-worker-dispatch-script-anchor/group-env-branches.sh
. "$PART_DIR/group-env-branches.sh"
# shellcheck source=./feature-1643-worker-dispatch-script-anchor/group-child-env.sh
. "$PART_DIR/group-child-env.sh"
# shellcheck source=./feature-1643-worker-dispatch-script-anchor/group-env-longvalue.sh
. "$PART_DIR/group-env-longvalue.sh"

if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_WD1643_SCRIPTANCHOR_INNER:-}" ]; then
        _WD1643_SCRIPTANCHOR_INNER=1 timeout 240 bash "$0" "$@"
        exit $?
    fi
fi

group_a
group_bd
group_c
group_e
group_f
group_g
group_h
group_i
group_j
group_k
group_l

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
