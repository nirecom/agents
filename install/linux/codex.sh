#!/bin/bash
# codex.sh - Install Codex CLI via npm
export SYSTEM_OPS_APPROVED=1

if [ -z "${C_RESET+x}" ]; then
    if [ -t 1 ]; then
        C_GREEN='\033[0;32m'; C_GRAY='\033[0;90m'; C_RESET='\033[0m'
    else
        C_GREEN=''; C_GRAY=''; C_RESET=''
    fi
fi

NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
. "$NVM_DIR/nvm.sh"

if type codex >/dev/null 2>&1; then
    printf "${C_GRAY}Codex is already installed.${C_RESET}\n"
    if ! bash "$(dirname "${BASH_SOURCE[0]}")/../lib/wait-cc-exit.sh"; then
        printf "Claude Code still running — skipping update.\n" >&2
        exit 0
    fi
    codex update || true
    exit 0
fi

echo "Installing Codex..."
npm install -g @openai/codex
printf "${C_GREEN}Codex installed.${C_RESET}\n"
