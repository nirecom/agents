#!/bin/bash
# gh.sh - Install GitHub CLI and configure authentication
# Sibling: dotfiles/install/linux/gh.sh (same pattern; kept separate for self-sufficiency)
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

if command -v gh &>/dev/null; then
    printf "${C_GRAY}gh is already installed: $(gh --version | head -1)${C_RESET}\n"
else
    echo "Installing gh (GitHub CLI)..."
    case "$(uname -s)" in
        Darwin)
            brew install gh
            ;;
        *)
            sudo mkdir -p -m 755 /etc/apt/keyrings
            curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
            sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
            sudo apt-get update -q
            sudo apt-get install -y gh
            ;;
    esac
    printf "${C_GREEN}gh installed: $(gh --version | head -1)${C_RESET}\n"
fi

# Auth: check if already authenticated (idempotency — skip login on re-runs)
if gh auth status &>/dev/null 2>&1; then
    printf "${C_GRAY}gh: already authenticated — skipping gh auth login.${C_RESET}\n"
elif [ -t 0 ]; then
    # Non-interactive guard: only attempt login when stdin is a TTY to prevent CI hangs.
    # [ -t 0 ] is the primary guard (|| true only handles exit-code failures, not hangs).
    gh auth login || printf "${C_YELLOW}gh auth login did not complete; continuing installation.${C_RESET}\n"
else
    printf "${C_YELLOW}gh: non-interactive session — skipping gh auth login. Run 'gh auth login' manually later.${C_RESET}\n"
fi

# Add project scope (always run — non-fatal)
gh auth refresh -s project || printf "${C_YELLOW}gh auth refresh -s project did not complete; continuing installation.${C_RESET}\n"
