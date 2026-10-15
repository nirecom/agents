#!/usr/bin/env bash
# check-session-id-ssot.sh — two static checks. (1) SSOT read gate (#2270): a Node `process.env`
# access to SESSION_ID / CLAUDE_CODE_SESSION_ID (dotted or bracket+literal) bypasses the resolver.
# Bash `$VAR`, computed `process.env[name]` and WORKFLOW_SESSION_ID are out of scope (not
# statically separable from legitimate use); completeness is NOT claimed.
# (2) Retired-relay tombstone (#1091): the retired relay names may not appear anywhere in the
# tracked tree outside append-only records, the test archive and TOMBSTONE_EXEMPT; no waivers.
# Test isolation lines that only clear them pass (tombstone_isolation_line, #2590).
# Path tables: bin/check-session-id-ssot/path-tables.txt of the cwd tree, else the one beside this script.
# Usage: check-session-id-ssot.sh [--staged] [file ...]   Exit: 0 clean | 1 violations | 2 usage.
# Contract and rationale: docs/architecture/claude-code/session-id-resolution.md

set -uo pipefail

NAMES="SESSION_ID|CLAUDE_CODE_SESSION_ID"
READ_RE="process\\.env\\.($NAMES)([^A-Za-z0-9_]|\$)|process\\.env\\[[[:space:]]*[\"']($NAMES)[\"'][[:space:]]*\\]"
# A waiver needs a role AND a non-empty reason after the em dash; a bare marker is the
# rubber stamp this gate exists to prevent.
WAIVER_RE="session-id-ssot: waived \\([^)]*\\)[[:space:]]*—[[:space:]]*[^[:space:]]"

# Tombstone: the names are retired, so no use is legitimate and no waiver applies.
TOMBSTONE_RE='(^|[^A-Za-z0-9_])(CLAUDE_SESSION_ID|CLAUDE_ENV_FILE)([^A-Za-z0-9_]|$)'
# Test isolation must still clear the names, so a leftover CLAUDE_ENV_FILE cannot reach the
# purge and rewrite a real env file. In tests/<dir>/**/*.sh and the shared points the table lists,
# a line passes when every retired name on it is an operand of a whole-line `unset` or of `-u <name>`.
TOMBSTONE_UNSET_LINE_RE='^[[:space:]]*unset([[:space:]]+[A-Za-z_][A-Za-z0-9_]*)+([[:space:]]+2>[[:space:]]*/dev/null)?([[:space:]]*\|\|[[:space:]]*true)?[[:space:]]*$'
TOMBSTONE_DASH_U_RE='(^|[[:space:]])-u[[:space:]]+(CLAUDE_SESSION_ID|CLAUDE_ENV_FILE)([^A-Za-z0-9_]|$)'

usage() {
    echo "usage: check-session-id-ssot.sh [--staged] [file ...]" >&2
    [ $# -gt 0 ] && echo "check-session-id-ssot: $1" >&2
    exit 2
}

FILES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --staged) shift ;;
        --) shift; while [ $# -gt 0 ]; do FILES+=("$1"); shift; done ;;
        -*) usage "unknown flag: $1" ;;
        *) FILES+=("$1"); shift ;;
    esac
done

# The tables of the tree under judgment (cwd) decide, so a path and the change relying on it
# can land in one commit; only a tree without the file is judged with this script's own copy.
TABLE_REL="bin/check-session-id-ssot/path-tables.txt"
TABLE_FILE="$TABLE_REL"
if [[ ! -e "$TABLE_FILE" && ! -L "$TABLE_FILE" ]]; then
    TABLE_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-session-id-ssot/path-tables.txt"
    echo "check-session-id-ssot: no $TABLE_REL under the current directory; judging with the guard's own tables" >&2
fi
table_error() {
    echo "check-session-id-ssot: $TABLE_FILE: $1" >&2
    exit 2
}
[[ -f "$TABLE_FILE" && ! -L "$TABLE_FILE" ]] || table_error "not a regular file"
[[ -r "$TABLE_FILE" ]] || table_error "not readable"

ALLOWLIST=()
TOMBSTONE_EXEMPT=()
TOMBSTONE_ISOLATION_FILES_OUTSIDE_TESTS=()
TABLE_SECTION=""
TABLE_SEEN=""
while IFS= read -r TABLE_LINE || [[ -n "$TABLE_LINE" ]]; do
    TABLE_LINE="${TABLE_LINE#"${TABLE_LINE%%[![:space:]]*}"}"
    TABLE_LINE="${TABLE_LINE%"${TABLE_LINE##*[![:space:]]}"}"
    case "$TABLE_LINE" in
        ""|"#"*) continue ;;
        "[ALLOWLIST]"|"[TOMBSTONE_EXEMPT]"|"[TOMBSTONE_ISOLATION_FILES_OUTSIDE_TESTS]")
            TABLE_SECTION="$TABLE_LINE"
            TABLE_SEEN="$TABLE_SEEN$TABLE_LINE"
            continue ;;
        "["*"]") table_error "unknown section $TABLE_LINE" ;;
    esac
    case "$TABLE_SECTION" in
        "[ALLOWLIST]") ALLOWLIST+=("$TABLE_LINE") ;;
        "[TOMBSTONE_EXEMPT]") TOMBSTONE_EXEMPT+=("$TABLE_LINE") ;;
        "[TOMBSTONE_ISOLATION_FILES_OUTSIDE_TESTS]") TOMBSTONE_ISOLATION_FILES_OUTSIDE_TESTS+=("$TABLE_LINE") ;;
        *) table_error "entry before any section: $TABLE_LINE" ;;
    esac
done < "$TABLE_FILE"
for TABLE_SECTION in "[ALLOWLIST]" "[TOMBSTONE_EXEMPT]" "[TOMBSTONE_ISOLATION_FILES_OUTSIDE_TESTS]"; do
    [[ "$TABLE_SEEN" == *"$TABLE_SECTION"* ]] || table_error "section $TABLE_SECTION missing"
done

# No explicit files: the whole tracked tree. "No new direct read anywhere" is a property of
# the tree, not of one commit's diff, so --staged narrows nothing on its own.
if [ "${#FILES[@]}" -eq 0 ]; then
    command -v git >/dev/null 2>&1 || { echo "check-session-id-ssot: git not found" >&2; exit 2; }
    while IFS= read -r -d '' f; do FILES+=("$f"); done < <(git ls-files -z 2>/dev/null)
fi

# Excluded trees: fixtures must be free to set the raw env, and prose that quotes the
# expression is not a code path.
in_scope() {
    case "$1" in
        tests/*|docs/*|changelog/*|.git/*|*.md) return 1 ;;
    esac
    [ -f "$1" ] || return 1
    for a in ${ALLOWLIST[@]+"${ALLOWLIST[@]}"}; do
        [ "$1" = "$a" ] && return 1
    done
    return 0
}

# Tombstone scope is wider than in_scope: tests and Markdown are included, because a retired
# name in a fixture or a skill re-teaches the relay. Only append-only records and the archive
# are excluded.
tombstone_in_scope() {
    case "$1" in
        docs/history/*|docs/history.md|changelog/*|CHANGELOG.md|tests/_archive/*|.git/*) return 1 ;;
    esac
    [ -f "$1" ] || return 1
    for e in ${TOMBSTONE_EXEMPT[@]+"${TOMBSTONE_EXEMPT[@]}"}; do
        [ "$1" = "$e" ] && return 1
    done
    return 0
}

SCAN=()
TSCAN=()
for f in "${FILES[@]}"; do
    in_scope "$f" && SCAN+=("$f")
    tombstone_in_scope "$f" && TSCAN+=("$f")
done

# grep exits 1 for "no match" (clean) but >1 for an error; an error must not read as a clean scan.
scan_grep() {
    local re="$1" rc=0
    shift
    SCAN_OUT="$(grep -I -n -H -E -- "$re" "$@" 2>/dev/null)" || rc=$?
    if [ "$rc" -gt 1 ]; then
        echo "check-session-id-ssot: grep failed (exit $rc)" >&2
        exit 2
    fi
}

# tombstone_isolation_file <path> — 0 when the line rule applies to <path>.
tombstone_isolation_file() {
    local s
    case "$1" in tests/*/*.sh) return 0 ;; esac
    for s in ${TOMBSTONE_ISOLATION_FILES_OUTSIDE_TESTS[@]+"${TOMBSTONE_ISOLATION_FILES_OUTSIDE_TESTS[@]}"}; do
        [ "$1" = "$s" ] && return 0
    done
    return 1
}

# tombstone_isolation_line <text> — 0 when every retired name on the line only clears it.
tombstone_isolation_line() {
    local text="$1"
    [[ "$text" =~ $TOMBSTONE_UNSET_LINE_RE ]] && return 0
    while [[ "$text" =~ $TOMBSTONE_DASH_U_RE ]]; do
        text="${text/"${BASH_REMATCH[0]}"/ ${BASH_REMATCH[3]}}"
    done
    [[ "$text" =~ $TOMBSTONE_RE ]] && return 1
    return 0
}

TOMBSTONES=0
if [ "${#TSCAN[@]}" -gt 0 ]; then
    scan_grep "$TOMBSTONE_RE" "${TSCAN[@]}"
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        file="${hit%%:*}"
        rest="${hit#*:}"
        if tombstone_isolation_file "$file" && tombstone_isolation_line "${rest#*:}"; then continue; fi
        echo "$hit"
        TOMBSTONES=$((TOMBSTONES + 1))
    done <<< "$SCAN_OUT"
fi
if [ "$TOMBSTONES" -gt 0 ]; then
    echo ""
    echo "Retired session-id relay names reintroduced ($TOMBSTONES). Use CLAUDE_CODE_SESSION_ID; see docs/architecture/claude-code/session-id-resolution.md#retired-relay."
fi

VIOLATIONS=0
SCAN_OUT=""
[ "${#SCAN[@]}" -gt 0 ] && scan_grep "$READ_RE" "${SCAN[@]}"
[ "${#SCAN[@]}" -gt 0 ] && while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    file="${hit%%:*}"
    rest="${hit#*:}"
    line="${rest%%:*}"
    text="${rest#*:}"
    echo "$text" | grep -qE "$WAIVER_RE" && continue
    if [ "$line" -gt 1 ]; then
        prev="$(sed -n "$((line - 1))p" "$file" 2>/dev/null || true)"
        echo "$prev" | grep -qE "$WAIVER_RE" && continue
    fi
    echo "$file:$line: ${text#"${text%%[![:space:]]*}"}"
    VIOLATIONS=$((VIOLATIONS + 1))
done <<< "$SCAN_OUT"

if [ "$VIOLATIONS" -gt 0 ]; then
    echo ""
    echo "Direct session-id env reads bypass the SSOT resolver ($VIOLATIONS)."
    echo "Call resolveSessionId() instead, or add an inline waiver:"
    echo "  // session-id-ssot: waived (<role>) — <why the resolver cannot be used here>"
    echo "See docs/architecture/claude-code/session-id-resolution.md."
fi
[ $((VIOLATIONS + TOMBSTONES)) -gt 0 ] && exit 1
exit 0
