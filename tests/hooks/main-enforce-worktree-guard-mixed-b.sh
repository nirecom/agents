#!/bin/bash
# tests/hooks/main-enforce-worktree-guard-mixed-b.sh
# Tests: hooks/enforce-worktree.js
# Tags: TL2, worktree, enforce, hook, bin, git, pre-commit, scope:common, enforce-worktree, workflow, supervisor, orphan-cwd, bash-c, fail-closed, context-populate, block-extras, axis-a, env, shell, windows, tests, merge, cross-repo, issue-525, feature-885, dup-group-keep:time-hard-limit, test-lang-exception:e2e
# One of the main-enforce-worktree-guard-<group>.sh entrypoints; tests/lib/mewg-groups.sh maps
# the fragments in tests/hooks/main-enforce-worktree-guard/ to groups (split for per-test time).
# TL3 gap: cases feed hand-built stdin to `node hooks/enforce-worktree.js`, so a dropped
# settings.json registration or a diverged host payload shape stays green. Covered elsewhere:
# tests/hooks/fix-1780-round4-write-tool-parity.sh section R (static registration) and
# bin/check-verification-gate.sh category hook-registration.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MEWG_GROUP="mixed-b"

# Shared harness first (root decoy, run root, command guard); mewg-harness.sh below redefines pass/fail/skip.
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

MEWG_TMP_ROOT="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'mewg-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$MEWG_TMP_ROOT" ] && MEWG_TMP_ROOT="$(mktemp -d)"
readonly MEWG_TMP_ROOT
TMPDIR_BASE="$MEWG_TMP_ROOT"
trap 'rm -rf "$MEWG_TMP_ROOT"' EXIT

# rules/test/fixture-isolation.md: pin the workflow dir and the plans dir as a PAIR.
export WORKFLOW_STATE_DIR="$TMPDIR_BASE/workflow"
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/workflow-plans"
mkdir -p "$WORKFLOW_STATE_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_CODE_SESSION_ID

# shellcheck source=tests/lib/mewg-harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/mewg-harness.sh"
# shellcheck source=tests/lib/mewg-groups.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/mewg-groups.sh"

if mewg_static_check "$MEWG_GROUP"; then
    for _mewg_f in $(mewg_fragments_of "$MEWG_GROUP"); do
        # shellcheck source=/dev/null
        . "$FRAGMENT_DIR/$_mewg_f"
    done
    mewg_group_verify "$MEWG_GROUP"
fi

echo ""
# Deliberately not the `PASS: `/`FAIL: `/`SKIP: ` prefixes — those are reserved
# for case lines, and run-all's tallies would count this summary as three cases.
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
