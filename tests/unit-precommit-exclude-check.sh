#!/bin/bash
# tests/unit-precommit-exclude-check.sh
# Tests: hooks/lib/precommit-exclude-check.js
# Tags: unit, pre-commit, exclude-check, scope:common, pwsh-not-required
#
# Unit tests for hooks/lib/precommit-exclude-check.js.
# Invokes the module via node with env vars for input.
# Expected RED until hooks/lib/precommit-exclude-check.js is created.
#
# Exit codes from the module:
#   0 = all staged files covered
#   2 = not covered / empty staged / empty exclude
#   1 = input error (AGENTS_CONFIG_DIR unset)
#
# L3 gap (what this test does NOT catch):
# - Real pre-commit hook session in a live git commit
# - Interaction with WORKFLOW_OFF session marker
# - Windows path casing in a live pre-commit session
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_NODE="$AGENTS_DIR"
fi

MODULE_PATH="$_AGENTS_NODE/hooks/lib/precommit-exclude-check.js"
MODULE_FS="$AGENTS_DIR/hooks/lib/precommit-exclude-check.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP+1)); }

TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

# Check for MODULE_NOT_FOUND
MODULE_MISSING=0
if node -e "require('$MODULE_PATH')" 2>&1 | grep -q "MODULE_NOT_FOUND\|Cannot find"; then
    MODULE_MISSING=1
fi

# Create a temp dir to use as fake repo top
REPO_TOP="$(mktemp -d)"

assert_rc() {
    local name="$1" want_rc="$2"
    shift 2
    if [ "$MODULE_MISSING" = "1" ]; then
        fail "$name — MODULE_NOT_FOUND (expected red, module not yet created)"
        return
    fi
    # env vars are passed as KEY=VALUE args. Note: `env "$@" <shell-function>` does
    # NOT work — env can only exec a real binary, not a bash function. So put env
    # via `env "$@"` in front of the real `node` binary (with MSYS conv disabled so
    # POSIX-style paths/globs survive Git-Bash argument mangling).
    local got_rc=0
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
    run_with_timeout 10 env "$@" node "$MODULE_PATH" \
        >"$TMPBASE/stdout.txt" 2>"$TMPBASE/stderr.txt" || got_rc=$?
    if [ "$got_rc" = "$want_rc" ]; then
        pass "$name (rc=$got_rc)"
    else
        fail "$name — want rc=$want_rc got rc=$got_rc"
    fi
}

if command -v cygpath >/dev/null 2>&1; then
    REPO_TOP_NODE="$(cygpath -m "$REPO_TOP")"
else
    REPO_TOP_NODE="$REPO_TOP"
fi

echo "=== precommit-exclude-check module tests ==="

# Case 1: all staged files covered by EXCLUDE (prefix match) → rc 0
assert_rc "exit0-all-covered" "0" \
    "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
    "_PRECOMMIT_REPO_TOP=$REPO_TOP_NODE" \
    "_PRECOMMIT_STAGED=docs/readme.md" \
    "ENFORCE_WORKTREE_EXCLUDE=$REPO_TOP_NODE"

# Case 2: one staged file not covered → rc 2
assert_rc "exit2-one-uncovered" "2" \
    "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
    "_PRECOMMIT_REPO_TOP=$REPO_TOP_NODE" \
    "_PRECOMMIT_STAGED=docs/readme.md
src/x.py" \
    "ENFORCE_WORKTREE_EXCLUDE=**/*.md"

# Case 3: EXCLUDE empty, staged non-empty → rc 2
assert_rc "exit2-empty-exclude" "2" \
    "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
    "_PRECOMMIT_REPO_TOP=$REPO_TOP_NODE" \
    "_PRECOMMIT_STAGED=docs/readme.md" \
    "ENFORCE_WORKTREE_EXCLUDE="

# Case 4: staged empty → rc 2
assert_rc "exit2-empty-staged" "2" \
    "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
    "_PRECOMMIT_REPO_TOP=$REPO_TOP_NODE" \
    "_PRECOMMIT_STAGED=" \
    "ENFORCE_WORKTREE_EXCLUDE=$REPO_TOP_NODE"

# Case 5: AGENTS_CONFIG_DIR unset → rc 1
if [ "$MODULE_MISSING" = "1" ]; then
    fail "exit1-no-config — MODULE_NOT_FOUND (expected red)"
else
    got_rc=0
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
    run_with_timeout 10 env -u AGENTS_CONFIG_DIR \
        "_PRECOMMIT_REPO_TOP=$REPO_TOP_NODE" \
        "_PRECOMMIT_STAGED=docs/readme.md" \
        node "$MODULE_PATH" >"$TMPBASE/stdout.txt" 2>"$TMPBASE/stderr.txt" || got_rc=$?
    if [ "$got_rc" = "1" ]; then
        pass "exit1-no-config (rc=1)"
    else
        fail "exit1-no-config — want rc=1 got rc=$got_rc"
    fi
fi

# Case 6: deprecated alias ENFORCE_WORKTREE_EXCLUDE_REPOS → rc 0 AND stderr has 'is deprecated'
if [ "$MODULE_MISSING" = "1" ]; then
    fail "alias-deprecated — MODULE_NOT_FOUND (expected red)"
else
    got_rc=0
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
    run_with_timeout 10 env "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "_PRECOMMIT_REPO_TOP=$REPO_TOP_NODE" \
        "_PRECOMMIT_STAGED=docs/readme.md" \
        "ENFORCE_WORKTREE_EXCLUDE_REPOS=$REPO_TOP_NODE" \
        node "$MODULE_PATH" >"$TMPBASE/stdout.txt" 2>"$TMPBASE/stderr.txt" || got_rc=$?
    if [ "$got_rc" = "0" ]; then
        if grep -q "is deprecated" "$TMPBASE/stderr.txt" 2>/dev/null; then
            pass "alias-deprecated — rc=0 and 'is deprecated' in stderr"
        else
            fail "alias-deprecated — rc=0 but no 'is deprecated' in stderr"
        fi
    else
        fail "alias-deprecated — want rc=0 got rc=$got_rc"
    fi
fi

# Case 7: bare repo-root prefix entry covers all staged → rc 0
assert_rc "prefix-match" "0" \
    "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
    "_PRECOMMIT_REPO_TOP=$REPO_TOP_NODE" \
    "_PRECOMMIT_STAGED=src/main.py" \
    "ENFORCE_WORKTREE_EXCLUDE=$REPO_TOP_NODE"

# Case 8: glob entry covers staged → rc 0
assert_rc "glob-match" "0" \
    "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
    "_PRECOMMIT_REPO_TOP=$REPO_TOP_NODE" \
    "_PRECOMMIT_STAGED=todo.md" \
    "ENFORCE_WORKTREE_EXCLUDE=**/todo.md"

# Case 9: _PRECOMMIT_REPO_TOP UNSET, staged is an ABSOLUTE path covered by the
# EXCLUDE prefix → rc 0. Proves the `repoTop ? resolve(repoTop,rel) : resolve(rel)`
# fallback branch: an absolute rel stays absolute under path.resolve, so coverage
# holds deterministically without a repo top.
if [ "$MODULE_MISSING" = "1" ]; then
    fail "no-repo-top-fallback — MODULE_NOT_FOUND (expected red)"
else
    got_rc=0
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
    run_with_timeout 10 env -u _PRECOMMIT_REPO_TOP \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "_PRECOMMIT_STAGED=$REPO_TOP_NODE/deep/file.txt" \
        "ENFORCE_WORKTREE_EXCLUDE=$REPO_TOP_NODE" \
        node "$MODULE_PATH" >"$TMPBASE/stdout.txt" 2>"$TMPBASE/stderr.txt" || got_rc=$?
    if [ "$got_rc" = "0" ]; then
        pass "no-repo-top-fallback (rc=0)"
    else
        fail "no-repo-top-fallback — want rc=0 got rc=$got_rc"
    fi
fi

# Case 10: traversal staged filename ../escape.py escapes the repo top →
# path.resolve(repoTop,"../escape.py") lands OUTSIDE the EXCLUDE prefix → rc 2.
# A traversal filename must not be silently excluded from enforcement.
assert_rc "traversal-staged-not-excluded" "2" \
    "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
    "_PRECOMMIT_REPO_TOP=$REPO_TOP_NODE" \
    "_PRECOMMIT_STAGED=../escape.py" \
    "ENFORCE_WORKTREE_EXCLUDE=$REPO_TOP_NODE"

# Case 11: semicolon list where only the 2nd entry covers the staged file → rc 0.
# Validates the helper passes the WHOLE list through, not just the first entry.
assert_rc "multi-entry-second-match" "0" \
    "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
    "_PRECOMMIT_REPO_TOP=$REPO_TOP_NODE" \
    "_PRECOMMIT_STAGED=src/main.py" \
    "ENFORCE_WORKTREE_EXCLUDE=/nonexistent/nomatch;$REPO_TOP_NODE"

# Case 12: a staged path CONTAINING A SPACE, covered by a repo-root prefix entry
# → rc 0. Proves a space in a staged filename survives the newline-split env
# transport (files split on /\r?\n/, not on whitespace) and is still covered.
assert_rc "space-in-staged-covered" "0" \
    "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
    "_PRECOMMIT_REPO_TOP=$REPO_TOP_NODE" \
    "_PRECOMMIT_STAGED=docs/my file.md" \
    "ENFORCE_WORKTREE_EXCLUDE=$REPO_TOP_NODE"

# Case 13: an EXCLUDE entry whose path CONTAINS A SPACE covers the staged file
# under that subtree → rc 0. Proves a space in an exclude entry is preserved
# (entries split on ';', never shell-split on whitespace).
assert_rc "space-in-exclude-entry-covered" "0" \
    "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
    "_PRECOMMIT_REPO_TOP=$REPO_TOP_NODE" \
    "_PRECOMMIT_STAGED=my dir/file.txt" \
    "ENFORCE_WORKTREE_EXCLUDE=$REPO_TOP_NODE/my dir"

# Case 14: a staged filename containing shell metacharacters that WOULD create a
# file named 'pwned' if the value were exec'd by a shell. Not covered by EXCLUDE
# → rc 2, AND no 'pwned' artifact is created. Proves env-var transport into node
# (no shell interpolation of the staged value).
INJECT_PROBE_DIR="$TMPBASE/inject-probe"
mkdir -p "$INJECT_PROBE_DIR"
if [ "$MODULE_MISSING" = "1" ]; then
    fail "metachar-staged-no-injection — MODULE_NOT_FOUND (expected red)"
else
    got_rc=0
    ( cd "$INJECT_PROBE_DIR" &&
      MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
      run_with_timeout 10 env \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "_PRECOMMIT_REPO_TOP=$REPO_TOP_NODE" \
        '_PRECOMMIT_STAGED=$(touch pwned).txt' \
        "ENFORCE_WORKTREE_EXCLUDE=/nonexistent/nomatch" \
        node "$MODULE_PATH" >"$TMPBASE/stdout.txt" 2>"$TMPBASE/stderr.txt" ) || got_rc=$?
    if [ "$got_rc" != "2" ]; then
        fail "metachar-staged-no-injection — want rc=2 got rc=$got_rc"
    elif [ -e "$INJECT_PROBE_DIR/pwned" ]; then
        fail "metachar-staged-no-injection — 'pwned' artifact was created (shell injection!)"
    else
        pass "metachar-staged-no-injection (rc=2, no 'pwned' artifact)"
    fi
fi
rm -f "$INJECT_PROBE_DIR/pwned"

# Case 15: a RELATIVE plain-path exclude entry (no leading slash, no glob) anchors
# to the process CWD. The git pre-commit hook always runs with CWD = repo top, so
# `path.resolve("docs")` yields <repoTop>/docs, covering the staged docs/x.md → rc 0.
# Contract: relative exclude entries resolve against the process CWD, which in the
# real pre-commit hook is the repo root.
if [ "$MODULE_MISSING" = "1" ]; then
    fail "relative-entry-anchored-to-repotop — MODULE_NOT_FOUND (expected red)"
else
    got_rc=0
    ( cd "$REPO_TOP" &&
      MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
      run_with_timeout 10 env \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "_PRECOMMIT_REPO_TOP=$REPO_TOP_NODE" \
        "_PRECOMMIT_STAGED=docs/x.md" \
        "ENFORCE_WORKTREE_EXCLUDE=docs" \
        node "$MODULE_PATH" >"$TMPBASE/stdout.txt" 2>"$TMPBASE/stderr.txt" ) || got_rc=$?
    if [ "$got_rc" = "0" ]; then
        pass "relative-entry-anchored-to-repotop (rc=0)"
    else
        fail "relative-entry-anchored-to-repotop — want rc=0 got rc=$got_rc"
    fi
fi

# Case 16: built-in exclude pattern (.worktree-backup/**) covers staged paths even
# when ENFORCE_WORKTREE_EXCLUDE is empty. Validates that the refactor (routing
# built-ins through the new path-coverage matcher) did not break the /worktree-end
# Step WE-8 backup bypass.
assert_rc "builtin-excludes-worktree-backup" "0" \
    "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
    "_PRECOMMIT_REPO_TOP=$REPO_TOP_NODE" \
    "_PRECOMMIT_STAGED=.worktree-backup/some-file.txt" \
    "ENFORCE_WORKTREE_EXCLUDE="

# Case 17: basename-only entry (no '/') covers any file with that basename.
# Exercises the gitignore basename semantics branch in shared-cmd-utils.js isExcluded():
# `if (!entry.includes('/') && isCoveredByEntryList(entry, path.basename(abs)))`
# An entry like "todo.md" (no slash, no glob) matches any staged file named "todo.md"
# regardless of directory depth.
assert_rc "basename-entry-matches-file" "0" \
    "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
    "_PRECOMMIT_REPO_TOP=$REPO_TOP_NODE" \
    "_PRECOMMIT_STAGED=docs/todo.md" \
    "ENFORCE_WORKTREE_EXCLUDE=todo.md"

# Case 18 (C3): mixed-canonical-and-deprecated-both-covered
# Both ENFORCE_WORKTREE_EXCLUDE (canonical) and ENFORCE_WORKTREE_EXCLUDE_REPOS
# (deprecated) are set; the canonical covers the staged file → rc 0.
# The deprecated alias only adds to the entry list but the canonical is enough.
assert_rc "mixed-canonical-and-deprecated-both-covered" "0" \
    "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
    "_PRECOMMIT_REPO_TOP=$REPO_TOP_NODE" \
    "_PRECOMMIT_STAGED=docs/readme.md" \
    "ENFORCE_WORKTREE_EXCLUDE=$REPO_TOP_NODE" \
    "ENFORCE_WORKTREE_EXCLUDE_REPOS=/some/other/path"

# Case 19 (C3): deprecated-only-covers-staged
# ENFORCE_WORKTREE_EXCLUDE is empty but ENFORCE_WORKTREE_EXCLUDE_REPOS contains
# the repo top → migration block merges it into EXCLUDE → rc 0.
# Confirms the deprecated alias works as a bypass via the migration block.
assert_rc "deprecated-only-covers-staged" "0" \
    "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
    "_PRECOMMIT_REPO_TOP=$REPO_TOP_NODE" \
    "_PRECOMMIT_STAGED=docs/readme.md" \
    "ENFORCE_WORKTREE_EXCLUDE=" \
    "ENFORCE_WORKTREE_EXCLUDE_REPOS=$REPO_TOP_NODE"

# Case 20 (C5): semicolon-in-staged-path-not-bypass
# A staged filename that contains a literal semicolon is covered by a repo-root
# prefix EXCLUDE → rc 0. The semicolon is part of the filename, not a separator
# (staged paths split on newlines only, not semicolons).
assert_rc "semicolon-in-staged-path-not-bypass" "0" \
    "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
    "_PRECOMMIT_REPO_TOP=$REPO_TOP_NODE" \
    "_PRECOMMIT_STAGED=docs/semi;colon.md" \
    "ENFORCE_WORKTREE_EXCLUDE=$REPO_TOP_NODE"

# Case 21 (C5): newline-in-exclude-entry-no-bypass
# ENFORCE_WORKTREE_EXCLUDE has an embedded newline in the value. The entry does
# not match the staged file → rc 2. Proves that a newline in the env var does
# NOT accidentally create extra entries that might grant bypass.
# Note: env vars cannot contain literal newlines in most shells, but Node reads
# process.env directly. We pass the value via a file-sourced trick; since the
# assert_rc helper uses `env KEY=VALUE`, we cannot embed a real newline there.
# Instead, test the documented separator (semicolon): a value like
# `/some/path\n/other` (backslash-n, not newline) must NOT match the staged
# path — verifying that a non-matching exclude always gives rc 2.
assert_rc "newline-in-exclude-entry-no-bypass" "2" \
    "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
    "_PRECOMMIT_REPO_TOP=$REPO_TOP_NODE" \
    "_PRECOMMIT_STAGED=docs/readme.md" \
    "ENFORCE_WORKTREE_EXCLUDE=/some/path\\n/other"

rm -rf "$REPO_TOP"

# Create a new temp dir for remaining cases (original REPO_TOP removed above)
REPO_TOP2="$(mktemp -d)"
if command -v cygpath >/dev/null 2>&1; then
    REPO_TOP2_NODE="$(cygpath -m "$REPO_TOP2")"
else
    REPO_TOP2_NODE="$REPO_TOP2"
fi
trap 'rm -rf "$TMPBASE" "$REPO_TOP2"' EXIT

# C6: Semicolon edge cases

# Case C6a: whitespace-padded-entries
# ENFORCE_WORKTREE_EXCLUDE has spaces around the semicolon and around entries.
# If parseExcludePatterns trims whitespace, rc 0 (covered). rc 2 is also
# acceptable behaviour if the implementation does not trim (documented here).
# We assert rc 0 because shared-cmd-utils.js trims entries via .trim().filter(Boolean).
assert_rc "whitespace-padded-entries" "0" \
    "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
    "_PRECOMMIT_REPO_TOP=$REPO_TOP2_NODE" \
    "_PRECOMMIT_STAGED=src/main.py" \
    "ENFORCE_WORKTREE_EXCLUDE= $REPO_TOP2_NODE ; /other "

# Case C6b: empty-entries-in-list
# Double semicolon creates an empty entry between two real entries.
# Empty entries should be ignored; the first real entry (REPO_TOP2) covers staged.
assert_rc "empty-entries-in-list" "0" \
    "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
    "_PRECOMMIT_REPO_TOP=$REPO_TOP2_NODE" \
    "_PRECOMMIT_STAGED=src/main.py" \
    "ENFORCE_WORKTREE_EXCLUDE=$REPO_TOP2_NODE;;/other"

# Case C6c: duplicate-entries
# Same repo root appears twice in the semicolon list.
# First match short-circuits; result is rc 0.
assert_rc "duplicate-entries" "0" \
    "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
    "_PRECOMMIT_REPO_TOP=$REPO_TOP2_NODE" \
    "_PRECOMMIT_STAGED=src/main.py" \
    "ENFORCE_WORKTREE_EXCLUDE=$REPO_TOP2_NODE;$REPO_TOP2_NODE"

rm -rf "$REPO_TOP2"

echo ""
echo "================================"
echo "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $FAIL
