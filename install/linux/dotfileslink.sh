#!/bin/bash
# dotfileslink.sh - Create ~/.claude/ symlinks, set git hooksPath, write profile snippet
# Usage: Called by install.sh, or run manually

set -euo pipefail

AGENTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# --- ~/.claude/ symlinks ---
mkdir -p ~/.claude

if [ -d ~/.claude/.git ]; then
    echo "WARNING: ~/.claude is a git repo. Remove .git to enable symlinks." >&2
else
    for dir in skills rules agents; do
        if [ -d ~/.claude/$dir ] && [ ! -L ~/.claude/$dir ]; then
            echo "Backing up ~/.claude/$dir -> ~/.claude/$dir.bak"
            rm -rf ~/.claude/$dir.bak
            mv ~/.claude/$dir ~/.claude/$dir.bak
        fi
    done
    if [ -L ~/.claude/commands ]; then
        echo "Removing obsolete symlink: ~/.claude/commands"
        rm -f ~/.claude/commands
    fi
    ln -sf "$AGENTS_ROOT/CLAUDE.md" ~/.claude/
    ln -sf "$AGENTS_ROOT/settings.json" ~/.claude/
    ln -snf "$AGENTS_ROOT/skills" ~/.claude/skills
    ln -snf "$AGENTS_ROOT/rules" ~/.claude/rules
    ln -snf "$AGENTS_ROOT/agents" ~/.claude/agents
    echo "Symlinks created in ~/.claude/"
fi

# --- git core.hooksPath ---
GIT_CONFIG_LOCAL="$HOME/.config/git/config.local"
mkdir -p "$(dirname "$GIT_CONFIG_LOCAL")"
git config --file "$GIT_CONFIG_LOCAL" core.hooksPath "$AGENTS_ROOT/hooks"
echo "core.hooksPath -> $AGENTS_ROOT/hooks"

# --- AGENTS_CONFIG_DIR / AGENTS_DIR profile snippet ---
PROFILE_SNIPPET="$HOME/.agents_profile"
cat > "$PROFILE_SNIPPET" << EOF
export AGENTS_CONFIG_DIR="$AGENTS_ROOT"
export AGENTS_DIR="$AGENTS_ROOT"
EOF
echo "Profile snippet written: $PROFILE_SNIPPET"

# --- ~/.local/bin/doc-append launcher ---
mkdir -p ~/.local/bin
cat > ~/.local/bin/doc-append << 'LAUNCHER_EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
AGENTS_ROOT_RESOLVED="${AGENTS_CONFIG_DIR:-}"
if [ -z "$AGENTS_ROOT_RESOLVED" ] && [ -f "$SCRIPT_DIR/../agents/bin/doc-append.py" ]; then
    AGENTS_ROOT_RESOLVED="$SCRIPT_DIR/.."
fi
if [[ -z "${1:-}" || "${1:-}" == --* ]]; then
    exec uv run "${AGENTS_ROOT_RESOLVED}/bin/doc-append.py" "docs/history.md" "$@"
else
    exec uv run "${AGENTS_ROOT_RESOLVED}/bin/doc-append.py" "$@"
fi
LAUNCHER_EOF
# Rewrite with the actual path now that we know AGENTS_ROOT
cat > ~/.local/bin/doc-append << EOF
#!/usr/bin/env bash
if [[ -z "\${1:-}" || "\${1:-}" == --* ]]; then
  exec uv run "$AGENTS_ROOT/bin/doc-append.py" "docs/history.md" "\$@"
else
  exec uv run "$AGENTS_ROOT/bin/doc-append.py" "\$@"
fi
EOF
chmod +x ~/.local/bin/doc-append
echo "Generated: ~/.local/bin/doc-append"
