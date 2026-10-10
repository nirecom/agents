#!/bin/bash
# Scan content for private information patterns
# Usage:
#   scan-outbound.sh [--stdin [label]] [file ...]
#   scan-outbound.sh --manifest   (RS-framed multi-file stream: RS+path+RS+len+LF+bytes...)
#   --stdin: read from stdin (optional label for output)
#   --manifest: read RS(0x1e)+path+RS+byteLen+LF+bytes frames from stdin
#   file args: scan named files
# Exit: 0 = clean, 1 = hard violation, 2 = warn-only (no hard), 3 = usage error,
#       4 = blocklist resolution or hard-secret pattern load error (fail-closed)
# NOTE: exit 3 was previously exit 2 (usage error). Bumped to free exit 2 for warn-only.

set -euo pipefail

# Hard secrets: provider API keys and tokens (Gitleaks-derived), the single source
# of truth also parsed by hooks/workflow-state/complexity-routing/secret-shape.js —
# so they live in this file rather than a sibling a copied scanner could lose.
# Entry: '<label> <group> <ERE>' — one per line, single-quoted, no ' in the ERE, and
# only syntax valid in both bash ERE and JS RegExp. Entries sharing a group (not -)
# test one work line in order, each match removed before the next: Anthropic is
# checked before OpenAI because both start sk- and Anthropic is more specific.
# BEGIN hard-secret-patterns
HARD_SECRET_PATTERNS=(
    'anthropic-key sk sk-ant-(api|sid)[0-9]{2}-[A-Za-z0-9_-]{20,}'
    'openai-key sk sk-(proj-|svcacct-)?[A-Za-z0-9_-]{20,}'
    'aws-key - AKIA[0-9A-Z]{16}'
    'private-key - -----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'
    'github-token - gh[pousr]_[A-Za-z0-9]{36,}'
    'slack-token - xox[baprs]-[0-9]+-[0-9]+-[A-Za-z0-9]+'
    'google-key - AIza[0-9A-Za-z_-]{35}'
    'huggingface-token - hf_[A-Za-z0-9]{34,}'
    'groq-key - gsk_[A-Za-z0-9]{20,}'
    'replicate-token - r8_[A-Za-z0-9]{37}'
    'cohere-key - co_[A-Za-z0-9]{40}'
)
# END hard-secret-patterns

HS_LABELS=()
HS_GROUPS=()
HS_RES=()
for _hs_entry in "${HARD_SECRET_PATTERNS[@]}"; do
    _hs_label="${_hs_entry%% *}"
    _hs_rest="${_hs_entry#* }"
    _hs_group="${_hs_rest%% *}"
    _hs_re="${_hs_rest#* }"
    if [[ -z "$_hs_label" || -z "$_hs_group" || -z "$_hs_re" || "$_hs_rest" == "$_hs_entry" || "$_hs_re" == "$_hs_rest" ]]; then
        printf 'Error: malformed hard-secret pattern entry — cannot scan\n' >&2
        exit 4
    fi
    HS_LABELS+=("$_hs_label")
    HS_GROUPS+=("$_hs_group")
    HS_RES+=("$_hs_re")
done
if [ "${#HS_RES[@]}" -eq 0 ]; then
    printf 'Error: no hard-secret patterns loaded — cannot scan\n' >&2
    exit 4
fi
unset _hs_entry _hs_label _hs_rest _hs_group _hs_re

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Anchor: AGENTS_MAIN_ROOT when set (handles linked worktrees where gitignored
# dotfiles exist only in the main repo root, not the worktree root); falls back
# to SCRIPT_DIR/.. for direct invocation and test sandboxes that unset it.
_anchor="${AGENTS_MAIN_ROOT:-$SCRIPT_DIR/..}"; ALLOWLIST="$_anchor/.private-info-allowlist"; BLOCKLIST="$_anchor/.private-info-blocklist"

VIOLATIONS=0
WARNINGS=0
MODE=""
LABEL="stdin"

# Parse arguments
if [ $# -eq 0 ]; then
    echo "Usage: scan-outbound.sh [--stdin [label]] [--manifest] [file ...]" >&2
    exit 3
fi

if [ "$1" = "--stdin" ]; then
    MODE="stdin"
    shift
    if [ $# -gt 0 ]; then
        LABEL="$1"
        shift
    fi
elif [ "$1" = "--manifest" ]; then
    MODE="manifest"
    shift
else
    MODE="files"
fi

# Load allowlist patterns (skip comments and empty lines)
ALLOW_PATTERNS=()
if [ ! -f "$ALLOWLIST" ]; then
    printf 'Warning: allowlist not found at %s — proceeding without allowlist\n' "$ALLOWLIST" >&2
elif [ -f "$ALLOWLIST" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        ALLOW_PATTERNS+=("$line")
    done < "$ALLOWLIST"
fi

# Load blocklist patterns (split into hard / warn tiers)
# Lines starting with `warn:` are soft-block patterns; others are hard.
BLOCK_HARD_PATTERNS=()
BLOCK_WARN_PATTERNS=()
if [ ! -f "$BLOCKLIST" ]; then
    printf 'Error: blocklist not found at expected path (AGENTS_MAIN_ROOT resolution) — cannot scan\n' >&2
    exit 4
elif [ -f "$BLOCKLIST" ]; then
    _bl_lineno=0
    while IFS= read -r line || [ -n "$line" ]; do
        _bl_lineno=$((_bl_lineno + 1))
        line="${line%$'\r'}"
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        if [[ "$line" == warn:* ]]; then
            pat="${line#warn:}"
            if [ -z "$pat" ]; then
                # Empty regex would match every line; skip and warn
                printf 'Warning: empty warn pattern at %s line %d — skipped\n' "$BLOCKLIST" "$_bl_lineno" >&2
                continue
            fi
            BLOCK_WARN_PATTERNS+=("$pat")
        else
            BLOCK_HARD_PATTERNS+=("$line")
        fi
    done < "$BLOCKLIST"
    unset _bl_lineno pat
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

    # Hard secrets (HARD_SECRET_PATTERNS)
    local hs_i hs_group hs_subject hs_m hs_work_group="" hs_workline=""
    for hs_i in "${!HS_RES[@]}"; do
        hs_group="${HS_GROUPS[hs_i]}"
        if [[ "$hs_group" == "-" ]]; then
            hs_subject="$line"
        else
            if [[ "$hs_group" != "$hs_work_group" ]]; then
                hs_work_group="$hs_group"
                hs_workline="$line"
            fi
            hs_subject="$hs_workline"
        fi
        if [[ "$hs_subject" =~ ${HS_RES[hs_i]} ]]; then
            hs_m="${BASH_REMATCH[0]}"
            if ! is_allowed "$file" "$hs_m"; then
                echo "$file:$lineno: [${HS_LABELS[hs_i]}] $hs_m"
                VIOLATIONS=$((VIOLATIONS + 1))
            fi
            if [[ "$hs_group" != "-" ]]; then
                hs_workline="${hs_workline/"$hs_m"/}"
            fi
        fi
    done

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

    # Blocklist patterns (hard tier)
    for pattern in "${BLOCK_HARD_PATTERNS[@]+"${BLOCK_HARD_PATTERNS[@]}"}"; do
        if [[ "$line" =~ $pattern ]]; then
            local match="${BASH_REMATCH[0]}"
            if ! is_allowed "$file" "$match"; then
                echo "$file:$lineno: [blocklist] $match"
                VIOLATIONS=$((VIOLATIONS + 1))
            fi
        fi
    done

    # Blocklist patterns (warn tier — soft-block, exit code 2)
    for pattern in "${BLOCK_WARN_PATTERNS[@]+"${BLOCK_WARN_PATTERNS[@]}"}"; do
        if [[ "$line" =~ $pattern ]]; then
            local match="${BASH_REMATCH[0]}"
            if ! is_allowed "$file" "$match"; then
                echo "$file:$lineno: [blocklist-warn] $match"
                WARNINGS=$((WARNINGS + 1))
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

# Scan a RS(0x1e)-framed manifest stream from stdin.
# Frame format: RS + repo-relative-path + RS + byte-length (decimal) + LF + raw-bytes
scan_manifest() {
    local _rs _header _trimmed _mpath _mlen
    _rs=$(printf '\036')
    while IFS= read -r _header; do
        _trimmed="${_header#"$_rs"}"
        _mpath="${_trimmed%%"$_rs"*}"
        _mlen="${_trimmed##*"$_rs"}"
        [ -z "$_mpath" ] && continue
        [ -z "$_mlen" ] && continue
        scan_content "$_mpath" < <(dd bs=1 count="$_mlen" 2>/dev/null)
    done
}

if [ "$MODE" = "stdin" ]; then
    scan_content "$LABEL"
elif [ "$MODE" = "manifest" ]; then
    scan_manifest
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
    echo "Found $VIOLATIONS hard violation(s), $WARNINGS warning(s)"
    exit 1
fi
if [ "$WARNINGS" -gt 0 ]; then
    echo ""
    echo "Found $WARNINGS warning(s) (no hard violation)"
    exit 2
fi
exit 0
