#!/bin/bash
# npm.sh - Update npm itself to latest. Never fails the installer: every path exits 0.
# When the current Node cannot run the latest npm, Node is raised first (nvm).

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_engine_check="$SCRIPT_CHECKOUT_ROOT/install/lib/npm-engine-check.js"

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
_npm_not_latest="npm is NOT at latest."

# Raise the default Node (nvm) to a version latest npm supports: the newest of the current
# major when it qualifies, else the LTS. Returns 0 when the running Node now qualifies.
raise_node_for_npm() {
    local range="$1" old_node major target new_node
    command -v nvm >/dev/null 2>&1 || return 1
    old_node="$(node --version)"
    major="$(node -p "process.versions.node.split('.')[0]")"
    if target="$(nvm ls-remote --no-colors </dev/null 2>/dev/null | node "$_engine_check" --pick "$range" "$major")" && [ -n "$target" ]; then
        nvm install "$target" </dev/null || return 1
        nvm alias default "$target" >/dev/null || return 1
        nvm use "$target" >/dev/null || return 1
    else
        nvm install --lts </dev/null || return 1
        nvm alias default 'lts/*' >/dev/null || return 1
        nvm use --lts >/dev/null || return 1
    fi
    node "$_engine_check" "$range" || return 1
    new_node="$(node --version)"
    echo "Node raised from $old_node to $new_node so the latest npm can run."
    echo "Note: global npm packages the installer does not reinstall (installed by hand) are not visible to $new_node."
    return 0
}

if ! command -v npm >/dev/null 2>&1; then
    printf "${C_YELLOW}npm not found. ${_npm_not_latest} npm update skipped.${C_RESET}\n" >&2
    exit 0
fi

# Pre-check: the incoming npm must support the current Node; raise Node when it does not.
if ! _npm_range="$(npm view npm@latest engines.node </dev/null 2>/dev/null)"; then
    printf "${C_YELLOW}Could not read the latest npm requirements. ${_npm_not_latest} Skipping update. ${_npm_manual}${C_RESET}\n" >&2
    exit 0
fi
_npm_check_rc=0
node "$_engine_check" "$_npm_range" || _npm_check_rc=$?
if [ "$_npm_check_rc" -eq 1 ]; then
    if ! raise_node_for_npm "$_npm_range"; then
        printf "${C_YELLOW}Latest npm does not support the current Node (%s) and Node could not be raised. %s Skipping update. Raise Node (nvm install --lts; nvm alias default 'lts/*'), then %s${C_RESET}\n" "$_npm_range" "$_npm_not_latest" "$_npm_manual" >&2
        exit 0
    fi
elif [ "$_npm_check_rc" -ne 0 ]; then
    printf "${C_YELLOW}Could not verify npm/Node compatibility. ${_npm_not_latest} Skipping update. ${_npm_manual}${C_RESET}\n" >&2
    exit 0
fi

# Skip package-manager-managed or unwritable installs; checked on the Node npm will use.
_npm_root="$(npm root -g </dev/null 2>/dev/null)"
_npm_prefix="$(npm prefix -g </dev/null 2>/dev/null)"
_npm_dir="$_npm_root/npm"
_npm_real="$(cd -P "$_npm_dir" 2>/dev/null && pwd -P)"
case "$_npm_real" in
    */Cellar/*|*/Homebrew/*|/usr/lib/*|/usr/share/*)
        printf "${C_YELLOW}npm is managed by a package manager. ${_npm_not_latest} Skipping update. ${_npm_manual}${C_RESET}\n" >&2
        exit 0
        ;;
esac
if [ -z "$_npm_root" ] || [ ! -w "$_npm_root" ] || [ ! -w "$_npm_dir" ] || [ ! -w "$_npm_prefix/bin" ]; then
    printf "${C_YELLOW}npm global location is not writable. ${_npm_not_latest} Skipping update. ${_npm_manual}${C_RESET}\n" >&2
    exit 0
fi

echo "Updating npm (latest)..."
if npm install -g npm@latest </dev/null; then
    printf "${C_GREEN}npm is up to date.${C_RESET}\n"
else
    printf "${C_YELLOW}npm update failed. ${_npm_not_latest} Keeping the installed version. ${_npm_manual}${C_RESET}\n" >&2
fi
exit 0
