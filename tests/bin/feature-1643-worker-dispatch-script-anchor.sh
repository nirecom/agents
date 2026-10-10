#!/usr/bin/env bash
# tests/bin/feature-1643-worker-dispatch-script-anchor.sh
# Tests: bin/worker-dispatch/spawn.js, hooks/lib/worker-dispatch-registry.js, bin/worker-dispatch/workers/test-runner.js, bin/worker-dispatch/capability.js
# Tags: worker-dispatch, script-anchor, family-worktree, spawn, registry, regression, TL2, scope:issue-specific
# Issue #1643 — the SCRIPT anchor vocabulary: which root a declared script is measured from, and that cwd is proven before it acts as a root (trust anchors: feature-1643-worker-dispatch-anchor.sh).
# Regression fenced: test-runner's runAll was anchored at the target main worktree, so a dispatch from a LINKED worktree ran MAIN's suite and reported success; "family-worktree" resolves against cwd only after assertCwdInFamily.
# DISPATCHER only (rules/coding/file-split.md Pattern A): groups live in the sibling dir, sourced below, sharing this shell's state; each group's rationale lives with its code.
#   probe-harness.sh node probe; groups-anchor.sh A registry / B+D resolveScript / C cwd containment / E timeout / F end-to-end;
#   group-env-scope.sh G membership; group-env-branches.sh H/I/J values; group-child-env.sh K real child env; group-env-longvalue.sh L value length.
# TL3 gap: a real /run-tests dispatch against the operator's checkout, and worktrees behind NTFS junctions or bind mounts.
# Mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DISPATCH_JS="$SCRIPT_CHECKOUT_ROOT/bin/worker-dispatch.js"
SPAWN_JS="$SCRIPT_CHECKOUT_ROOT/bin/worker-dispatch/spawn.js"
REGISTRY_JS="$SCRIPT_CHECKOUT_ROOT/hooks/lib/worker-dispatch-registry.js"

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

# Fixtures: a real main worktree + a real linked worktree (the family), an
# unrelated repo, and a plain directory. Main and linked carry tests/run-all.sh
# with DIFFERENT marker text — that difference is the whole discriminator.
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

# Both halves of the plans/workflow pair pinned into the temp tree (never just
# one — rules/test/fixture-isolation.md): pinning only one leaks supervisor
# appends into the developer's real ~/.workflow-plans.
PLANS_RAW="$TMPD/plans"; mkdir -p "$PLANS_RAW"
WFDIR_RAW="$TMPD/workflow"; mkdir -p "$WFDIR_RAW"

MAIN="$(nodepath "$MAIN_RAW")"
LINKED="$(nodepath "$LINKED_RAW")"
ALT="$(nodepath "$ALT_RAW")"
OUTSIDE="$(nodepath "$OUTSIDE_RAW")"
PLANS="$(nodepath "$PLANS_RAW")"
WFDIR="$(nodepath "$WFDIR_RAW")"

# Parts. Sourced, not executed: define the group functions and probe harness
# in THIS shell so they share the counters and fixtures above.
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
