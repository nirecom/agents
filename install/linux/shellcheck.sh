#!/bin/bash
# Install the ShellCheck shell-script linter.
# Required by skills/write-code/SKILL.md's bash-file lint step.
export SYSTEM_OPS_APPROVED=1

# Color fallback (no dotfiles dependency — standalone-safe pattern from claude-code.sh)
if [ -z "${C_RESET+x}" ]; then
    if [ -t 1 ]; then
        C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_GRAY='\033[0;90m'; C_RESET='\033[0m'
    else
        C_GREEN=''; C_YELLOW=''; C_GRAY=''; C_RESET=''
    fi
fi

if command -v shellcheck &>/dev/null; then
    printf "${C_GRAY}shellcheck is already installed: $(shellcheck --version | grep version:)${C_RESET}\n"
    exit 0
fi

echo "Installing shellcheck..."
case "$(uname -s)" in
    Darwin)
        if ! brew install shellcheck; then
            if command -v shellcheck &>/dev/null; then
                printf "${C_GRAY}shellcheck already present (installer returned non-zero).${C_RESET}\n"
            else
                printf "${C_YELLOW}shellcheck installation failed.${C_RESET}\n" >&2
                exit 1
            fi
        fi
        ;;
    *)
        if ! sudo apt-get install -y shellcheck; then
            if command -v shellcheck &>/dev/null; then
                printf "${C_GRAY}shellcheck already present (installer returned non-zero).${C_RESET}\n"
            else
                printf "${C_YELLOW}shellcheck installation failed.${C_RESET}\n" >&2
                exit 1
            fi
        fi
        ;;
esac

printf "${C_GREEN}shellcheck installed.${C_RESET}\n"
