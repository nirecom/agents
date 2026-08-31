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

# install/codegraph-constants.txt is the single source of truth for the pinned
# version and the telemetry opt-out; install/win/codegraph.ps1 reads the same file.
CODEGRAPH_VERSION=""
while IFS='=' read -r _cg_key _cg_value; do
    case "$_cg_key" in
        CODEGRAPH_VERSION) CODEGRAPH_VERSION="$_cg_value" ;;
        CODEGRAPH_TELEMETRY|DO_NOT_TRACK) export "$_cg_key=$_cg_value" ;;
    esac
done < "$AGENTS_ROOT/install/codegraph-constants.txt"

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

if ! command -v npm >/dev/null 2>&1; then
    printf "${C_YELLOW}npm not found. Run: nvm install --lts${C_RESET}\n" >&2
    exit 0
fi

if [ -z "$CODEGRAPH_VERSION" ]; then
    printf "${C_YELLOW}CODEGRAPH_VERSION missing from install/codegraph-constants.txt. CodeGraph step skipped.${C_RESET}\n" >&2
    exit 0
fi

if command -v codegraph >/dev/null 2>&1; then
    printf "${C_GRAY}CodeGraph is already installed.${C_RESET}\n"
else
    echo "Installing CodeGraph..."
    if ! npm install -g --ignore-scripts "@colbymchenry/codegraph@$CODEGRAPH_VERSION" </dev/null; then
        printf "${C_YELLOW}CodeGraph installation failed. Re-run to retry.${C_RESET}\n" >&2
        exit 0
    fi
    printf "${C_GREEN}CodeGraph installed.${C_RESET}\n"
fi

node "$AGENTS_ROOT/install/codegraph-mcp.js" register </dev/null
exit 0
