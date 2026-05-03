#!/bin/bash
# gemini.sh - Install Gemini CLI via npm

if [ -z "${C_RESET+x}" ]; then
    if [ -t 1 ]; then
        C_GREEN='\033[0;32m'; C_GRAY='\033[0;90m'; C_RESET='\033[0m'
    else
        C_GREEN=''; C_GRAY=''; C_RESET=''
    fi
fi

NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
. "$NVM_DIR/nvm.sh"

if type gemini >/dev/null 2>&1; then
    printf "${C_GRAY}Gemini CLI is already installed.${C_RESET}\n"
    exit 0
fi

echo "Installing Gemini CLI..."
npm install -g @google/gemini-cli
printf "${C_GREEN}Gemini CLI installed. Run: gemini auth${C_RESET}\n"

if type mmdc >/dev/null 2>&1; then
    printf "${C_GRAY}Mermaid CLI (mmdc) is already installed.${C_RESET}\n"
else
    echo "Installing Mermaid CLI (mmdc)..."
    npm install -g @mermaid-js/mermaid-cli
    printf "${C_GREEN}Mermaid CLI installed.${C_RESET}\n"
fi
