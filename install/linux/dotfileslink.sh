#!/bin/bash
# dotfileslink.sh - Create ~/.claude/ symlinks, set git hooksPath, write profile snippet
# Usage: Called by install.sh, or run manually

set -euo pipefail

AGENTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ -z "${C_RESET+x}" ]; then
    if [ -t 1 ]; then
        C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_GRAY='\033[0;90m'; C_RESET='\033[0m'
    else
        C_GREEN=''; C_YELLOW=''; C_GRAY=''; C_RESET=''
    fi
fi

_dl_is_windows=0
case "${OS:-}${MSYSTEM:-}" in
    *Windows_NT*|*MINGW*|*MSYS*|*CYGWIN*) _dl_is_windows=1 ;;
esac
if [ "$_dl_is_windows" = "1" ]; then
    export MSYS=winsymlinks:nativestrict
fi

# _link_one: transactional symlink creation with rollback.
# Returns 0 on success, 1 on failure (never `exit`s). Caller decides whether to continue.
_link_one() {
    local source="$1" dest="$2"
    [ -e "$source" ] || { printf "${C_YELLOW}Source not found: %s (skipping)${C_RESET}\n" "$source" >&2; return 0; }
    _norm() {
        if [ "$_dl_is_windows" = "1" ] && command -v cygpath >/dev/null 2>&1; then
            cygpath -u "$1" 2>/dev/null
        elif command -v realpath >/dev/null 2>&1; then
            realpath -m "$1" 2>/dev/null
        else
            printf '%s' "$1"
        fi
    }
    local _rollback="none"   # none | restore-symlink | restore-file
    local _old_target=""
    local _bak=""
    local _tmp_bak=""
    if [ -L "$dest" ]; then
        local cur; cur="$(readlink "$dest" 2>/dev/null || true)"
        if [ "$(_norm "$cur")" = "$(_norm "$source")" ] \
                || { [ "$dest" -ef "$source" ] 2>/dev/null; }; then
            printf "${C_GRAY}Already linked: %s${C_RESET}\n" "$dest"; return 0
        fi
        printf "${C_YELLOW}Relinking: %s${C_RESET}\n" "$dest"
        _old_target="$cur"
        _rollback="restore-symlink"
        if ! rm -f "$dest"; then
            printf "${C_YELLOW}Failed to remove existing symlink: %s${C_RESET}\n" "$dest" >&2
            return 1
        fi
    elif [ -e "$dest" ]; then
        local _is_jct=0
        if [ "$_dl_is_windows" = "1" ] && [ -d "$dest" ] && command -v cmd.exe >/dev/null 2>&1; then
            local _wpar _base
            _wpar="$(cygpath -w "$(dirname "$dest")" 2>/dev/null || dirname "$dest")"
            _base="$(basename "$dest")"
            local _base_re
            _base_re="$(printf '%s' "$_base" | sed 's/[][\\.*^$(){}?+|/]/\\&/g')"
            if cmd.exe //c "dir /AL \"$_wpar\"" 2>/dev/null \
                    | grep -qE "(<JUNCTION>|<SYMLINKD>)[[:space:]]+$_base_re( |$)"; then
                _is_jct=1
            fi
        fi
        if [ "$_is_jct" = "1" ]; then
            if [ "$dest" -ef "$source" ] 2>/dev/null; then
                printf "${C_GRAY}Junction already correct: %s${C_RESET}\n" "$dest"; return 0
            fi
            printf "${C_YELLOW}Removing junction: %s${C_RESET}\n" "$dest"
            if ! rmdir "$dest" 2>/dev/null; then
                if cmd.exe //c "dir /AL \"$_wpar\"" 2>/dev/null \
                        | grep -qE "(<JUNCTION>|<SYMLINKD>)[[:space:]]+$_base_re( |$)"; then
                    rm -rf "$dest" || { printf "${C_YELLOW}Failed to remove junction: %s${C_RESET}\n" "$dest" >&2; return 1; }
                else
                    printf "${C_YELLOW}Refused rm -rf: %s no longer detected as junction${C_RESET}\n" "$dest" >&2
                    return 1
                fi
            fi
            # Junction rollback is best-effort; original target is not reliably captured.
        else
            _bak="${dest}.bak"
            _tmp_bak="${dest}.bak.tmp.$$"
            printf "${C_YELLOW}Backing up: %s -> %s${C_RESET}\n" "$dest" "$_bak"
            if ! mv "$dest" "$_tmp_bak"; then
                printf "${C_YELLOW}Backup failed: %s${C_RESET}\n" "$dest" >&2
                return 1
            fi
            _rollback="restore-file"
        fi
    fi
    if ! ln -s "$source" "$dest" 2>/dev/null; then
        case "$_rollback" in
            restore-symlink)
                ln -s "$_old_target" "$dest" 2>/dev/null || true
                ;;
            restore-file)
                mv "$_tmp_bak" "$dest" 2>/dev/null || true
                ;;
        esac
        printf "${C_YELLOW}Failed to link: %s (rollback applied)${C_RESET}\n" "$dest" >&2
        return 1
    fi
    # ln succeeded — promote the new backup transactionally so the old .bak
    # survives any failure of the final mv (HIGH-2 from codex review).
    if [ "$_rollback" = "restore-file" ]; then
        local _old_bak="${_bak}.old.$$"
        local _had_old_bak=0
        if [ -e "$_bak" ]; then
            _had_old_bak=1
            mv "$_bak" "$_old_bak" || {
                printf "${C_YELLOW}Backup promotion failed: cannot stage old .bak (%s retained, new .bak at %s)${C_RESET}\n" "$_bak" "$_tmp_bak" >&2
                return 1
            }
        fi
        if ! mv "$_tmp_bak" "$_bak"; then
            [ "$_had_old_bak" = "1" ] && mv "$_old_bak" "$_bak" 2>/dev/null || true
            printf "${C_YELLOW}Backup promotion failed: %s (old .bak retained)${C_RESET}\n" "$dest" >&2
            return 1
        fi
        [ "$_had_old_bak" = "1" ] && rm -rf "$_old_bak"
    fi
    printf "${C_GREEN}Linked: %s -> %s${C_RESET}\n" "$dest" "$source"
    return 0
}

# --- ~/.claude/ symlinks ---
mkdir -p ~/.claude

if [ -d ~/.claude/.git ]; then
    echo "WARNING: ~/.claude is a git repo. Remove .git to enable symlinks." >&2
else
    if [ -L ~/.claude/commands ]; then
        printf "${C_YELLOW}Removing obsolete symlink: ~/.claude/commands${C_RESET}\n"
        rm -f ~/.claude/commands
    fi
    # Track per-link failures; aggregate non-zero exit signals install.sh failure.
    _link_failed=0
    _link_one "$AGENTS_ROOT/CLAUDE.md"  "$HOME/.claude/CLAUDE.md"   || _link_failed=$((_link_failed+1))
    _link_one "$AGENTS_ROOT/skills"     "$HOME/.claude/skills"      || _link_failed=$((_link_failed+1))
    _link_one "$AGENTS_ROOT/rules"      "$HOME/.claude/rules"       || _link_failed=$((_link_failed+1))
    _link_one "$AGENTS_ROOT/agents"     "$HOME/.claude/agents"      || _link_failed=$((_link_failed+1))
    # Remove stale settings.json symlink that used to point directly into agents/
    if [ -L ~/.claude/settings.json ]; then
        printf "${C_YELLOW}Removing stale symlink: ~/.claude/settings.json${C_RESET}\n"
        rm -f ~/.claude/settings.json
    fi
    if [ "$_link_failed" -gt 0 ]; then
        printf "${C_YELLOW}Symlink failures: %d${C_RESET}\n" "$_link_failed" >&2
        exit 1
    fi
    printf "${C_GREEN}Symlinks created in ~/.claude/${C_RESET}\n"
fi

# /wf-init alias for /workflow-init (#1743): intra-repo symlink so autocomplete
# picks up a short name — /workflow-launch-exec (an unowned built-in) otherwise
# wins the `/wor` completion. Not a native Skill alias field (none exists);
# this is a second directory name resolving to the same SKILL.md. Placed
# outside the ~/.claude/.git guard above since this link stays within
# $AGENTS_ROOT and is unrelated to the ~/.claude destination tree.
_link_one "$AGENTS_ROOT/skills/workflow-init" "$AGENTS_ROOT/skills/wf-init" \
    || printf "${C_YELLOW}Symlink failure: skills/wf-init${C_RESET}\n" >&2

# Test affordance — see tests/feature-697-dotfileslink-link-one.sh
[ "${DOTFILESLINK_LINKS_ONLY:-0}" = "1" ] && exit 0

# --- Assemble ~/.claude/settings.json from base + extension ---
if ! type node >/dev/null 2>&1; then
    _dl_nvm_dir="${NVM_DIR:-$HOME/.nvm}"
    [ -s "$_dl_nvm_dir/nvm.sh" ] && . "$_dl_nvm_dir/nvm.sh"
    unset _dl_nvm_dir
fi
if ! type node >/dev/null 2>&1; then
    printf "${C_YELLOW}Error: node not found. Run: nvm install --lts${C_RESET}\n" >&2
    exit 1
fi
node "$AGENTS_ROOT/install/assemble-settings.js"

# --- git core.hooksPath ---
git config --file "$HOME/.gitconfig" core.hooksPath "$AGENTS_ROOT/hooks"
printf "${C_GREEN}core.hooksPath -> $AGENTS_ROOT/hooks${C_RESET}\n"

# --- ~/.local/bin/doc-append launcher ---
mkdir -p ~/.local/bin
cat > ~/.local/bin/doc-append << 'LAUNCHER_EOF'
#!/usr/bin/env bash
export MSYS_NO_PATHCONV=1
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
AGENTS_ROOT_RESOLVED="${AGENTS_CONFIG_DIR:-}"
if [ -z "$AGENTS_ROOT_RESOLVED" ] && [ -f "$SCRIPT_DIR/../agents/bin/doc-append.py" ]; then
    AGENTS_ROOT_RESOLVED="$SCRIPT_DIR/.."
fi
if [[ -z "${1:-}" || "${1:-}" == --* ]]; then
    exec uv run "${AGENTS_ROOT_RESOLVED}/bin/doc-append.py" "docs/history.md" "$@"
else
    exec uv run "${AGENTS_ROOT_RESOLVED}/bin/doc-append.py" "$@"
fi
LAUNCHER_EOF
# Rewrite with the actual path now that we know AGENTS_ROOT
cat > ~/.local/bin/doc-append << EOF
#!/usr/bin/env bash
export MSYS_NO_PATHCONV=1
if [[ -z "\${1:-}" || "\${1:-}" == --* ]]; then
  exec uv run "$AGENTS_ROOT/bin/doc-append.py" "docs/history.md" "\$@"
else
  exec uv run "$AGENTS_ROOT/bin/doc-append.py" "\$@"
fi
EOF
chmod +x ~/.local/bin/doc-append
printf "${C_GREEN}Generated: ~/.local/bin/doc-append${C_RESET}\n"

# --- ~/.local/bin/doc-append-plain launcher ---
cat > ~/.local/bin/doc-append-plain << EOF
#!/usr/bin/env bash
exec uv run "$AGENTS_ROOT/bin/doc-append-plain.py" "\$@"
EOF
chmod +x ~/.local/bin/doc-append-plain
printf "${C_GREEN}Generated: ~/.local/bin/doc-append-plain${C_RESET}\n"

# --- ~/.local/bin/repo-visibility launcher ---
cat > ~/.local/bin/repo-visibility << EOF
#!/usr/bin/env bash
exec uv run "$AGENTS_ROOT/bin/repo-visibility.py" "\$@"
EOF
chmod +x ~/.local/bin/repo-visibility
printf "${C_GREEN}Generated: ~/.local/bin/repo-visibility${C_RESET}\n"

# --- BEGIN temporary: cc-session-title launcher cleanup ---
# Remove stale launchers from the cc-session-title removal (PRs #303, #313, #331).
# Idempotent: rm -f silently no-ops when the file is absent.
# Safe to delete this block after all developer machines have run dotfileslink once.
for stale in ~/.local/bin/cc-session-title ~/.local/bin/cc-session-title.cmd ~/.local/bin/cc-session-title.py; do
    if [ -e "$stale" ] || [ -L "$stale" ]; then
        rm -f "$stale"
        printf "${C_YELLOW}Removed stale launcher: $stale${C_RESET}\n"
    fi
done
# --- END temporary: cc-session-title launcher cleanup ---

# --- PATH-exposed bin/ command symlinks ---
# The command set is declared once in install/path-exposed-commands.txt and looped over
# here; install/win/dotfileslink.ps1 consumes the same file (CPR-SSOT single source of truth,
# CPR-ORTH both platforms expose the same set). Do NOT hand-write an `ln -sf` below —
# add the command name to the list file instead.
_path_exposed_list="$AGENTS_ROOT/install/path-exposed-commands.txt"
if [[ ! -f "$_path_exposed_list" ]]; then
    printf "${C_YELLOW}Command list not found: %s (skipping)${C_RESET}\n" "$_path_exposed_list" >&2
    _path_exposed_list=/dev/null
fi
while IFS= read -r _cmd || [[ -n "$_cmd" ]]; do
    _cmd="${_cmd%$'\r'}"
    _cmd="${_cmd#"${_cmd%%[![:space:]]*}"}"
    _cmd="${_cmd%"${_cmd##*[![:space:]]}"}"
    [[ -n "$_cmd" ]] || continue
    [[ "$_cmd" == \#* ]] && continue
    ln -sf "$AGENTS_ROOT/bin/$_cmd" "$HOME/.local/bin/$_cmd"
    printf "${C_GREEN}Symlinked: ~/.local/bin/%s${C_RESET}\n" "$_cmd"
done < "$_path_exposed_list"
unset _cmd _path_exposed_list
