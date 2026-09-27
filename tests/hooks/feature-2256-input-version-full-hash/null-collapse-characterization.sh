#!/usr/bin/env bash
# tests/hooks/feature-2256-input-version-full-hash/null-collapse-characterization.sh
# Tests: hooks/lib/diff-fingerprint.js
# Tags: supervisor, input-version, null-collapse, characterization, CPR-ORTH, TL2, scope:issue-specific
# #2323 C3 scenario 10 — characterization lock: computeInputVersion collapses every
# code-side "cannot resolve" cause to one indistinguishable null (the symmetric signal
# the #2323 selfRecovering predicate keys off). Code-change-free; passes before + after.
# Parent: tests/hooks/feature-2256-input-version-full-hash.sh
# TL3 gap (not caught here): a real detached-HEAD / shallow-clone checkout on a CI host
# — fixtures reach null via missing merge base / non-repo, not those exact git states.

set -uo pipefail
# shellcheck source=./_common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

# Direct call so an actual null / undefined cwd (not the string "null") reaches the fn.
null_iv() {
    ARG="$1" node -e "
const fp = require('$FP_NODE');
const arg = process.env.ARG === 'NULL' ? null : (process.env.ARG === 'UNDEF' ? undefined : process.env.ARG);
const v = fp.computeInputVersion(arg);
process.stdout.write(v === null || v === undefined ? 'null' : String(v));
" 2>&1
}

# A repo whose HEAD has no protected-branch (main/master) ancestor: resolveMergeBase
# returns null, so computeInputVersion collapses to null. mk_repo always makes main.
mk_no_merge_base_repo() {
    local dir="$WORK/nomergebase"
    mkdir -p "$dir"
    git -C "$dir" init -q -b work
    git -C "$dir" config core.hooksPath /dev/null
    git -C "$dir" config core.autocrlf false
    git -C "$dir" config commit.gpgsign false
    git -C "$dir" config user.email t@example.invalid
    git -C "$dir" config user.name tester
    printf 'seed\n' > "$dir/seed.txt"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m seed
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$dir"; else printf '%s' "$dir"; fi
}

# --- 1: (a) a null cwd collapses to null ---
assert_eq "1: a null cwd returns null" "$(null_iv NULL)" "null"

# --- 2: (a') an undefined cwd collapses to null ---
assert_eq "2: an undefined cwd returns null" "$(null_iv UNDEF)" "null"

# --- 3: (b) an empty-string cwd collapses to null ---
assert_eq "3: an empty-string cwd returns null" "$(fp computeInputVersion "")" "null"

# --- 4: (c) a non-existent cwd collapses to null ---
assert_eq "4: a non-existent cwd returns null" \
    "$(fp computeInputVersion "$WORK_NODE/does-not-exist-$$")" "null"

# --- 5: (d) a directory that is not a git repo collapses to null ---
mkdir -p "$WORK/plain"
printf 'x\n' > "$WORK/plain/f.txt"
if command -v cygpath >/dev/null 2>&1; then PLAIN_NODE="$(cygpath -m "$WORK/plain")"; else PLAIN_NODE="$WORK/plain"; fi
assert_eq "5: a non-git directory returns null" "$(fp computeInputVersion "$PLAIN_NODE")" "null"

# --- 6: (e) a repo with no protected-branch merge base collapses to null ---
NOMB="$(mk_no_merge_base_repo)"
assert_eq "6: a repo with no resolvable merge base returns null" \
    "$(fp computeInputVersion "$NOMB")" "null"

# --- 7: anchor — a resolvable repo still yields a full 64-hex digest, so the null
# assertions above are meaningful (the harness CAN produce a non-null result) ---
OKREPO="$(mk_repo okmb)"
assert_match "7: a resolvable repo yields a full 64-hex digest (null is not vacuous)" \
    "$(fp computeInputVersion "$OKREPO")" '^[0-9a-f]{64}$'

# --- 8: every distinct null cause yields the SAME value (indistinguishable null) ---
a="$(null_iv NULL)"; b="$(fp computeInputVersion "")"; c="$(fp computeInputVersion "$NOMB")"
if [ "$a" = "$b" ] && [ "$b" = "$c" ] && [ "$a" = "null" ]; then
    pass "8: null cwd, empty cwd and missing-merge-base all collapse to one identical null"
else
    fail "8: null cwd, empty cwd and missing-merge-base all collapse to one identical null" \
        "got '$a' / '$b' / '$c'"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
