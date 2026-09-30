#!/bin/bash
# codegraph.sh - Reconcile CodeGraph to the state CODEGRAPH asks for (install+register / unregister)
export SYSTEM_OPS_APPROVED=1

AGENTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ -z "${C_RESET+x}" ]; then
    if [ -t 1 ]; then
        C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_GRAY='\033[0;90m'; C_RESET='\033[0m'
    else
        C_GREEN=''; C_YELLOW=''; C_GRAY=''; C_RESET=''
    fi
fi

# The telemetry pair in install/codegraph-constants.txt is NOT exported here:
# it would leak into every child. codegraph-mcp.js hands it to its own children.

NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
if [ -s "$NVM_DIR/nvm.sh" ]; then
    . "$NVM_DIR/nvm.sh"
fi

if ! command -v node >/dev/null 2>&1; then
    printf "${C_YELLOW}node not found. CodeGraph step skipped.${C_RESET}\n" >&2
    exit 0
fi

# CODEGRAPH is opt-in (default off): exit 1 means explicit ON; every other exit
# (off / unset / unrecognized / internal failure) resolves to OFF.
_cg_rc=0
bash "$AGENTS_ROOT/bin/get-config-var" --is-off CODEGRAPH off >/dev/null 2>&1 || _cg_rc=$?

if [ "$_cg_rc" -ne 1 ]; then
    printf "${C_GRAY}CODEGRAPH is off (default).${C_RESET}\n"
    node "$AGENTS_ROOT/install/codegraph-mcp.js" unregister </dev/null
    exit 0
fi

# Pinned to 1.6.0: 1.6.1 regressed with Windows console flicker (#2456).
# An installed binary is kept when the update fails.
_cg_updated=0
if command -v npm >/dev/null 2>&1; then
    echo "Installing CodeGraph 1.6.0..."
    if npm install -g --ignore-scripts "@colbymchenry/codegraph@1.6.0" </dev/null; then
        _cg_updated=1
        printf "${C_GREEN}CodeGraph is up to date.${C_RESET}\n"
    elif ! command -v codegraph >/dev/null 2>&1; then
        printf "${C_YELLOW}CodeGraph installation failed. Re-run to retry.${C_RESET}\n" >&2
        exit 0
    fi
elif ! command -v codegraph >/dev/null 2>&1; then
    printf "${C_YELLOW}npm not found. Run: nvm install --lts${C_RESET}\n" >&2
    exit 0
fi

if [ "$_cg_updated" -ne 1 ]; then
    printf "${C_YELLOW}CodeGraph could not be updated (npm missing or failed); keeping the installed version.${C_RESET}\n" >&2
fi

node "$AGENTS_ROOT/install/codegraph-mcp.js" register </dev/null
exit 0
