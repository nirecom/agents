#!/usr/bin/env bash
# tests/hooks/fix-enforce-worktree-worktree-remove-linked.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/handle-bash-write.js
# Tags: TL1, hook, enforce, worktree, worktree-remove, linked, scope:common
# #838 (via #2393): `git -C <main> worktree remove <wt2>` is gated on
# isMainCheckout(CWD), so a session standing in a linked worktree cannot clean up
# a sibling worktree even with an explicit -C at the main checkout. D1/D1b are
# RED until the gate keys on the -C target; D2-D6 pin the boundaries.

set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"
# shellcheck source=tests/lib/ew-runner.sh
. "$AGENTS_DIR/tests/lib/ew-runner.sh"

T="$(make_tmp)"
trap 'rm -rf "$T"' EXIT
harness_isolate "$T/iso"

MAIN="$(np "$T/main")"
LINKED="$(np "$T/wt-linked")"
VICTIM="$(np "$T/wt-victim")"
OTHER="$(np "$T/other")"
ew_make_repo "$MAIN"
ew_make_repo "$OTHER"
git -C "$MAIN" worktree add -q -b feature/foo "$LINKED"
git -C "$MAIN" worktree add -q -b feature/victim "$VICTIM"
EW_CONFIG_DIR="$MAIN"

run() { ew_run "$1" "$(ew_bash_payload test "$2")"; }

case_begin "worktree-remove-from-linked" "hooks/enforce-worktree/handle-bash-write.js"
ew_expect allow "D1. linked CWD: git -C <main> worktree remove <sibling> → ALLOW" \
    "$(run "$LINKED" "git -C \"$MAIN\" worktree remove \"$VICTIM\"")"
ew_expect allow "D1b. linked CWD: git -C <main> worktree prune → ALLOW" \
    "$(run "$LINKED" "git -C \"$MAIN\" worktree prune")"
case_end

case_begin "worktree-remove-from-main-regression" "hooks/enforce-worktree.js"
ew_expect allow "D2. main CWD: git -C <main> worktree remove <sibling> → ALLOW (regression)" \
    "$(run "$MAIN" "git -C \"$MAIN\" worktree remove \"$VICTIM\"")"
case_end

case_begin "worktree-remove-boundaries" "hooks/enforce-worktree/handle-bash-write.js"
ew_expect block "D3. linked CWD: git worktree remove <sibling> without -C → BLOCK" \
    "$(run "$LINKED" "git worktree remove \"$VICTIM\"")"
ew_expect block "D4. linked CWD: git -C <unrelated-repo> worktree remove → BLOCK" \
    "$(run "$LINKED" "git -C \"$OTHER\" worktree remove \"$VICTIM\"")"
ew_expect block "D5. linked CWD: git -C <linked> worktree remove <sibling> → BLOCK (-C is not main)" \
    "$(run "$LINKED" "git -C \"$LINKED\" worktree remove \"$VICTIM\"")"
ew_expect block "D6. linked CWD: git -C <main> worktree remove --force <sibling> → BLOCK" \
    "$(run "$LINKED" "git -C \"$MAIN\" worktree remove --force \"$VICTIM\"")"
ew_expect block "D7. linked CWD: git -C <main> worktree remove <sibling> && git -C <main> commit → BLOCK (chain)" \
    "$(run "$LINKED" "git -C \"$MAIN\" worktree remove \"$VICTIM\" && git -C \"$MAIN\" commit -m x")"
ew_expect block "D7b. linked CWD: git -C <main> worktree prune && git -C <main> commit → BLOCK (chain)" \
    "$(run "$LINKED" "git -C \"$MAIN\" worktree prune && git -C \"$MAIN\" commit -m x")"
case_end

echo ""
echo "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[[ "$FAIL" -eq 0 ]]
