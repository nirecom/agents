#!/bin/bash
# tests/unit-path-coverage-match.sh
# Tests: hooks/lib/path-coverage-match.js
# Tags: unit, path-coverage, scope:common, pwsh-not-required
#
# Unit tests for hooks/lib/path-coverage-match.js (isCoveredByEntryList, hasGlobMetachar).
# Table-driven. Expected RED until hooks/lib/path-coverage-match.js is created.
#
# Mutation probe: N/A — this module defines no regex constants (glob dispatch is String.includes('*'); glob matching is delegated to hooks/lib/glob-match.js, covered by feature-enforce-worktree-exclude-glob.sh).
#
# L3 gap (what this test does NOT catch):
# - Real PreToolUse hook session where path-coverage-match is loaded via settings.json
# - Windows path casing in a live Claude Code session
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_NODE="$AGENTS_DIR"
fi

MODULE="$_AGENTS_NODE/hooks/lib/path-coverage-match.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP+1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then pass "$name"; else fail "$name — want=$want got=$got"; fi
}

# Check for MODULE_NOT_FOUND
MODULE_MISSING=0
if node -e "require('$MODULE')" 2>&1 | grep -q "MODULE_NOT_FOUND"; then
    MODULE_MISSING=1
fi

# Call isCoveredByEntryList(entryList, targetPath) -> "true" or "false"
# Values pass via env (not argv) with MSYS path-conversion disabled, so Git-Bash
# on Windows does not mangle POSIX-absolute literals like /a/b/c.txt into A:/b/c.txt.
# MSYS_NO_PATHCONV / MSYS2_ARG_CONV_EXCL are no-ops on POSIX hosts.
call_covered() {
    local entry_list="$1" target="$2"
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
    _PCM_ENTRY="$entry_list" _PCM_TARGET="$target" \
    run_with_timeout 10 node -e "
const m = require('$MODULE');
const r = m.isCoveredByEntryList(process.env._PCM_ENTRY, process.env._PCM_TARGET);
process.stdout.write(r ? 'true' : 'false');
" 2>/dev/null
}

echo "=== isCoveredByEntryList cases ==="

# Table: name | entry_list | target | want
while IFS='|' read -r name entry_list target want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name#"${name%%[![:space:]]*}"}"; name="${name%"${name##*[![:space:]]}"}"
    entry_list="${entry_list#"${entry_list%%[![:space:]]*}"}"; entry_list="${entry_list%"${entry_list##*[![:space:]]}"}"
    target="${target#"${target%%[![:space:]]*}"}"; target="${target%"${target##*[![:space:]]}"}"
    want="${want#"${want%%[![:space:]]*}"}"; want="${want%"${want##*[![:space:]]}"}"

    if [ "$MODULE_MISSING" = "1" ]; then
        fail "$name — MODULE_NOT_FOUND (expected red, module not yet created)"
        continue
    fi
    got="$(call_covered "$entry_list" "$target")"
    assert_eq "$name" "$want" "$got"
done <<'TABLE'
glob-match-wildcard        | **/todo.md          | /a/b/todo.md           | true
glob-match-single-star     | C:/git/*/data.json  | C:/git/repo/data.json  | true
glob-no-match              | **/todo.md          | /a/b/other.md          | false
prefix-exact               | /a/b                | /a/b                   | true
prefix-subtree             | /a/b                | /a/b/c/d.txt           | true
prefix-sibling             | /a/bbb              | /a/b                   | false
prefix-sibling2            | /a/b                | /a/bbb/file.txt        | false
prefix-nonmatch            | /a/b                | /a/c/d.txt             | false
empty-list                 |                     | /any/path              | false
mixed-list-prefix          | **/todo.md;/a/b     | /a/b/c.txt             | true
mixed-list-glob            | **/todo.md;/a/b     | /x/todo.md             | true
mixed-none                 | **/todo.md;/a/b     | /c/other.txt           | false
single-file-exact          | /a/b/specific.txt   | /a/b/specific.txt      | true
single-file-subtree        | /a/b/specific.txt   | /a/b/specific.txt/x    | true
traversal-no-match         | /safe/path          | /safe/path/../../etc/passwd | false
traversal-resolves-inside  | /safe               | /safe/sub/../file.txt  | true
target-empty-string        | /a/b                |                        | false
file-entry-no-basename-glob | /safe/secret.txt   | /other/secret.txt      | false
TABLE

# Windows case-fold test (only runs on Windows)
_os="$(uname -s 2>/dev/null || true)"
case "$_os" in
    MINGW*|MSYS*|CYGWIN*)
        if [ "$MODULE_MISSING" = "1" ]; then
            fail "windows-case-fold — MODULE_NOT_FOUND (expected red)"
        else
            got="$(call_covered "/A/B" "/a/b")"
            assert_eq "windows-case-fold" "true" "$got"
        fi
        ;;
    *)
        skip "windows-case-fold — not Windows"
        ;;
esac

# POSIX-drive-letter normalization (only runs on Windows).
# On Windows, a POSIX-drive path like /c/foo must normalize to C:\foo so it
# matches a drive-letter entry/target. On POSIX hosts /c/foo and C:/foo are
# genuinely different paths (C: is not a drive), so the equivalence is skipped.
# Table: name | entry_list | target | want
case "$_os" in
    MINGW*|MSYS*|CYGWIN*)
        while IFS='|' read -r name entry_list target want; do
            [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
            name="${name#"${name%%[![:space:]]*}"}"; name="${name%"${name##*[![:space:]]}"}"
            entry_list="${entry_list#"${entry_list%%[![:space:]]*}"}"; entry_list="${entry_list%"${entry_list##*[![:space:]]}"}"
            target="${target#"${target%%[![:space:]]*}"}"; target="${target%"${target##*[![:space:]]}"}"
            want="${want#"${want%%[![:space:]]*}"}"; want="${want%"${want##*[![:space:]]}"}"

            if [ "$MODULE_MISSING" = "1" ]; then
                fail "$name — MODULE_NOT_FOUND (expected red)"
                continue
            fi
            got="$(call_covered "$entry_list" "$target")"
            assert_eq "$name" "$want" "$got"
        done <<'WINTABLE'
posix-drive-entry-vs-drive-target | /c/foo/bar | C:/foo/bar        | true
drive-entry-vs-posix-target       | C:/foo/bar | /c/foo/bar        | true
posix-drive-entry-subtree         | /c/foo     | C:/foo/sub/x.txt  | true
WINTABLE
        ;;
    *)
        skip "posix-drive-entry-vs-drive-target — not Windows"
        skip "drive-entry-vs-posix-target — not Windows"
        skip "posix-drive-entry-subtree — not Windows"
        ;;
esac

# target-undefined: pass JS undefined as targetPath (cannot be a table cell).
# Contract: isCoveredByEntryList must guard non-string targetPath and return
# false, NOT throw (write-code adds `typeof targetPath !== "string" || !targetPath
# → return false`). Driven via a direct node -e passing undefined explicitly.
call_covered_undef() {
    run_with_timeout 10 node -e "
const m = require('$MODULE');
process.stdout.write(m.isCoveredByEntryList('/a/b', undefined) ? 'true' : 'false');
" 2>/dev/null
}
if [ "$MODULE_MISSING" = "1" ]; then
    fail "target-undefined — MODULE_NOT_FOUND (expected red)"
else
    got="$(call_covered_undef)"
    assert_eq "target-undefined" "false" "$got"
fi

echo ""
echo "=== hasGlobMetachar cases ==="

call_has_meta() {
    local val="$1"
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
    _PCM_VAL="$val" \
    run_with_timeout 10 node -e "
const m = require('$MODULE');
process.stdout.write(m.hasGlobMetachar(process.env._PCM_VAL) ? 'true' : 'false');
" 2>/dev/null
}

call_has_meta_num() {
    run_with_timeout 10 node -e "
const m = require('$MODULE');
process.stdout.write(m.hasGlobMetachar(42) ? 'true' : 'false');
" 2>/dev/null
}

for case_def in \
    "star-true|*|true" \
    "globstar-true|**/x|true" \
    "plain-false|plain/path|false"
do
    cname="${case_def%%|*}"
    rest="${case_def#*|}"
    cval="${rest%%|*}"
    cwant="${rest##*|}"
    if [ "$MODULE_MISSING" = "1" ]; then
        fail "$cname — MODULE_NOT_FOUND (expected red)"
    else
        got="$(call_has_meta "$cval")"
        assert_eq "$cname" "$cwant" "$got"
    fi
done

# non-string input
if [ "$MODULE_MISSING" = "1" ]; then
    fail "non-string-false — MODULE_NOT_FOUND (expected red)"
else
    got="$(call_has_meta_num)"
    assert_eq "non-string-false" "false" "$got"
fi

echo ""
echo "================================"
echo "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $FAIL
