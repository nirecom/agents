#!/bin/bash
# Agents framework installer for Linux/macOS
# Usage: ./install.sh [--develop] [--full]
#   --develop : also install Codex CLI

set -euo pipefail

# Colors (only when stdout is a terminal)
if [ -t 1 ]; then
    C_CYAN='\033[0;36m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'
    C_GRAY='\033[0;90m'; C_BOLD='\033[1m'; C_RESET='\033[0m'
else
    C_CYAN=''; C_GREEN=''; C_YELLOW=''; C_GRAY=''; C_BOLD=''; C_RESET=''
fi
export C_CYAN C_GREEN C_YELLOW C_GRAY C_BOLD C_RESET

_uname_s="$(uname -s)"
if [[ "$_uname_s" == MINGW* || "$_uname_s" == MSYS* || "$_uname_s" == CYGWIN* ]]; then
    printf "${C_YELLOW}Windows shell environment detected (%s). Use install.ps1 instead.${C_RESET}\n" "$_uname_s"
    exit 1
fi
unset _uname_s

AGENTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OPT_DEVELOP=false
for _arg in "$@"; do
  case "$_arg" in
    --develop|--full|--base|--toolchain) OPT_DEVELOP=true ;;
  esac
done
unset _arg

printf "${C_CYAN}=== agents installer ===${C_RESET}\n"

echo ""
printf -- "${C_BOLD}--- Checking Node.js (nvm) ---${C_RESET}\n"
NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    printf "${C_YELLOW}nvm not found. Installing nvm...${C_RESET}\n"
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash -s -- --skip-shell
    echo ""
    echo "Restart your terminal and re-run install.sh."
    exit 1
fi
. "$NVM_DIR/nvm.sh"
if ! type npm >/dev/null 2>&1; then
    printf "${C_YELLOW}Error: nvm is installed but npm not found. Run: nvm install --lts${C_RESET}\n" >&2
    exit 1
fi

echo ""
printf -- "${C_BOLD}--- Creating symlinks ---${C_RESET}\n"
"$AGENTS_ROOT/install/linux/dotfileslink.sh"

echo ""
printf -- "${C_BOLD}--- Installing Claude Code ---${C_RESET}\n"
"$AGENTS_ROOT/install/linux/claude-code.sh"
export PATH="$HOME/.local/bin:$PATH"

if [ "$OPT_DEVELOP" = true ]; then
    echo ""
    printf -- "${C_BOLD}--- Installing Codex ---${C_RESET}\n"
    "$AGENTS_ROOT/install/linux/codex.sh"
fi

echo ""
printf -- "${C_BOLD}--- Initializing Claude Code session sync ---${C_RESET}\n"
# --- BEGIN session-sync gate ---
# One-time idempotent bootstrap (git init, .gitattributes/.gitignore write, remote
# add/set-url) — runs unconditionally whenever Claude Code is present, independent of
# the SESSION_SYNC toggle, which gates only *automatic* sync (see profile-snippet.sh).
# Manual `session-sync push/pull/status/reset` depends on this bootstrap having run.
if ! type claude >/dev/null 2>&1; then
    printf "${C_YELLOW}Claude Code not found. Session sync skipped.${C_RESET}\n"
else
    "$AGENTS_ROOT/install/linux/session-sync-init.sh"
fi
# --- END session-sync gate ---

echo ""
printf -- "${C_BOLD}--- Adding profile sourcing ---${C_RESET}\n"
case "${SHELL##*/}" in
    zsh)  _rc_file="${HOME}/.zshrc" ;;
    bash) _rc_file="${HOME}/.bashrc" ;;
    *)    _rc_file="${HOME}/.profile" ;;
esac
_snippet_path="$AGENTS_ROOT/profile-snippet.sh"
_marker="# --- BEGIN agents profile sourcing ---"
_need_restart=false
if ! grep -qF "$_marker" "$_rc_file" 2>/dev/null; then
    printf '\n%s\n. "%s"\n# --- END agents profile sourcing ---\n' \
        "$_marker" "$_snippet_path" >> "$_rc_file"
    printf "${C_GREEN}Added profile sourcing to $_rc_file${C_RESET}\n"
    _need_restart=true
else
    perl -i -pe "s|^\\. \\\".*profile-snippet\\.sh\\\"|. \\\"$_snippet_path\\\"|" "$_rc_file"
    printf "${C_GRAY}Profile sourcing already present in $_rc_file (path updated if needed)${C_RESET}\n"
fi
_rc_file_msg="$_rc_file"
unset _rc_file _snippet_path _marker

echo ""
printf -- "${C_BOLD}--- Configuring VS Code settings (GitHub Copilot / Claude Code) ---${C_RESET}\n"
"$AGENTS_ROOT/install/linux/vscode-settings.sh"

echo ""
printf -- "${C_BOLD}--- Setting up global gitignore (WORKTREE_NOTES.md) ---${C_RESET}\n"
"$AGENTS_ROOT/install/linux/global-gitignore.sh"

echo ""
printf -- "${C_BOLD}--- Installing gh (GitHub CLI) ---${C_RESET}\n"
"$AGENTS_ROOT/install/linux/gh.sh"

echo ""
printf -- "${C_BOLD}--- Installing jq ---${C_RESET}\n"
"$AGENTS_ROOT/install/linux/jq.sh"

echo ""
printf -- "${C_BOLD}--- Installing shellcheck ---${C_RESET}\n"
"$AGENTS_ROOT/install/linux/shellcheck.sh"

echo ""
printf -- "${C_BOLD}--- Configuring CodeGraph ---${C_RESET}\n"
"$AGENTS_ROOT/install/linux/codegraph.sh"

echo ""
printf "${C_GREEN}=== Done ===${C_RESET}\n"
if [ "$_need_restart" = "true" ]; then
    echo "Restart your shell or run: source $_rc_file_msg"
fi
