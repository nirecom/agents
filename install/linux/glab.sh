#!/bin/bash
# glab.sh - Install GitLab CLI and configure authentication
# Sibling: dotfiles/install/linux/glab.sh (same pattern; kept separate for self-sufficiency)
# Usage: Called by install.sh or run independently
export SYSTEM_OPS_APPROVED=1

# Color fallback (no dotfiles dependency — standalone-safe pattern from claude-code.sh)
if [ -z "${C_RESET+x}" ]; then
    if [ -t 1 ]; then
        C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_GRAY='\033[0;90m'; C_RESET='\033[0m'
    else
        C_GREEN=''; C_YELLOW=''; C_GRAY=''; C_RESET=''
    fi
fi

if command -v glab &>/dev/null; then
    printf "${C_GRAY}glab is already installed: $(glab --version | head -1)${C_RESET}\n"
else
    echo "Installing glab (GitLab CLI)..."
    case "$(uname -s)" in
        Darwin)
            brew install glab
            ;;
        *)
            sudo apt-get update -q
            sudo apt-get install -y glab 2>/dev/null || true
            ;;
    esac
    if command -v glab &>/dev/null; then
        printf "${C_GREEN}glab installed: $(glab --version | head -1)${C_RESET}\n"
    else
        printf "${C_YELLOW}glab could not be installed automatically. Install manually: https://gitlab.com/gitlab-org/cli#installation${C_RESET}\n"
    fi
fi

# Auth: skip if glab not installed; check idempotency then prompt only in interactive sessions.
if ! command -v glab &>/dev/null; then
    printf "${C_YELLOW}glab: not installed, skipping authentication setup.${C_RESET}\n"
elif glab auth status &>/dev/null 2>&1; then
    printf "${C_GRAY}glab: already authenticated — skipping glab auth login.${C_RESET}\n"
elif [ -t 0 ]; then
    # Non-interactive guard: only attempt login when stdin is a TTY to prevent CI hangs.
    # [ -t 0 ] is the primary guard (|| true only handles exit-code failures, not hangs).
    glab auth login || printf "${C_YELLOW}glab auth login did not complete; continuing installation.${C_RESET}\n"
else
    printf "${C_YELLOW}glab: non-interactive session — skipping glab auth login. Run 'glab auth login' manually later.${C_RESET}\n"
fi
