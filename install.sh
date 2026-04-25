#!/bin/bash
# Agents framework installer for Linux/macOS
# Usage: ./install.sh

set -euo pipefail

AGENTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== agents installer ==="

echo ""
echo "--- Creating symlinks ---"
"$AGENTS_ROOT/install/linux/dotfileslink.sh"

if type claude >/dev/null 2>&1; then
    echo ""
    echo "--- Initializing Claude Code session sync ---"
    "$AGENTS_ROOT/install/linux/session-sync-init.sh"
else
    echo "Claude Code not found. Install it and re-run to enable session sync."
fi

echo ""
echo "=== Done ==="
echo ""
echo "Add the following to your shell profile (~/.bash_profile or ~/.zshrc):"
echo "  source ~/.agents_profile"
