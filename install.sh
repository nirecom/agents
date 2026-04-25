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
echo "--- Adding profile sourcing ---"
_rc_file="${HOME}/.bashrc"
_snippet_path="$AGENTS_ROOT/profile-snippet.sh"
_marker="# --- BEGIN agents profile sourcing ---"
if ! grep -qF "$_marker" "$_rc_file" 2>/dev/null; then
    printf '\n%s\n. "%s"\n# --- END agents profile sourcing ---\n' \
        "$_marker" "$_snippet_path" >> "$_rc_file"
    echo "Added profile sourcing to $_rc_file"
else
    sed -i "s|^\. \".*profile-snippet\.sh\"|. \"$_snippet_path\"|" "$_rc_file"
    echo "Profile sourcing already present in $_rc_file (path updated if needed)"
fi
unset _rc_file _snippet_path _marker

echo ""
echo "--- Configuring VS Code settings (GitHub Copilot / Claude Code) ---"
"$AGENTS_ROOT/install/linux/vscode-settings.sh"

echo ""
echo "=== Done ==="
echo "Restart your shell or run: source ~/.bashrc"
