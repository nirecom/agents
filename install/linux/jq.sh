#!/bin/bash
# jq.sh - Install jq (JSON processor)
# jq is required by bin/compose-doc-append-entry, github-contents-write.sh, github-git-data-write.sh
export SYSTEM_OPS_APPROVED=1

# Color fallback (no dotfiles dependency — standalone-safe pattern from claude-code.sh)
if [ -z "${C_RESET+x}" ]; then
    if [ -t 1 ]; then
        C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_GRAY='\033[0;90m'; C_RESET='\033[0m'
    else
        C_GREEN=''; C_YELLOW=''; C_GRAY=''; C_RESET=''
    fi
fi

if command -v jq &>/dev/null; then
    printf "${C_GRAY}jq is already installed: $(jq --version)${C_RESET}\n"
    exit 0
fi

echo "Installing jq..."
case "$(uname -s)" in
    Darwin)
        if ! brew install jq; then
            if command -v jq &>/dev/null; then
                printf "${C_GRAY}jq already present (installer returned non-zero).${C_RESET}\n"
            else
                printf "${C_YELLOW}jq installation failed.${C_RESET}\n" >&2
                exit 1
            fi
        fi
        ;;
    *)
        if ! sudo apt-get install -y jq; then
            if command -v jq &>/dev/null; then
                printf "${C_GRAY}jq already present (installer returned non-zero).${C_RESET}\n"
            else
                printf "${C_YELLOW}jq installation failed.${C_RESET}\n" >&2
                exit 1
            fi
        fi
        ;;
esac

printf "${C_GREEN}jq installed: $(jq --version)${C_RESET}\n"
