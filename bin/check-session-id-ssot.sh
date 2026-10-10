#!/usr/bin/env bash
# check-session-id-ssot.sh — two static checks. (1) SSOT read gate (#2270): a Node `process.env`
# access to SESSION_ID / CLAUDE_CODE_SESSION_ID (dotted or bracket+literal) bypasses the resolver.
# Bash `$VAR`, computed `process.env[name]` and WORKFLOW_SESSION_ID are out of scope (not
# statically separable from legitimate use); completeness is NOT claimed.
# (2) Retired-relay tombstone (#1091): the retired relay names may not appear anywhere in the
# tracked tree outside append-only records, the test archive and TOMBSTONE_EXEMPT; no waivers.
# Usage: check-session-id-ssot.sh [--staged] [file ...]   Exit: 0 clean | 1 violations | 2 usage.
# Contract and rationale: docs/architecture/claude-code/session-id-resolution.md

set -uo pipefail

# Whole-file exemptions: the canonical resolvers. Every direct read in them IS the
# implementation the rest of the tree must delegate to. Everything else needing a direct
# read carries a per-line inline waiver instead, so the exemption stays where it is earned.
ALLOWLIST=(
  "hooks/workflow-state/session-id.js"
  "hooks/lib/resolve-workflow-session-id.js"
  "hooks/workflow-state/resolve-worktree-path.js"
  "bin/resolve-worktree-path"
)

NAMES="SESSION_ID|CLAUDE_CODE_SESSION_ID"
READ_RE="process\\.env\\.($NAMES)([^A-Za-z0-9_]|\$)|process\\.env\\[[[:space:]]*[\"']($NAMES)[\"'][[:space:]]*\\]"
# A waiver needs a role AND a non-empty reason after the em dash; a bare marker is the
# rubber stamp this gate exists to prevent.
WAIVER_RE="session-id-ssot: waived \\([^)]*\\)[[:space:]]*—[[:space:]]*[^[:space:]]"

# Tombstone: the names are retired, so no use is legitimate and no waiver applies. The exempt
# files must still spell them: this guard, its test, the one-shot purge migration and its test,
# the doc that records the retirement, and the test-isolation points that unset the retired
# names so a leftover CLAUDE_ENV_FILE cannot reach the purge and rewrite a real env file
# (the two shared ones, then the tests and the fixture that unset them on their own).
TOMBSTONE_RE='(^|[^A-Za-z0-9_])(CLAUDE_SESSION_ID|CLAUDE_ENV_FILE)([^A-Za-z0-9_]|$)'
TOMBSTONE_EXEMPT=(
  "bin/check-session-id-ssot.sh"
  "tests/bin/bin-check-session-id-ssot.sh"
  "hooks/lib/temporary-migrations/legacy-session-id-relay-purge.js"
  "tests/hooks/legacy-session-id-relay-purge.sh"
  "docs/architecture/claude-code/session-id-resolution.md"
  "tests/lib/harness.sh"
  "bin/lib/run-tests-baseline-exec.sh"
  "tests/bin/feature-step-durations.sh"
  "tests/hooks/feat-2511-session-relocation.sh"
  "tests/hooks/feature-confirm-checkpoint.sh"
  "tests/hooks/fix-524-confirm-plan-guard.sh"
  "tests/lib/plan-sync-fixture.sh"
)

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
    for a in "${ALLOWLIST[@]}"; do
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
    for e in "${TOMBSTONE_EXEMPT[@]}"; do
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

TOMBSTONES=0
if [ "${#TSCAN[@]}" -gt 0 ]; then
    scan_grep "$TOMBSTONE_RE" "${TSCAN[@]}"
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
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
