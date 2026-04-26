#!/bin/bash
# claude-code.sh - Install Claude Code CLI via native installer

if type claude >/dev/null 2>&1; then
    echo "Claude Code is already installed: $(claude --version)"
    exit 0
fi

echo "Installing Claude Code..."
curl -fsSL https://claude.ai/install.sh | bash
echo "Claude Code installed."
