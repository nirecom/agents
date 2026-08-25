#!/usr/bin/env bash
# tests/fix-2025-safe-plans-path.sh
# Tests: bin/lib/safe-plans-path.sh, bin/lib/concern-ledger.sh, bin/concern-ledger
# Tags: safe-plans-path, path-traversal, containment, symlink, atomic-publish, table-driven, security, scope:issue-specific, pwsh-not-required
#
# #2025: every writer under the plans dir spelled its own destination, so each
# owned a separate copy of "is this still inside the directory the caller
# nominated". This pins the shared primitive that replaces them, on the two axes
# that decide whether a write is safe: the token that names a file, and the
# directory a finished file is allowed to land in.
set -uo pipefail

# TL1 — the library is sourced directly; the only real resources are a temp tree
# and its symlinks, which is what the containment checks are about.
#
# TL3 gap (mitigation: filesystem-semantics): TOCTOU mid-publish is out of scope
# (the threat is a pre-placed link); Windows junctions/NTFS reparse points are
# misreported by `test -h`; SYMLINKS_OK/MODES_OK cases are SKIPPED where the
# host lacks symlinks or POSIX modes, and permission-denied publication is
# SKIPPED everywhere (chmod 000 stays writable under Git Bash on Windows).
# Mitigation: single resolution is pinned as source shape, and the pre-placed
# *directory* attack needs no symlinks, so it covers every form on every host.

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPLIB="$AGENTS_ROOT/bin/lib/safe-plans-path.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        pass "$name"
    else
        echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"
        FAIL=$((FAIL + 1))
    fi
}

# assert_eq with a guard: an expectation that could not be computed is itself a
# failure, so '' == '' can never pass while the thing under test is missing.
assert_eq_nz() {
    local name="$1" want="$2" got="$3"
    if [ -z "$want" ]; then
        echo "FAIL: $name — the expected value could not be computed (empty)"
        FAIL=$((FAIL + 1))
        return
    fi
    assert_eq "$name" "$want" "$got"
}

# Fixture isolation (rules/test/fixture-isolation.md).
TMPDIR_BASE=$(mktemp -d)
trap 'cd / 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT
unset CLAUDE_SESSION_ID 2>/dev/null || true
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
export CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
export AGENTS_CONFIG_DIR="$AGENTS_ROOT"
cd "$TMPDIR_BASE" || exit 1

if [ ! -f "$SPLIB" ]; then
    echo "SKIP-BLOCKED: bin/lib/safe-plans-path.sh not implemented yet"
    fail "implementation missing: bin/lib/safe-plans-path.sh (every case below fails for this reason)"
fi

# sp <fn> <args...> — one library call in its own subshell, so a sourced
# implementation can never clobber the harness counters.
sp() { ( set +u; source "$SPLIB" >/dev/null 2>&1 || exit 127; "$@" ); }

# verdict <fn> <args...> → accepted | rejected | missing. Named rather than
# numbered so a table row states the contract; 'missing' keeps an absent
# implementation from reading as a rejection.
verdict() {
    local rc
    sp "$@" >/dev/null 2>&1
    rc=$?
    case "$rc" in
        0) printf accepted ;;
        127) printf missing ;;
        *) printf rejected ;;
    esac
}

trim_f() { printf '%s' "$1" | sed 's/^ *//; s/ *$//'; }

echo ""
echo "--- sp 1: sp_valid_token — the allowlist that names a file ---"

# A token becomes part of a filename under the plans dir. Anything that can
# introduce a separator, a parent reference, or an option-looking leading dash
# is refused here rather than caught by a later containment check.
while IFS='|' read -r name input want; do
    [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    name="$(trim_f "$name")"; input="$(trim_f "$input")"; want="$(trim_f "$want")"
    [ "$input" = "<empty>" ] && input=""
    assert_eq "1: $name" "$want" "$(verdict sp_valid_token "$input")"
done <<'TABLE'
an ordinary session id            | 0199a2f1-cafe-4b0d-9c11-deadbeef0001 | accepted
a plain word                      | detail                               | accepted
a single alnum character          | a                                    | accepted
dots inside the name              | user.name                            | accepted
an underscore                     | my_session                           | accepted
the empty token                   | <empty>                              | rejected
a bare parent reference           | ..                                   | rejected
a parent reference in a path      | ../escaped                           | rejected
a parent reference mid-token      | a..b                                 | rejected
a forward separator               | sub/nested                           | rejected
a backslash separator             | sub\nested                           | rejected
a leading dash reads as an option | -rf                                  | rejected
a leading dash with a word        | --plans-dir                          | rejected
a shell metacharacter             | a;b                                  | rejected
a glob metacharacter              | a*b                                  | rejected
a space                           | a b                                  | rejected
a dollar expansion                | $HOME                                | rejected
TABLE

# The bare-dot edge earns its own row: '.' names the directory itself, so a
# token that is exactly a dot would make the derived path a directory.
assert_eq "1: a token that is exactly a dot" "rejected" "$(verdict sp_valid_token ".")"
assert_eq "1: a token that is exactly a dash" "rejected" "$(verdict sp_valid_token "-")"

# No overlong-token row: the allowlist is a character class with no length
# term, so length is an OS path-limit question, not this function's contract.

echo ""
echo "--- sp 2: which separator set applies to which path ---"

# A backslash is a separator on a Windows-spelled path and an ordinary filename
# character everywhere else. Deciding that per path — never per host — is what
# keeps a POSIX file literally named 'a\b' from being split in two (CPR-UNV).
while IFS='|' read -r name input want; do
    [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    name="$(trim_f "$name")"; input="$(trim_f "$input")"; want="$(trim_f "$want")"
    assert_eq "2: $name" "$want" "$(verdict _sp_is_winpath "$input")"
done <<'TABLE'
a drive letter with a backslash  | C:\Users\nire        | accepted
a drive letter with a slash      | C:/Users/nire        | accepted
a bare drive letter              | C:                   | accepted
a lowercase drive letter         | d:\tmp               | accepted
a UNC path                       | \\server\share       | accepted
an ordinary absolute POSIX path  | /home/nire/.plans    | rejected
a relative POSIX path            | plans/dir            | rejected
a POSIX name holding a backslash | plans\evil           | rejected
a two-letter prefix, not a drive | ab:\x                | rejected
TABLE

# _sp_dirname / _sp_basename read the separator set decided above.
sp_split() { printf 'dir=%s base=%s' "$(sp _sp_dirname "$1")" "$(sp _sp_basename "$1")"; }

assert_eq_nz "2: a POSIX path splits on the forward slash only" \
    'dir=/xx/y base=z.txt' "$(sp_split '/xx/y/z.txt')"
assert_eq_nz "2: a Windows path splits on the backslash too" \
    'dir=C:\a\b base=c.txt' "$(sp_split 'C:\a\b\c.txt')"
assert_eq_nz "2: a Windows path with mixed separators splits at the last one" \
    'dir=C:\a/b base=c.txt' "$(sp_split 'C:\a/b\c.txt')"
assert_eq_nz "2: a POSIX filename containing a backslash is one name, not two" \
    'dir=/xx base=a\b.txt' "$(sp_split '/xx/a\b.txt')"
assert_eq_nz "2: a bare name has the current directory as its directory" \
    'dir=. base=c.txt' "$(sp_split 'c.txt')"
assert_eq_nz "2: a trailing separator does not produce an empty basename" \
    'dir=/xx base=y' "$(sp_split '/xx/y/')"

echo ""
echo "--- sp 3: '..' detection, and the gate over it ---"

# _sp_has_dotdot <rest> <win>: a '..' component. On a non-Windows path a
# backslash is not a separator, so 'x\..\y' holds no '..' component at all —
# treating it as one would refuse a legal POSIX filename (CPR-UNV).
while IFS='|' read -r name rest win want; do
    [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    name="$(trim_f "$name")"; rest="$(trim_f "$rest")"
    win="$(trim_f "$win")"; want="$(trim_f "$want")"
    assert_eq "3: $name" "$want" "$(verdict _sp_has_dotdot "$rest" "$win")"
done <<'TABLE'
a leading parent component       | ../y      | 0 | accepted
a parent component in the middle | x/../y    | 0 | accepted
a trailing parent component      | x/..      | 0 | accepted
the whole path is a parent ref   | ..        | 0 | accepted
a name that merely starts so     | ..hidden  | 0 | rejected
a name that merely contains dots | x/a..b/y  | 0 | rejected
backslashes on a POSIX path      | x\..\y    | 0 | rejected
backslashes on a Windows path    | x\..\y    | 1 | accepted
mixed separators on Windows      | x/..\y    | 1 | accepted
no parent reference at all       | x/y/z     | 0 | rejected
TABLE

# A host that cannot create real symlinks turns every symlink assertion below
# into a vacuous pass, so the capability is probed once and named in the output
# rather than being silently assumed.
SYMLINKS_OK=no
ln -s "$TMPDIR_BASE" "$TMPDIR_BASE/.symlink-probe" 2>/dev/null || true
[ -h "$TMPDIR_BASE/.symlink-probe" ] && SYMLINKS_OK=yes
[ "$SYMLINKS_OK" = "yes" ] \
    || echo "NOTE: this host does not create real symlinks — symlink cases are skipped"

# The same treatment for POSIX modes (CPR-ORTH). safe-plans-path.sh pins the
# temp file's mode at 0600 and documents the no-op filesystem as a named
# CPR-UNV exception; on NTFS under Git Bash chmod succeeds and changes nothing,
# so the assertion cannot be made to pass there without asserting a falsehood.
# Probed rather than assumed, so the mode really is checked wherever it exists.
MODES_OK=no
{
    MODE_PROBE="$TMPDIR_BASE/.mode-probe"
    : > "$MODE_PROBE"
    chmod 600 "$MODE_PROBE" 2>/dev/null || true
    [ "$({ stat -c '%a' "$MODE_PROBE" 2>/dev/null || stat -f '%Lp' "$MODE_PROBE" 2>/dev/null; })" = "600" ] \
        && MODES_OK=yes
}
[ "$MODES_OK" = "yes" ] \
    || echo "NOTE: this host does not honour POSIX modes — mode cases are skipped"

# ---------------------------------------------------------------------------
# Cases split into tests/fix-2025-safe-plans-path/ per rules/coding/file-split.md.
# ---------------------------------------------------------------------------
SUITE_DIR="$AGENTS_ROOT/tests/fix-2025-safe-plans-path"

# shellcheck source=./fix-2025-safe-plans-path/containment.sh
. "$SUITE_DIR/containment.sh"
# shellcheck source=./fix-2025-safe-plans-path/publish.sh
. "$SUITE_DIR/publish.sh"
# shellcheck source=./fix-2025-safe-plans-path/contained-ops.sh
. "$SUITE_DIR/contained-ops.sh"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed."
    exit 0
fi
exit 1
