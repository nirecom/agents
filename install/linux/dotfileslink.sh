#!/bin/bash
# dotfileslink.sh - Create ~/.claude/ symlinks, set git hooksPath, write profile snippet
# Usage: Called by install.sh, or run manually

set -euo pipefail

AGENTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ -z "${C_RESET+x}" ]; then
    if [ -t 1 ]; then
        C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_GRAY='\033[0;90m'; C_RESET='\033[0m'
    else
        C_GREEN=''; C_YELLOW=''; C_GRAY=''; C_RESET=''
    fi
fi

# --- ~/.claude/ symlinks ---
mkdir -p ~/.claude

if [ -d ~/.claude/.git ]; then
    echo "WARNING: ~/.claude is a git repo. Remove .git to enable symlinks." >&2
else
    for dir in skills rules agents; do
        if [ -d ~/.claude/$dir ] && [ ! -L ~/.claude/$dir ]; then
            printf "${C_YELLOW}Backing up ~/.claude/$dir -> ~/.claude/$dir.bak${C_RESET}\n"
            rm -rf ~/.claude/$dir.bak
            mv ~/.claude/$dir ~/.claude/$dir.bak
        fi
    done
    if [ -L ~/.claude/commands ]; then
        printf "${C_YELLOW}Removing obsolete symlink: ~/.claude/commands${C_RESET}\n"
        rm -f ~/.claude/commands
    fi
    ln -sf "$AGENTS_ROOT/CLAUDE.md" ~/.claude/
    ln -snf "$AGENTS_ROOT/skills" ~/.claude/skills
    ln -snf "$AGENTS_ROOT/rules" ~/.claude/rules
    ln -snf "$AGENTS_ROOT/agents" ~/.claude/agents
    # Remove stale settings.json symlink that used to point directly into agents/
    if [ -L ~/.claude/settings.json ]; then
        printf "${C_YELLOW}Removing stale symlink: ~/.claude/settings.json${C_RESET}\n"
        rm -f ~/.claude/settings.json
    fi
    printf "${C_GREEN}Symlinks created in ~/.claude/${C_RESET}\n"
fi

# --- Assemble ~/.claude/settings.json from base + extension ---
node "$AGENTS_ROOT/install/assemble-settings.js"

# --- git core.hooksPath ---
git config --file "$HOME/.gitconfig" core.hooksPath "$AGENTS_ROOT/hooks"
printf "${C_GREEN}core.hooksPath -> $AGENTS_ROOT/hooks${C_RESET}\n"

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
printf "${C_GREEN}Generated: ~/.local/bin/doc-append${C_RESET}\n"

# --- ~/.local/bin/doc-append-plain launcher ---
cat > ~/.local/bin/doc-append-plain << EOF
#!/usr/bin/env bash
exec uv run "$AGENTS_ROOT/bin/doc-append-plain.py" "\$@"
EOF
chmod +x ~/.local/bin/doc-append-plain
printf "${C_GREEN}Generated: ~/.local/bin/doc-append-plain${C_RESET}\n"

# --- ~/.local/bin/repo-visibility launcher ---
cat > ~/.local/bin/repo-visibility << EOF
#!/usr/bin/env bash
exec uv run "$AGENTS_ROOT/bin/repo-visibility.py" "\$@"
EOF
chmod +x ~/.local/bin/repo-visibility
printf "${C_GREEN}Generated: ~/.local/bin/repo-visibility${C_RESET}\n"

# --- BEGIN temporary: cc-session-title launcher cleanup ---
# Remove stale launchers from the cc-session-title removal (PRs #303, #313, #331).
# Idempotent: rm -f silently no-ops when the file is absent.
# Safe to delete this block after all developer machines have run dotfileslink once.
for stale in ~/.local/bin/cc-session-title ~/.local/bin/cc-session-title.cmd; do
    if [ -e "$stale" ] || [ -L "$stale" ]; then
        rm -f "$stale"
        printf "${C_YELLOW}Removed stale launcher: $stale${C_RESET}\n"
    fi
done
# --- END temporary: cc-session-title launcher cleanup ---

# --- ~/.local/bin/review-code-codex symlink ---
ln -sf "$AGENTS_ROOT/bin/review-code-codex" ~/.local/bin/review-code-codex
printf "${C_GREEN}Symlinked: ~/.local/bin/review-code-codex${C_RESET}\n"

# --- ~/.local/bin/review-plan-codex symlink ---
ln -sf "$AGENTS_ROOT/bin/review-plan-codex" ~/.local/bin/review-plan-codex
printf "${C_GREEN}Symlinked: ~/.local/bin/review-plan-codex${C_RESET}\n"

# --- ~/.local/bin/get-config-var symlink ---
ln -sf "$AGENTS_ROOT/bin/get-config-var" ~/.local/bin/get-config-var
printf "${C_GREEN}Symlinked: ~/.local/bin/get-config-var${C_RESET}\n"

# --- ~/.local/bin/draw-diagram symlink ---
ln -sf "$AGENTS_ROOT/bin/draw-diagram" ~/.local/bin/draw-diagram
printf "${C_GREEN}Symlinked: ~/.local/bin/draw-diagram${C_RESET}\n"

# --- ~/.local/bin/draw-diagram-gemini symlink ---
ln -sf "$AGENTS_ROOT/bin/draw-diagram-gemini" ~/.local/bin/draw-diagram-gemini
printf "${C_GREEN}Symlinked: ~/.local/bin/draw-diagram-gemini${C_RESET}\n"
