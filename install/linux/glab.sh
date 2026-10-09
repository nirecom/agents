#!/bin/bash
# glab.sh - Install GitLab CLI and configure authentication
# Self-contained installer (no dotfiles sibling; see docs/architecture/gitlab-support.md).
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

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# GITLAB is opt-in (default off): exit 1 means explicit ON; every other exit resolves to OFF.
_gitlab_rc=0
bash "$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" --is-off GITLAB off >/dev/null 2>&1 || _gitlab_rc=$?
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
_hostname="$(bash "$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" GITLAB_HOSTNAME 2>/dev/null || true)"
_token="$(bash "$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" GITLAB_TOKEN 2>/dev/null || true)"
_subfolder="$(bash "$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" GITLAB_SUBFOLDER 2>/dev/null || true)"
_ssh_host="$(bash "$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" GITLAB_SSH_HOSTNAME 2>/dev/null || true)"

# _glab_probe <host> <port>: TCP connect via bash /dev/tcp, name resolution included, 3s hard
# limit. $BASH (the running shell), not PATH's bash, so a PATH-mocked bash cannot stand in.
_glab_probe() {
    local _sh="${BASH:-bash}" _probe_pid _kill_pid _rc=0
    # shellcheck disable=SC2016  # $1/$2 expand inside the probe shell, not here
    local _connect='exec 3<>"/dev/tcp/$1/$2"'
    if command -v timeout >/dev/null 2>&1; then
        timeout 3 "$_sh" -c "$_connect" _ "$1" "$2" >/dev/null 2>&1
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout 3 "$_sh" -c "$_connect" _ "$1" "$2" >/dev/null 2>&1
    else
        # No timeout utility: background + kill-after for 3s hard limit
        "$_sh" -c "$_connect" _ "$1" "$2" >/dev/null 2>&1 &
        _probe_pid=$!
        ( sleep 3; kill "$_probe_pid" 2>/dev/null ) &
        _kill_pid=$!
        wait "$_probe_pid" 2>/dev/null || _rc=$?
        kill "$_kill_pid" 2>/dev/null
        wait "$_kill_pid" 2>/dev/null
        return "$_rc"
    fi
}

if [ -n "$_hostname" ] && [ -n "$_token" ]; then
    # GLAB_PROBE_PORT is a test seam; production always probes 443.
    _port=443
    if [[ "${GLAB_PROBE_PORT:-}" =~ ^[0-9]{1,5}$ ]] && (( 10#$GLAB_PROBE_PORT >= 1 && 10#$GLAB_PROBE_PORT <= 65535 )); then
        _port=$((10#$GLAB_PROBE_PORT))
    fi
    _probe_rc=0
    _glab_probe "$_hostname" "$_port" || _probe_rc=$?
    if [ "$_probe_rc" -ne 0 ]; then
        printf "${C_YELLOW}WARNING: Cannot connect to %s:%s (TCP connect failed or timed out within 3s). Skipping glab authentication.${C_RESET}\n" "$_hostname" "$_port" >&2
    else
        printf "Configuring glab authentication for %s...\n" "$_hostname"
        # Token on stdin, not argv: a command line is visible in every process listing.
        _auth_args=(auth login --hostname "$_hostname" --stdin --api-protocol https --git-protocol ssh)
        [ -n "$_ssh_host" ] && _auth_args+=(--ssh-hostname "$_ssh_host")
        if ! printf '%s' "$_token" | glab "${_auth_args[@]}"; then
            printf "${C_YELLOW}glab auth login failed.${C_RESET}\n" >&2
        else
            printf "${C_GREEN}glab: authenticated.${C_RESET}\n"
            if [ -n "$_subfolder" ]; then
                glab config set --host "$_hostname" subfolder "$_subfolder"
                printf "${C_GREEN}glab: subfolder set to '%s'.${C_RESET}\n" "$_subfolder"
            fi
        fi
    fi
else
    printf "${C_YELLOW}glab: set GITLAB_HOSTNAME and GITLAB_TOKEN in .env for automated auth,${C_RESET}\n"
    printf "${C_YELLOW}      or run 'glab auth login --hostname <host>' manually.${C_RESET}\n"
fi
