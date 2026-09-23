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

AGENTS_ROOT="${AGENTS_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"

# GITLAB is opt-in (default off): exit 1 means explicit ON; every other exit resolves to OFF.
_gitlab_rc=0
bash "$AGENTS_ROOT/bin/get-config-var" --is-off GITLAB off >/dev/null 2>&1 || _gitlab_rc=$?
if [ "$_gitlab_rc" -ne 1 ]; then
    printf "${C_GRAY}GITLAB is off (default); skipping glab installation.${C_RESET}\n"
    exit 0
fi

if command -v glab &>/dev/null; then
    echo "Updating glab (GitLab CLI)..."
    case "$(uname -s)" in
        Darwin)
            brew upgrade glab || printf "${C_GRAY}glab is up to date.${C_RESET}\n"
            ;;
        *)
            sudo apt-get install -y --only-upgrade glab 2>/dev/null || true
            ;;
    esac
    printf "${C_GREEN}glab: $(glab --version | head -1)${C_RESET}\n"
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

if ! command -v glab &>/dev/null; then
    printf "${C_YELLOW}glab: not installed, skipping authentication setup.${C_RESET}\n"
    exit 0
fi

# Read auth config from .env; non-interactive when both GITLAB_HOSTNAME and GITLAB_TOKEN are set.
_hostname="$(bash "$AGENTS_ROOT/bin/get-config-var" GITLAB_HOSTNAME 2>/dev/null || true)"
_token="$(bash "$AGENTS_ROOT/bin/get-config-var" GITLAB_TOKEN 2>/dev/null || true)"
_subfolder="$(bash "$AGENTS_ROOT/bin/get-config-var" GITLAB_SUBFOLDER 2>/dev/null || true)"
_ssh_host="$(bash "$AGENTS_ROOT/bin/get-config-var" GITLAB_SSH_HOSTNAME 2>/dev/null || true)"

if [ -n "$_hostname" ] && [ -n "$_token" ]; then
    printf "Configuring glab authentication for %s...\n" "$_hostname"
    _auth_args=(auth login --hostname "$_hostname" --token "$_token" --api-protocol https --git-protocol ssh)
    [ -n "$_ssh_host" ] && _auth_args+=(--ssh-hostname "$_ssh_host")
    glab "${_auth_args[@]}"
    if [ $? -ne 0 ]; then
        printf "${C_YELLOW}glab auth login failed.${C_RESET}\n" >&2
    else
        printf "${C_GREEN}glab: authenticated.${C_RESET}\n"
        if [ -n "$_subfolder" ]; then
            glab config set --host "$_hostname" subfolder "$_subfolder"
            printf "${C_GREEN}glab: subfolder set to '%s'.${C_RESET}\n" "$_subfolder"
        fi
    fi
else
    if glab auth status &>/dev/null 2>&1; then
        printf "${C_GRAY}glab: already authenticated.${C_RESET}\n"
    else
        printf "${C_YELLOW}glab: set GITLAB_HOSTNAME and GITLAB_TOKEN in .env for automated auth,${C_RESET}\n"
        printf "${C_YELLOW}      or run 'glab auth login --hostname <host>' manually.${C_RESET}\n"
    fi
fi
