#!/bin/bash
# claude-code.sh - Install Claude Code CLI via native installer
export SYSTEM_OPS_APPROVED=1

if [ -z "${C_RESET+x}" ]; then
    if [ -t 1 ]; then
        C_GREEN='\033[0;32m'; C_GRAY='\033[0;90m'; C_RESET='\033[0m'
    else
        C_GREEN=''; C_GRAY=''; C_RESET=''
    fi
fi

if type claude >/dev/null 2>&1; then
    printf "${C_GRAY}Claude Code is already installed: $(claude --version)${C_RESET}\n"
    exit 0
fi

echo "Installing Claude Code..."
curl -fsSL https://claude.ai/install.sh | bash
printf "${C_GREEN}Claude Code installed.${C_RESET}\n"
