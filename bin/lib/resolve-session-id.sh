#!/usr/bin/env bash
# Shared helper: resolve current Claude Code session-id by scanning
# ~/.claude/projects/<encoded-cwd>/ JSONL transcript directory.
#
# Source this file: source "$(dirname "${BASH_SOURCE[0]}")/resolve-session-id.sh"
# Provides:
#   encode_path_for_claude_projects <abs-path>  → stdout encoded dir name
#   _scan_one_transcript_dir <dir>              → stdout session-id (rc=1 on miss)
#   resolve_session_id_from_jsonl               → stdout session-id (rc=1 on miss)

encode_path_for_claude_projects() {
    local p="${1:-}"
    [ -z "$p" ] && return 1
    # Normalize backslashes to forward slashes (Windows native paths).
    p=$(printf '%s' "$p" | LC_ALL=C tr '\\' '/')
    # Normalize Git Bash POSIX drive (/c/... → c:/...). Single ASCII letter only.
    p=$(printf '%s' "$p" | LC_ALL=C sed 's#^/\([a-zA-Z]\)/#\1:/#')
    # Strip trailing slashes, but only when at least one non-slash char remains.
    local stripped
    stripped=$(printf '%s' "$p" | LC_ALL=C sed 's#/*$##')
    if [ -n "$stripped" ]; then
        p="$stripped"
    fi
    # Lowercase + non-alnum → single dash (UNCHANGED — matches Claude Code's encoding).
    printf '%s' "$p" | LC_ALL=C tr '[:upper:]' '[:lower:]' \
        | LC_ALL=C sed 's/[^a-z0-9]/-/g'
}

_scan_one_transcript_dir() {
    local dir="${1:-}"
    [ -d "$dir" ] || return 1
    local newest
    newest=$(ls -1t "$dir"/*.jsonl 2>/dev/null | head -1)
    [ -n "$newest" ] || return 1
    local name
    name=$(basename "$newest" .jsonl)
    case "$name" in
        *[!A-Za-z0-9_-]*) return 1 ;;
    esac
    [ -n "$name" ] || return 1
    printf '%s' "$name"
}

resolve_session_id_from_jsonl() {
    local base="${CLAUDE_TRANSCRIPT_BASE_DIR:-$HOME/.claude/projects}"
    local candidates=()
    # Priority 1: CLAUDE_PROJECT_DIR (CC-native path — correct encoding on Windows)
    if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
        candidates+=("$CLAUDE_PROJECT_DIR")
    fi
    # Priority 2: pwd (may differ from CC-native on Windows/Git-Bash)
    local pwd_val
    pwd_val=$(pwd 2>/dev/null) && candidates+=("$pwd_val")
    # Priority 3: realpath(pwd) — resolves symlinks
    if command -v realpath >/dev/null 2>&1; then
        local rp
        rp=$(realpath "$pwd_val" 2>/dev/null) && [ "$rp" != "$pwd_val" ] && candidates+=("$rp")
    fi
    local cwd encoded dir sid
    for cwd in "${candidates[@]}"; do
        encoded=$(encode_path_for_claude_projects "$cwd") || continue
        [ -z "$encoded" ] && continue
        dir="$base/$encoded"
        if sid=$(_scan_one_transcript_dir "$dir"); then
            printf '%s' "$sid"
            return 0
        fi
    done
    return 1
}
