#!/bin/bash
# npm.sh - Update npm itself to latest. Never fails the installer: every path exits 0.

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ -z "${C_RESET+x}" ]; then
    if [ -t 1 ]; then
        C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_GRAY='\033[0;90m'; C_RESET='\033[0m'
    else
        C_GREEN=''; C_YELLOW=''; C_GRAY=''; C_RESET=''
    fi
fi

NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
if [ -s "$NVM_DIR/nvm.sh" ]; then
    . "$NVM_DIR/nvm.sh"
fi

_npm_manual="Run manually: npm install -g npm@latest"

if ! command -v npm >/dev/null 2>&1; then
    printf "${C_YELLOW}npm not found. npm update skipped.${C_RESET}\n" >&2
    exit 0
fi

# Pre-check A: skip package-manager-managed or unwritable installs.
_npm_root="$(npm root -g </dev/null 2>/dev/null)"
_npm_prefix="$(npm prefix -g </dev/null 2>/dev/null)"
_npm_dir="$_npm_root/npm"
_npm_real="$(cd -P "$_npm_dir" 2>/dev/null && pwd -P)"
case "$_npm_real" in
    */Cellar/*|*/Homebrew/*|/usr/lib/*|/usr/share/*)
        printf "${C_YELLOW}npm is managed by a package manager; skipping update. ${_npm_manual}${C_RESET}\n" >&2
        exit 0
        ;;
esac
if [ -z "$_npm_root" ] || [ ! -w "$_npm_root" ] || [ ! -w "$_npm_dir" ] || [ ! -w "$_npm_prefix/bin" ]; then
    printf "${C_YELLOW}npm global location is not writable; skipping update. ${_npm_manual}${C_RESET}\n" >&2
    exit 0
fi

# Pre-check B: the incoming npm must support the current Node.
if ! _npm_range="$(npm view npm@latest engines.node </dev/null 2>/dev/null)"; then
    printf "${C_YELLOW}Could not read the latest npm requirements; skipping update. ${_npm_manual}${C_RESET}\n" >&2
    exit 0
fi
_npm_check_rc=0
node "$SCRIPT_CHECKOUT_ROOT/install/lib/npm-engine-check.js" "$_npm_range" || _npm_check_rc=$?
if [ "$_npm_check_rc" -eq 1 ]; then
    printf "${C_YELLOW}Latest npm does not support the current Node (%s); skipping update. %s${C_RESET}\n" "$_npm_range" "$_npm_manual" >&2
    exit 0
elif [ "$_npm_check_rc" -ne 0 ]; then
    printf "${C_YELLOW}Could not verify npm/Node compatibility; skipping update. ${_npm_manual}${C_RESET}\n" >&2
    exit 0
fi

echo "Updating npm (latest)..."
if npm install -g npm@latest </dev/null; then
    printf "${C_GREEN}npm is up to date.${C_RESET}\n"
else
    printf "${C_YELLOW}npm update failed; keeping the installed version. ${_npm_manual}${C_RESET}\n" >&2
fi
exit 0
