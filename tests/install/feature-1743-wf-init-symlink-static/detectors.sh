# Sourced by tests/install/feature-1743-wf-init-symlink-static.sh outside any case span:
# content-derived detectors shared by several cases (each reads the file passed to it, every call).

# Windows: a $links entry whose Source is skills\workflow-init and Dest is skills\wf-init.
has_win_entry() {
    local file="$1"
    [ -f "$file" ] || return 1
    grep -Eq 'Source[[:space:]]*=[[:space:]]*"skills[\\/]workflow-init"[^#]*skills[\\/]wf-init' "$file"
}

# Windows: the same entry, with Dest anchored under the repo root ($SCRIPT_CHECKOUT_ROOT).
# The whole point of this alias is that it is repo-internal — every other entry in the
# same $links table targets $ClaudeDir, so an accidental $ClaudeDir Dest here would look
# plausible and still be wrong (CPR-ORTH orthogonality: this member differs by design).
has_win_dest_under_agents_root() {
    local file="$1"
    [ -f "$file" ] || return 1
    grep -Eq 'Source[[:space:]]*=[[:space:]]*"skills[\\/]workflow-init"[^#]*Dest[[:space:]]*=[[:space:]]*"\$SCRIPT_CHECKOUT_ROOT[\\/]skills[\\/]wf-init"' "$file"
}

# Windows: the wrong-root regression — Dest pointing under $ClaudeDir instead.
has_win_dest_under_claude_dir() {
    local file="$1"
    [ -f "$file" ] || return 1
    grep -Eq 'Source[[:space:]]*=[[:space:]]*"skills[\\/]workflow-init"[^#]*Dest[[:space:]]*=[[:space:]]*"\$ClaudeDir[\\/]' "$file"
}

# POSIX: a _link_one call with skills/workflow-init as source and skills/wf-init as dest.
has_sh_entry() {
    local file="$1"
    [ -f "$file" ] || return 1
    grep -Eq '_link_one[[:space:]]+.*skills/workflow-init.*skills/wf-init' "$file"
}

# --- CC process guard (issue #2284) ---
# Both dotfileslink installers must wait for a live Claude Code process to exit before
# rewriting settings.json, and skip the assemble-settings.js call when the wait times
# out. Detector shape: the wait-cc-exit reference precedes the assemble-settings call,
# with a skip (exit 0 / return) between the two.

# Line number of the first *executable* wait-cc-exit reference; empty when absent.
# A commented-out reference is documentation, never a guard.
_wait_ref_line() {
    local file="$1"
    [ -f "$file" ] || return 0
    grep -nE 'wait-cc-exit\.(sh|ps1)' "$file" \
        | grep -vE '^[0-9]+:[[:space:]]*#' | head -n1 | cut -d: -f1
}

# Line number of the assemble-settings.js invocation; empty when absent.
_assemble_line() {
    local file="$1"
    [ -f "$file" ] || return 0
    grep -nE 'assemble-settings\.js' "$file" | head -n1 | cut -d: -f1
}

# The guard must run before the write.
_guard_precedes_assemble() {
    local file="$1" w a
    w="$(_wait_ref_line "$file")"
    a="$(_assemble_line "$file")"
    [ -n "$w" ] && [ -n "$a" ] && [ "$w" -lt "$a" ]
}

# On timeout the write must be skipped: a skip path must appear in the guard's immediate
# neighbourhood (bounded to 6 lines) and the guard's exit code must be consumed by a branch.
# Scanning the whole range from guard to assemble is a false-green trap because
# dotfileslink.sh already contains unrelated `exit 0` and `return` lines in that span.
#
# Narrow skip (both platforms since #2476): assemble sits inside the success branch, so
# hooksPath/launchers still run on a timeout. The exit-on-timeout form stays accepted.
#   POSIX narrow: `if bash .../wait-cc-exit.sh; then assemble; fi`
#   PS narrow:    `& pwsh … wait-cc-exit.ps1` then `if ($LASTEXITCODE -eq 0) { assemble }`
#   exit form:    `if ! bash …; then … exit 0; fi` / `|| { …; exit 0; }` / PS `-ne 0 { …; exit 0 }`
_guard_skips_assemble() {
    local file="$1" w a to _bound=false _guard_line
    w="$(_wait_ref_line "$file")"
    a="$(_assemble_line "$file")"
    [ -n "$w" ] && [ -n "$a" ] && [ "$w" -lt "$a" ] || return 1

    _guard_line="$(sed -n "${w}p" "$file")"

    # Pattern 2 — narrow skip: POSIX positive `if` on the guard line, or PS
    # `if ($LASTEXITCODE -eq 0)` within 3 lines; assemble within 6 lines either way.
    if printf '%s' "$_guard_line" | grep -Eq '^[[:space:]]*if[[:space:]]' \
    && ! printf '%s' "$_guard_line" | grep -q '!' \
    && [ "$((a - w))" -le 6 ]; then
        return 0
    fi
    if sed -n "$((w + 1)),$((w + 3))p" "$file" \
        | grep -Eq 'if[[:space:]]*\([[:space:]]*\$LASTEXITCODE[[:space:]]+-eq[[:space:]]+0[[:space:]]*\)' \
    && [ "$((a - w))" -le 6 ]; then
        return 0
    fi

    # Pattern 1 — exit-on-timeout: guard bound + exit 0 within 6 lines.
    # Guard exit code must be bound — POSIX (if/||) OR PowerShell ($LASTEXITCODE within 3 lines).
    printf '%s' "$_guard_line" | grep -Eq '(^[[:space:]]*(if|while|until)[[:space:]]|\|\|)' && _bound=true
    if ! $_bound; then
        sed -n "${w},$((w + 3))p" "$file" | grep -Eq '(\$LASTEXITCODE|if[[:space:]]*\()' || return 1
    fi
    to=$((w + 6))
    [ "$to" -ge "$a" ] && to=$((a - 1))
    [ "$to" -ge "$w" ] || return 1
    sed -n "${w},${to}p" "$file" \
        | grep -Eq '(exit[[:space:]]+0|(^|[[:space:]]|;|\{)return([[:space:]]|;|\}|$))'
}

# Line of the DOTFILESLINK_LINKS_ONLY early-exit — the scope anchor for the guard.
# The guard must appear AFTER this line so a timeout skips only the settings write,
# not symlink creation or links-only mode.
_dotfiles_links_only_line() {
    local file="$1"
    [ -f "$file" ] || return 0
    grep -n 'DOTFILESLINK_LINKS_ONLY' "$file" \
        | grep -vE '^[0-9]+:[[:space:]]*#' | tail -n1 | cut -d: -f1
}

# Guard must appear AFTER the DOTFILESLINK_LINKS_ONLY exit.
_guard_scope_ok_dotfiles() {
    local file="$1" w sl
    w="$(_wait_ref_line "$file")"
    sl="$(_dotfiles_links_only_line "$file")"
    [ -n "$w" ] && [ -n "$sl" ] && [ "$w" -gt "$sl" ]
}

# _skip_probe <name> <file> <want 0|1> <what>: _guard_skips_assemble must return <want>.
_skip_probe() {
    local got=0
    _guard_skips_assemble "$2" && got=1
    if [ "$got" = "$3" ]; then pass "$1: skip detector returns $got — $4"
    else fail "$1: skip detector returned $got, expected $3 — $4"; fi
}
