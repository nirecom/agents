#!/bin/bash
# bin/github-issues/wip-state/session-id.sh — session-id resolution helpers.
# Sourced by ../wip-state.sh; not executable standalone.
# Globals consumed: CLAUDE_CODE_SESSION_ID, CLAUDE_ENV_FILE, CLAUDE_SESSION_ID, SID_SET, INJECTED_SID.

# Resolution order:
#   1. ${CLAUDE_CODE_SESSION_ID:-} non-empty → use directly. CC-native,
#      per-session-distinct, and reliably present in the Bash subprocess where
#      $CLAUDE_ENV_FILE is not propagated. Without it, resolution falls through
#      to the JSONL scan, which returns the most recently active OTHER session
#      in a concurrent environment (#1082).
#   2. $CLAUDE_ENV_FILE (readable) → grep CLAUDE_SESSION_ID — keeps native CLI
#      behavior where the env file is the canonical source.
#   3. ${CLAUDE_SESSION_ID:-} non-empty → use directly. VS Code Claude Code
#      does not propagate $CLAUDE_ENV_FILE to Bash subprocesses but does
#      propagate $CLAUDE_SESSION_ID, so this fallback restores WIP signaling
#      in that environment (#440). This convention is already established in
#      skills/issue-close-finalize/SKILL.md (--from-session uses the same
#      "file first, env fallback" order).
#   4. JSONL scan: mtime-newest ~/.claude/projects/<encoded-cwd>/*.jsonl basename.
#   5. None available → rc=2.
resolve_session_id() {
    local sid
    if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
        sid=$(printf '%s' "${CLAUDE_CODE_SESSION_ID:-}" | tr -d '\r"')
        if [ -n "$sid" ]; then
            printf '%s' "$sid"
            return 0
        fi
    fi
    if [ -n "${CLAUDE_ENV_FILE:-}" ] && [ -r "${CLAUDE_ENV_FILE}" ]; then
        sid=$(grep -E '^CLAUDE_SESSION_ID=' "$CLAUDE_ENV_FILE" 2>/dev/null \
                | head -1 | cut -d= -f2- | tr -d '\r"' )
        if [ -n "$sid" ]; then
            printf '%s' "$sid"
            return 0
        fi
    fi
    if [ -n "${CLAUDE_SESSION_ID:-}" ]; then
        sid=$(printf '%s' "${CLAUDE_SESSION_ID:-}" | tr -d '\r"')
        if [ -n "$sid" ]; then
            printf '%s' "$sid"
            return 0
        fi
    fi
    # 3. JSONL scan fallback — VS Code Claude Code does not export CLAUDE_SESSION_ID
    #    nor reliably propagate CLAUDE_ENV_FILE to Bash subprocesses (#519).
    if sid=$(resolve_session_id_from_jsonl); then
        sid=$(printf '%s' "$sid" | tr -d '\r"')
        if [ -n "$sid" ]; then
            printf '%s' "$sid"
            return 0
        fi
    fi
    echo "Error: CLAUDE_SESSION_ID not resolvable (neither \$CLAUDE_ENV_FILE nor \$CLAUDE_SESSION_ID is usable)" >&2
    return 2
}

validate_injected_sid() {
    local sid="$1"
    if [ -z "$sid" ]; then
        echo "Error: --session-id requires a non-empty value (empty string rejected; omit the flag to use default resolution chain)" >&2
        exit 2
    fi
    case "$sid" in
        *[!A-Za-z0-9_-]*) echo "Error: --session-id contains invalid characters (allowed: [A-Za-z0-9_-])" >&2; exit 2 ;;
    esac
    return 0
}

effective_session_id() {
    if [ "${SID_SET:-0}" -eq 1 ]; then
        validate_injected_sid "$INJECTED_SID"
        printf '%s' "$INJECTED_SID"
        return 0
    fi
    resolve_session_id
}
