#!/usr/bin/env bash
# vscode-settings.sh - Merge Copilot/Claude Code settings into VS Code user settings.json
# Usage: called from install.sh, or directly as ./install/linux/vscode-settings.sh

set -euo pipefail

AGENTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Allow override for testing
if [ -n "${VSCODE_USER_SETTINGS_DIR:-}" ]; then
    SETTINGS_DIR="$VSCODE_USER_SETTINGS_DIR"
elif [ "$(uname)" = "Darwin" ]; then
    SETTINGS_DIR="$HOME/Library/Application Support/Code/User"
else
    SETTINGS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/Code/User"
fi
SETTINGS_FILE="$SETTINGS_DIR/settings.json"

# Canonicalize to resolve any .. sequences before use (CWE-22)
if command -v realpath >/dev/null 2>&1; then
    SETTINGS_DIR="$(realpath -m "$SETTINGS_DIR")"
fi

if [ ! -d "$SETTINGS_DIR" ]; then
    echo "Warning: VS Code user settings directory not found: $SETTINGS_DIR (skipping)" >&2
    exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "Warning: jq not found — cannot update VS Code settings (skipping)" >&2
    exit 0
fi

# Read existing settings (treat missing or empty file as {})
if [ -f "$SETTINGS_FILE" ] && [ -s "$SETTINGS_FILE" ]; then
    EXISTING=$(cat "$SETTINGS_FILE")
    if ! echo "$EXISTING" | jq . >/dev/null 2>&1; then
        echo "Warning: settings.json contains invalid JSON — skipping to avoid corruption: $SETTINGS_FILE" >&2
        exit 0
    fi
    cp "$SETTINGS_FILE" "$SETTINGS_FILE.bak"
else
    EXISTING="{}"
fi

# Build patch JSON
PATCH=$(jq -n \
    --arg agents_prompts "$AGENTS_ROOT/copilot/prompts" \
    --arg claude_dir "$HOME/.claude" \
    '{
        "chat.useClaudeMdFile": true,
        "chat.useAgentsMdFile": true,
        "chat.useNestedAgentsMdFiles": false,
        "github.copilot.chat.codeGeneration.useInstructionFiles": true,
        "chat.includeApplyingInstructions": true,
        "chat.promptFiles": true,
        "chat.promptFilesLocations": { ($agents_prompts): true },
        "chat.hookFilesLocations": { ($claude_dir): true }
    }')

# Merge patch into existing (patch wins for duplicate keys)
MERGED=$(echo "$EXISTING" | jq --argjson patch "$PATCH" '. * $patch')

printf '%s\n' "$MERGED" > "$SETTINGS_FILE"
echo "VS Code settings updated: $SETTINGS_FILE"
