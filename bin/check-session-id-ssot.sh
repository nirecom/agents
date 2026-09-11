#!/usr/bin/env bash
# check-session-id-ssot.sh — static gate against session-id env reads that bypass the SSOT
# resolver (#2270). Scope is deliberately ONE construct: a Node `process.env` access to
# SESSION_ID / CLAUDE_SESSION_ID / CLAUDE_CODE_SESSION_ID, spelled dotted or bracket+literal.
# Bash `$VAR` expansion, computed `process.env[name]`, and WORKFLOW_SESSION_ID (a different
# namespace, read as a sanctioned override) are OUT of scope: none is statically separable
# from legitimate use, so flagging them would make the gate unusable. Completeness is NOT
# claimed — this stops new direct reads, it does not prove the tree has none.
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

NAMES="SESSION_ID|CLAUDE_SESSION_ID|CLAUDE_CODE_SESSION_ID"
READ_RE="process\\.env\\.($NAMES)([^A-Za-z0-9_]|\$)|process\\.env\\[[[:space:]]*[\"']($NAMES)[\"'][[:space:]]*\\]"
# A waiver needs a role AND a non-empty reason after the em dash; a bare marker is the
# rubber stamp this gate exists to prevent.
WAIVER_RE="session-id-ssot: waived \\([^)]*\\)[[:space:]]*—[[:space:]]*[^[:space:]]"

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

SCAN=()
for f in "${FILES[@]}"; do
    in_scope "$f" && SCAN+=("$f")
done
[ "${#SCAN[@]}" -eq 0 ] && exit 0

VIOLATIONS=0
while IFS= read -r hit; do
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
done < <(grep -I -n -H -E -- "$READ_RE" "${SCAN[@]}" 2>/dev/null || true)

if [ "$VIOLATIONS" -gt 0 ]; then
    echo ""
    echo "Direct session-id env reads bypass the SSOT resolver ($VIOLATIONS)."
    echo "Call resolveSessionId() instead, or add an inline waiver:"
    echo "  // session-id-ssot: waived (<role>) — <why the resolver cannot be used here>"
    echo "See docs/architecture/claude-code/session-id-resolution.md."
    exit 1
fi
exit 0
