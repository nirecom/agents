#!/bin/bash
# codex.sh - Install Codex CLI via npm

NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
. "$NVM_DIR/nvm.sh"

if type codex >/dev/null 2>&1; then
    echo "Codex is already installed."
    exit 0
fi

echo "Installing Codex..."
npm install -g @openai/codex
echo "Codex installed."
