#!/bin/bash
# pwsh.sh - Install PowerShell (pwsh) and Pester 5
export SYSTEM_OPS_APPROVED=1

# Color fallback (no dotfiles dependency — standalone-safe pattern from claude-code.sh)
if [ -z "${C_RESET+x}" ]; then
    if [ -t 1 ]; then
        C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_GRAY='\033[0;90m'; C_RESET='\033[0m'
    else
        C_GREEN=''; C_YELLOW=''; C_GRAY=''; C_RESET=''
    fi
fi

_install_pester() {
    if pwsh -NoProfile -Command 'if (Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge "5.0" }) { exit 0 } else { exit 1 }' 2>/dev/null; then
        printf "${C_GRAY}Pester 5 is already installed.${C_RESET}\n"
        return 0
    fi
    echo "Installing Pester 5..."
    if pwsh -NoProfile -Command 'Install-Module Pester -Force -Scope CurrentUser -SkipPublisherCheck'; then
        printf "${C_GREEN}Pester 5 installed.${C_RESET}\n"
    else
        printf "${C_YELLOW}Pester installation failed. Run manually: pwsh -Command 'Install-Module Pester -Scope CurrentUser'${C_RESET}\n" >&2
    fi
}

if command -v pwsh &>/dev/null; then
    printf "${C_GRAY}pwsh is already installed: $(pwsh --version)${C_RESET}\n"
    _install_pester
    exit 0
fi

echo "Installing pwsh..."
case "$(uname -s)" in
    Darwin)
        if ! brew install --cask powershell; then
            if command -v pwsh &>/dev/null; then
                printf "${C_GRAY}pwsh already present (installer returned non-zero).${C_RESET}\n"
            else
                printf "${C_YELLOW}pwsh installation failed.${C_RESET}\n" >&2
                exit 1
            fi
        fi
        ;;
    *)
        if ! sudo apt-get install -y powershell; then
            if command -v pwsh &>/dev/null; then
                printf "${C_GRAY}pwsh already present (installer returned non-zero).${C_RESET}\n"
            else
                printf "${C_YELLOW}pwsh installation failed. Add the Microsoft repository first: https://learn.microsoft.com/en-us/powershell/scripting/install/install-ubuntu${C_RESET}\n" >&2
                exit 1
            fi
        fi
        ;;
esac

printf "${C_GREEN}pwsh installed: $(pwsh --version)${C_RESET}\n"
_install_pester
