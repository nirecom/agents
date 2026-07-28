# bin/lib/gh-outbound-guard.sh
#
# Purpose: shared fail-closed outbound-content scan guard for scripts that hand
# free text (issue title/body, commit message, file content) to `gh` / `gh api`.
# The `scan-outbound.js` PreToolUse hook only inspects the literal Bash-tool
# command string, so content produced *inside* a wrapper script never reaches it.
# This library closes that gap at the last point before the outbound call.
#
# Function contract:
#   gh_outbound_guard <label>   — reads content from stdin, scans it via
#   bin/scan-outbound.sh --stdin <label>.
#     return 0 = clean (caller may proceed)
#     return 1 = block (caller must abort)
#   The block reason is stored in the parent-scope GH_OUTBOUND_GUARD_MESSAGE
#   variable (and echoed to stderr).
#
# This library NEVER calls `exit` — only `return`. It is sourced, so exiting
# would kill the caller's shell, traps, and errexit handling.
#
# Callers MUST invoke it with input redirection:
#     gh_outbound_guard "<label>" < "$file"      # or process substitution
# NEVER on the right-hand side of a pipe: a pipe RHS runs in a subshell, so the
# GH_OUTBOUND_GUARD_MESSAGE assignment would not propagate back to the caller.
#
# Fail-closed by design: warn-tier (rc 2), usage error (rc 3), and an
# unresolvable scanner are all treated as BLOCK. These scripts run
# non-interactively (no TTY), matching the non-interactive convention in
# docs/scan-outbound.md. Sending unscanned content is never the safer default.

# _ghog_emit_abort <label> <rc> <scan_output>
# Builds the 3-part block message, assigns it to the (global)
# GH_OUTBOUND_GUARD_MESSAGE, and mirrors it to stderr.
_ghog_emit_abort() {
    local label="$1" rc="$2" scan_out="$3" tier
    case "$rc" in
        1) tier="hard violation" ;;
        2) tier="warn-tier match (non-interactive → treated as block)" ;;
        3) tier="usage error" ;;
        *) tier="scanner-error" ;;
    esac
    GH_OUTBOUND_GUARD_MESSAGE="gh_outbound_guard: BLOCKED outbound write for '${label}' — ${tier} (scanner rc=${rc}).
Matched by the scanner:
${scan_out}
Replace the matched content in '${label}' with a generic placeholder and retry (or add a per-file entry to .private-info-allowlist).
Bypassing this guard by other means (disabling hooks, calling gh directly, WORKFLOW_OFF, etc.) is prohibited — see feedback_no_security_gap_exploit."
    printf '%s\n' "$GH_OUTBOUND_GUARD_MESSAGE" >&2
}

gh_outbound_guard() {
    GH_OUTBOUND_GUARD_MESSAGE=""

    local label="${1:-stdin}"
    local scanner=""

    # AGENTS_CONFIG_DIR, when set, is authoritative — a missing scanner there is
    # a block (fail-closed), not a reason to reach for another copy.
    if [ -n "${AGENTS_CONFIG_DIR:-}" ]; then
        if [ -x "$AGENTS_CONFIG_DIR/bin/scan-outbound.sh" ]; then
            scanner="$AGENTS_CONFIG_DIR/bin/scan-outbound.sh"
        fi
    else
        local _ghog_libdir
        _ghog_libdir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
        if [ -n "$_ghog_libdir" ] && [ -x "$_ghog_libdir/scan-outbound.sh" ]; then
            scanner="$_ghog_libdir/scan-outbound.sh"
        fi
    fi

    if [ -z "$scanner" ]; then
        GH_OUTBOUND_GUARD_MESSAGE="gh_outbound_guard: BLOCKED outbound write for '${label}' — scan-outbound.sh could not be resolved (checked \$AGENTS_CONFIG_DIR/bin and this library's sibling bin/). Fail-closed: unscanned content is never sent.
Fix the scanner path (set AGENTS_CONFIG_DIR to the agents repo) and retry.
Bypassing this guard by other means is prohibited — see feedback_no_security_gap_exploit."
        printf '%s\n' "$GH_OUTBOUND_GUARD_MESSAGE" >&2
        return 1
    fi

    # Not `local`: the RETURN trap below must still see it while unwinding.
    _ghog_tmp=""
    _ghog_tmp="$(mktemp)" || {
        GH_OUTBOUND_GUARD_MESSAGE="gh_outbound_guard: BLOCKED outbound write for '${label}' — mktemp failed; cannot stage content for scanning (fail-closed)."
        printf '%s\n' "$GH_OUTBOUND_GUARD_MESSAGE" >&2
        return 1
    }
    trap 'rm -f "$_ghog_tmp"' RETURN

    cat > "$_ghog_tmp"

    local scan_out="" rc=0
    scan_out="$("$scanner" --stdin "$label" < "$_ghog_tmp" 2>&1)" || rc=$?

    if [ "$rc" -eq 0 ]; then
        return 0
    fi

    _ghog_emit_abort "$label" "$rc" "$scan_out"
    return 1
}
