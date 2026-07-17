#!/bin/bash
# bin/github-issues/wip-state/session-id.sh — session-id resolution helpers.
# Sourced by ../wip-state.sh; not executable standalone.
# Globals consumed: CLAUDE_CODE_SESSION_ID, CLAUDE_ENV_FILE, CLAUDE_SESSION_ID, SID_SET, INJECTED_SID.

# Resolution is delegated in full to the canonical JS resolver via the
# bin/resolve-session-id bridge (7-step chain + isSameGitRepo cross-repo guard;
# issue #1251). The bridge writes the resolved session-id to stdout (no trailing
# newline) and exits 0 on success, or exits 2 when unresolvable. This wrapper
# preserves the historical rc=2 contract by propagating the bridge's exit code.
resolve_session_id() {
    local sid rc _dir bridge
    _dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
    bridge="$_dir/../../resolve-session-id"
    sid=$(bash "$bridge" 2>/dev/null) || {
        rc=$?
        echo "Error: session id not resolvable (bin/resolve-session-id exhausted the chain: CLAUDE_CODE_SESSION_ID, CLAUDE_ENV_FILE, CLAUDE_SESSION_ID, WORKTREE_NOTES.md, JSONL scan)" >&2
        return "$rc"
    }
    if [ -z "$sid" ]; then
        echo "Error: session id not resolvable (bin/resolve-session-id exhausted the chain: CLAUDE_CODE_SESSION_ID, CLAUDE_ENV_FILE, CLAUDE_SESSION_ID, WORKTREE_NOTES.md, JSONL scan)" >&2
        return 2
    fi
    printf '%s' "$sid"
    return 0
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
