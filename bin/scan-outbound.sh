#!/bin/bash
# Scan content for private information patterns
# Usage:
#   scan-outbound.sh [--stdin [label]] [file ...]
#   --stdin: read from stdin (optional label for output)
#   file args: scan named files
# Exit: 0 = clean, 1 = violations found, 2 = usage error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOTFILES_DIR="$(dirname "$SCRIPT_DIR")"
ALLOWLIST="$DOTFILES_DIR/.private-info-allowlist"
_dotfiles_private="${DOTFILES_PRIVATE_DIR:-$DOTFILES_DIR/../dotfiles-private}"
ALLOWLIST_PRIVATE="$_dotfiles_private/.private-info-allowlist"
BLOCKLIST_PRIVATE="$_dotfiles_private/.private-info-blocklist"

VIOLATIONS=0
MODE=""
LABEL="stdin"

# Parse arguments
if [ $# -eq 0 ]; then
    echo "Usage: scan-outbound.sh [--stdin [label]] [file ...]" >&2
    exit 2
fi

if [ "$1" = "--stdin" ]; then
    MODE="stdin"
    shift
    if [ $# -gt 0 ]; then
        LABEL="$1"
        shift
    fi
else
    MODE="files"
fi

# Load allowlist patterns (skip comments and empty lines)
ALLOW_PATTERNS=()
if [ -f "$ALLOWLIST" ]; then
    while IFS= read -r line; do
        line="${line%$'\r'}"
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        ALLOW_PATTERNS+=("$line")
    done < "$ALLOWLIST"
fi

# Load external allowlist patterns (from dotfiles-private, if available)
if [ -f "$ALLOWLIST_PRIVATE" ]; then
    while IFS= read -r line; do
        line="${line%$'\r'}"
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        ALLOW_PATTERNS+=("$line")
    done < "$ALLOWLIST_PRIVATE"
fi

# Load blocklist patterns
BLOCK_PATTERNS=()
if [ -f "$BLOCKLIST_PRIVATE" ]; then
    while IFS= read -r line; do
        line="${line%$'\r'}"
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        BLOCK_PATTERNS+=("$line")
    done < "$BLOCKLIST_PRIVATE"
fi

# Check if a match is allowlisted
is_allowed() {
    local file="$1"
    local matched="$2"
    for pattern in "${ALLOW_PATTERNS[@]+"${ALLOW_PATTERNS[@]}"}"; do
        if [[ "$pattern" == *:* ]]; then
            local file_pat="${pattern%%:*}"
            local val_pat="${pattern#*:}"
            if [[ "$file" == $file_pat ]] && [[ "$matched" =~ $val_pat ]]; then
                return 0
            fi
        else
            if [[ "$matched" =~ $pattern ]]; then
                return 0
            fi
        fi
    done
    return 1
}

# Scan a single line
scan_line() {
    local file="$1"
    local lineno="$2"
    local line="$3"

    # Private IPv4 ranges (RFC 1918)
    local ip_patterns=(
        '10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'
        '172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}'
        '192\.168\.[0-9]{1,3}\.[0-9]{1,3}'
    )
    for ip_pat in "${ip_patterns[@]}"; do
        local tmpline="$line"
        while [[ "$tmpline" =~ ($ip_pat) ]]; do
            local ip="${BASH_REMATCH[1]}"
            if ! is_allowed "$file" "$ip"; then
                echo "$file:$lineno: [IPv4] $ip"
                VIOLATIONS=$((VIOLATIONS + 1))
            fi
            tmpline="${tmpline/"$ip"/}"
        done
    done

    # Email addresses
    if [[ "$line" =~ [a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,} ]]; then
        local email="${BASH_REMATCH[0]}"
        if ! is_allowed "$file" "$email"; then
            echo "$file:$lineno: [email] $email"
            VIOLATIONS=$((VIOLATIONS + 1))
        fi
    fi

    # MAC addresses
    if [[ "$line" =~ ([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2} ]]; then
        local mac="${BASH_REMATCH[0]}"
        if ! is_allowed "$file" "$mac"; then
            echo "$file:$lineno: [MAC] $mac"
            VIOLATIONS=$((VIOLATIONS + 1))
        fi
    fi

    # Absolute local paths
    if [[ "$line" =~ /Users/[a-zA-Z][a-zA-Z0-9_.-]* ]] || [[ "$line" =~ /home/[a-zA-Z][a-zA-Z0-9_.-]* ]] || \
       [[ "$line" =~ [A-Z]:\\Users\\[a-zA-Z][a-zA-Z0-9_.-]* ]] || [[ "$line" =~ [A-Z]:/Users/[a-zA-Z][a-zA-Z0-9_.-]* ]]; then
        local path="${BASH_REMATCH[0]}"
        if [[ ! "$line" =~ /home/linuxbrew ]] && ! is_allowed "$file" "$path"; then
            echo "$file:$lineno: [path] $path"
            VIOLATIONS=$((VIOLATIONS + 1))
        fi
    fi

    # MSYS absolute paths: /<drive>/<name> (e.g. /c/..., /d/...)
    if [[ "$line" =~ (^|[^[:alnum:]_/])/[a-z]/[[:alnum:]_.-] ]]; then
        local mpath="${BASH_REMATCH[0]}"
        if ! is_allowed "$file" "$line"; then
            echo "$file:$lineno: [msys-path] $mpath"
            VIOLATIONS=$((VIOLATIONS + 1))
        fi
    fi

    # WSL absolute paths: /mnt/<drive>/<name>
    if [[ "$line" =~ (^|[^[:alnum:]_/])/mnt/[a-z]/[[:alnum:]_.-] ]]; then
        local wpath="${BASH_REMATCH[0]}"
        if ! is_allowed "$file" "$line"; then
            echo "$file:$lineno: [wsl-path] $wpath"
            VIOLATIONS=$((VIOLATIONS + 1))
        fi
    fi

    # Hard secrets: provider API keys and tokens (Gitleaks-derived patterns)
    # Anthropic checked before OpenAI — both use sk- prefix, Anthropic is more specific
    local hs_workline="$line"

    local hs_anthropic_re='sk-ant-(api|sid)[0-9]{2}-[A-Za-z0-9_-]{20,}'
    if [[ "$hs_workline" =~ $hs_anthropic_re ]]; then
        local m="${BASH_REMATCH[0]}"
        if ! is_allowed "$file" "$m"; then
            echo "$file:$lineno: [anthropic-key] $m"
            VIOLATIONS=$((VIOLATIONS + 1))
        fi
        hs_workline="${hs_workline/"$m"/}"
    fi

    local hs_openai_re='sk-(proj-|svcacct-)?[A-Za-z0-9_-]{20,}'
    if [[ "$hs_workline" =~ $hs_openai_re ]]; then
        local m="${BASH_REMATCH[0]}"
        if ! is_allowed "$file" "$m"; then
            echo "$file:$lineno: [openai-key] $m"
            VIOLATIONS=$((VIOLATIONS + 1))
        fi
    fi

    if [[ "$line" =~ AKIA[0-9A-Z]{16} ]]; then
        local m="${BASH_REMATCH[0]}"
        if ! is_allowed "$file" "$m"; then
            echo "$file:$lineno: [aws-key] $m"
            VIOLATIONS=$((VIOLATIONS + 1))
        fi
    fi

    local hs_pem_re='-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'
    if [[ "$line" =~ $hs_pem_re ]]; then
        local m="${BASH_REMATCH[0]}"
        if ! is_allowed "$file" "$m"; then
            echo "$file:$lineno: [private-key] $m"
            VIOLATIONS=$((VIOLATIONS + 1))
        fi
    fi

    if [[ "$line" =~ gh[pousr]_[A-Za-z0-9]{36,} ]]; then
        local m="${BASH_REMATCH[0]}"
        if ! is_allowed "$file" "$m"; then
            echo "$file:$lineno: [github-token] $m"
            VIOLATIONS=$((VIOLATIONS + 1))
        fi
    fi

    local hs_slack_re='xox[baprs]-[0-9]+-[0-9]+-[A-Za-z0-9]+'
    if [[ "$line" =~ $hs_slack_re ]]; then
        local m="${BASH_REMATCH[0]}"
        if ! is_allowed "$file" "$m"; then
            echo "$file:$lineno: [slack-token] $m"
            VIOLATIONS=$((VIOLATIONS + 1))
        fi
    fi

    if [[ "$line" =~ AIza[0-9A-Za-z_-]{35} ]]; then
        local m="${BASH_REMATCH[0]}"
        if ! is_allowed "$file" "$m"; then
            echo "$file:$lineno: [google-key] $m"
            VIOLATIONS=$((VIOLATIONS + 1))
        fi
    fi

    if [[ "$line" =~ hf_[A-Za-z0-9]{34,} ]]; then
        local m="${BASH_REMATCH[0]}"
        if ! is_allowed "$file" "$m"; then
            echo "$file:$lineno: [huggingface-token] $m"
            VIOLATIONS=$((VIOLATIONS + 1))
        fi
    fi

    if [[ "$line" =~ gsk_[A-Za-z0-9]{20,} ]]; then
        local m="${BASH_REMATCH[0]}"
        if ! is_allowed "$file" "$m"; then
            echo "$file:$lineno: [groq-key] $m"
            VIOLATIONS=$((VIOLATIONS + 1))
        fi
    fi

    if [[ "$line" =~ r8_[A-Za-z0-9]{37} ]]; then
        local m="${BASH_REMATCH[0]}"
        if ! is_allowed "$file" "$m"; then
            echo "$file:$lineno: [replicate-token] $m"
            VIOLATIONS=$((VIOLATIONS + 1))
        fi
    fi

    if [[ "$line" =~ co_[A-Za-z0-9]{40} ]]; then
        local m="${BASH_REMATCH[0]}"
        if ! is_allowed "$file" "$m"; then
            echo "$file:$lineno: [cohere-key] $m"
            VIOLATIONS=$((VIOLATIONS + 1))
        fi
    fi

    # Zero-width / BOM (Trojan Source — homoglyph/invisible identifier trick)
    # U+200B (E2 80 8B), U+200C (8C), U+200D (8D), U+FEFF (EF BB BF)
    local zw_re=$'\xe2\x80[\x8b-\x8d]|\xef\xbb\xbf'
    if [[ "$line" =~ $zw_re ]]; then
        if ! is_allowed "$file" "$line"; then
            echo "$file:$lineno: [zero-width] <hidden char>"
            VIOLATIONS=$((VIOLATIONS + 1))
        fi
    fi

    # Bidi overrides (Trojan Source — display vs. execution divergence, CVE-2021-42574)
    # U+202D/E (E2 80 AD/AE), U+2066-2069 (E2 81 A6-A9)
    local bidi_re=$'\xe2\x80[\xad\xae]|\xe2\x81[\xa6-\xa9]'
    if [[ "$line" =~ $bidi_re ]]; then
        if ! is_allowed "$file" "$line"; then
            echo "$file:$lineno: [bidi-override] <hidden char>"
            VIOLATIONS=$((VIOLATIONS + 1))
        fi
    fi

    # Blocklist patterns
    for pattern in "${BLOCK_PATTERNS[@]+"${BLOCK_PATTERNS[@]}"}"; do
        if [[ "$line" =~ $pattern ]]; then
            local match="${BASH_REMATCH[0]}"
            if ! is_allowed "$file" "$match"; then
                echo "$file:$lineno: [blocklist] $match"
                VIOLATIONS=$((VIOLATIONS + 1))
            fi
        fi
    done
}

# Main: scan content
scan_content() {
    local file="$1"
    local lineno=0
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        scan_line "$file" "$lineno" "$line"
    done
}

if [ "$MODE" = "stdin" ]; then
    scan_content "$LABEL"
else
    for f in "$@"; do
        if [ -f "$f" ]; then
            scan_content "$f" < "$f"
        else
            echo "Warning: $f not found, skipping" >&2
        fi
    done
fi

if [ "$VIOLATIONS" -gt 0 ]; then
    echo ""
    echo "Found $VIOLATIONS private information violation(s)"
    exit 1
fi
exit 0
