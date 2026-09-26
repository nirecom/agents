#!/usr/bin/env bash
# tests/hooks/fix-enforce-worktree-gh-cross-repo.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/handle-bash-write.js
# Tags: TL1, hook, enforce, worktree, gh, issue-create, cross-repo, scope:permanent
# #1246 (via #2393): the #713 gate blocks every bare `gh issue create` from the
# main worktree, even when --repo/-R/GH_REPO names a DIFFERENT repo managed via
# ENFORCE_WORKTREE_ADDITIONAL_REPOS. F6* are RED until the gate resolves the
# target slug from each session root's origin; F1-F5 pin the unchanged edges.

set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"
# shellcheck source=tests/lib/ew-runner.sh
. "$AGENTS_DIR/tests/lib/ew-runner.sh"

T="$(make_tmp)"
trap 'rm -rf "$T"' EXIT
harness_isolate "$T/iso"

MAIN="$(np "$T/session-repo")"
OTHER="$(np "$T/other-repo")"
ew_make_repo "$MAIN"
ew_make_repo "$OTHER"
# Both URL shapes the slug normaliser must accept (https + scp-style ssh).
git -C "$MAIN" remote add origin "https://github.com/example-owner/session-repo.git"
git -C "$OTHER" remote add origin "git@github.com:example-owner/other-repo.git"
EW_CONFIG_DIR="$MAIN"
ADD="ENFORCE_WORKTREE_ADDITIONAL_REPOS=$OTHER"

run() { ew_run "$MAIN" "$(ew_bash_payload test "$1")" "${@:2}"; }

case_begin "gh-issue-create-gate-unchanged" "hooks/enforce-worktree.js"
out="$(ew_raw "$MAIN" "$(ew_bash_payload test 'gh issue create -t title -b body')" "$ADD")"
if [[ "$out" == *'"decision":"block"'* && "$out" == *'bare `gh issue create`'* ]]; then
    pass "F1. main CWD: gh issue create (no --repo) → BLOCK by the #713 skill gate"
else
    fail "F1. main CWD: gh issue create (no --repo) → BLOCK by the #713 skill gate" "got=$out"
fi
ew_expect block "F2. main CWD: --repo <unmanaged slug> → BLOCK" \
    "$(run 'gh issue create --repo example-owner/unmanaged -t title -b body' "$ADD")"
ew_expect block "F3. main CWD: --repo <CWD origin slug> → BLOCK (skill gate still applies)" \
    "$(run 'gh issue create --repo example-owner/session-repo -t title -b body' "$ADD")"
ew_expect block "F4. main CWD: --repo other-repo WITHOUT ADDITIONAL_REPOS → BLOCK" \
    "$(run 'gh issue create --repo example-owner/other-repo -t title -b body')"
ew_expect allow "F5. main CWD: ISSUE_CREATE_SKILL=1 gh issue create → ALLOW (sanctioned, regression)" \
    "$(run 'ISSUE_CREATE_SKILL=1 gh issue create -t title -b body' "$ADD")"
case_end

case_begin "gh-issue-create-cross-repo" "hooks/enforce-worktree/handle-bash-write.js"
ew_expect allow "F6a. main CWD: --repo <managed other-repo> (separate form) → ALLOW" \
    "$(run 'gh issue create --repo example-owner/other-repo -t title -b body' "$ADD")"
ew_expect allow "F6b. main CWD: -R <managed other-repo> → ALLOW" \
    "$(run 'gh issue create -R example-owner/other-repo -t title -b body' "$ADD")"
ew_expect allow "F6c. main CWD: --repo=<managed other-repo> (joined form) → ALLOW" \
    "$(run 'gh issue create --repo=example-owner/other-repo -t title -b body' "$ADD")"
ew_expect allow "F6d. main CWD: GH_REPO=<managed other-repo> gh issue create → ALLOW" \
    "$(run 'GH_REPO=example-owner/other-repo gh issue create -t title -b body' "$ADD")"
case_end

# Pattern 2 (allow-extension attacks): the cross-repo allow must not widen to a
# second, un-targeted create or to a --repo that only appears inside a value.
case_begin "gh-issue-create-cross-repo-attacks" "hooks/enforce-worktree/handle-bash-write.js"
ew_expect block "F7. main CWD: -R <managed other-repo> && bare gh issue create → BLOCK (chain)" \
    "$(run 'gh issue create -R example-owner/other-repo -t a -b b && gh issue create -t c -b d' "$ADD")"
ew_expect block "F8. main CWD: -b \"--repo <managed other-repo>\" (body injection) → BLOCK" \
    "$(run 'gh issue create -t title -b "--repo example-owner/other-repo"' "$ADD")"
case_end

echo ""
echo "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[[ "$FAIL" -eq 0 ]]
