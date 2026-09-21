#!/bin/bash
# rtk.sh - Install RTK (Rust Token Killer) when RTK is on; validate with rtk config,
# migrate only invalid config via rtk config --create.
export SYSTEM_OPS_APPROVED=1

AGENTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ -z "${C_RESET+x}" ]; then
    if [ -t 1 ]; then
        C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_GRAY='\033[0;90m'; C_RESET='\033[0m'
    else
        C_GREEN=''; C_YELLOW=''; C_GRAY=''; C_RESET=''
    fi
fi

# RTK is opt-in (default off): exit 1 means explicit ON; every other exit
# (off / unset / unrecognized / internal failure) resolves to OFF.
_rtk_rc=0
bash "$AGENTS_ROOT/bin/get-config-var" --is-off RTK off >/dev/null 2>&1 || _rtk_rc=$?
if [ "$_rtk_rc" -ne 1 ]; then
    printf "${C_GRAY}RTK is off (default).${C_RESET}\n"
    exit 0
fi

# Linux: RTK ships through Homebrew — install brew if missing, then load it.
if [ "$(uname -s)" = "Linux" ] && ! command -v brew >/dev/null 2>&1; then
    echo "Installing Homebrew..."
    if ! /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
        printf "${C_YELLOW}Homebrew installation failed. RTK step skipped.${C_RESET}\n" >&2
        exit 0
    fi
    if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
        eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
    fi
fi

if ! command -v brew >/dev/null 2>&1; then
    printf "${C_YELLOW}brew not found. RTK step skipped.${C_RESET}\n" >&2
    exit 0
fi

if command -v rtk >/dev/null 2>&1; then
    printf "${C_GRAY}RTK is already installed.${C_RESET}\n"
else
    echo "Installing RTK..."
    if ! brew install rtk-ai/tap/rtk </dev/null; then
        printf "${C_YELLOW}RTK installation failed. Re-run to retry.${C_RESET}\n" >&2
        exit 0
    fi
    printf "${C_GREEN}RTK installed.${C_RESET}\n"
fi

# Validate config via the RTK binary; migrate only an existing-but-invalid config.
# rtk config exits 0 when the config is absent/empty (built-in defaults) or valid,
# and non-zero only when a config exists but is unparseable — the sole case that
# warrants 'rtk config --create' to migrate to RTK's current default.
if command -v rtk >/dev/null 2>&1; then
    if ! rtk config >/dev/null 2>&1; then
        echo "Existing RTK config is invalid; migrating via 'rtk config --create'..."
        rtk config --create >/dev/null 2>&1 || printf "${C_YELLOW}rtk config --create failed (non-fatal).${C_RESET}\n" >&2
    fi
fi
exit 0
