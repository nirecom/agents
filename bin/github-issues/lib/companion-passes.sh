# companion-passes.sh — sourceable lib for find-companion-issues.sh
# Exposes: companion_pass_a / companion_pass_b_identifiers /
#           companion_pass_b_candidates / companion_pass_b / companion_pass_c
# All gh calls use 2>/dev/null and || return 0 to preserve caller's set -euo pipefail.

_FIND_PRINTF_OK=0
find . -maxdepth 0 -printf '' >/dev/null 2>&1 && _FIND_PRINTF_OK=1

_find_basenames() {
    local dir="$1"; shift
    if [ "$_FIND_PRINTF_OK" -eq 1 ]; then
        find "$dir" "$@" -printf '%f\n'
    else
        find "$dir" "$@" -exec basename {} \;
    fi
}

# companion_pass_a <primary_N>
# Sets PASS_A_NUMBERS (newline-separated issue numbers from #M refs
# in primary body+comments).
companion_pass_a() {
    local primary="$1" raw text nums
    PASS_A_NUMBERS=""
    raw=$(gh issue view "$primary" --json body,comments 2>/dev/null) || return 0
    text=$(jq -r '(.body // "") + "\n" + ((.comments // []) | map(.body) | join("\n"))' <<< "$raw" 2>/dev/null) || text=""
    nums=$(grep -oE '#[0-9]+' <<< "$text" 2>/dev/null) || nums=""
    PASS_A_NUMBERS=$(tr -d '#' <<< "$nums" | sort -u)
}

# companion_pass_b_identifiers
# Sets IDENTIFIER_SET (newline-separated lowercase tokens >=4 chars
# from $AGENTS_CONFIG_DIR/{skills,hooks,bin,agents,rules}).
companion_pass_b_identifiers() {
    IDENTIFIER_SET=""
    local root="${AGENTS_CONFIG_DIR:-}"
    if [ -z "$root" ] || [ ! -d "$root" ]; then return 0; fi
    IDENTIFIER_SET=$(
        {
            [ -d "$root/skills" ] && _find_basenames "$root/skills" -mindepth 1 -maxdepth 1 -type d
            [ -d "$root/hooks" ] && _find_basenames "$root/hooks" -maxdepth 1 -type f -name '*.js' \
                | sed 's/\.js$//'
            [ -d "$root/bin" ] && _find_basenames "$root/bin" -maxdepth 1 -type f \
                | sed 's/\.\(sh\|js\|py\)$//'
            [ -d "$root/agents" ] && _find_basenames "$root/agents" -maxdepth 1 -type f -name '*.md' \
                | sed 's/\.md$//'
            [ -d "$root/rules" ] && _find_basenames "$root/rules" -maxdepth 1 -type f -name '*.md' \
                | sed 's/\.md$//'
        } 2>/dev/null \
        | tr '[:upper:]' '[:lower:]' \
        | awk 'length($0) >= 4' \
        | sort -u
    )
}

# _title_tokens <title>
# Outputs (stdout) whitespace-tokenized lowercase tokens, one per line.
_title_tokens() {
    printf '%s' "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | tr -c 'a-z0-9-_' '\n' \
        | awk 'length($0) > 0'
}

# companion_pass_b_candidates <primary_title>
# Sets PASS_B_NUMBERS (newline-separated issue numbers from gh issue list
# --search <tok> for each token in primary_title intersect IDENTIFIER_SET).
# Call after companion_pass_b_identifiers.
companion_pass_b_candidates() {
    local primary_title="$1" pt_words tok hits hits_json
    PASS_B_NUMBERS=""
    [ -z "$IDENTIFIER_SET" ] && return 0
    # Normalize once: lowercase, replace non-alnum/hyphen/underscore with space,
    # then pad with spaces so " tok " word-boundary check works without subprocesses.
    pt_words=" $(printf '%s' "$primary_title" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' ' ') "
    while IFS= read -r tok; do
        [ -z "$tok" ] && continue
        # Pure-bash word check — no subprocess per iteration.
        case "$pt_words" in *" $tok "*) ;; *) continue ;; esac
        hits_json=$(gh issue list --state open --limit 50 \
            --search "$tok" --json number \
            2>/dev/null) || continue
        hits=$(printf '%s' "$hits_json" | jq -r '.[].number' 2>/dev/null || true)
        PASS_B_NUMBERS=$(printf '%s\n%s' "$PASS_B_NUMBERS" "$hits")
    done <<< "$IDENTIFIER_SET"
    PASS_B_NUMBERS=$(printf '%s\n' "$PASS_B_NUMBERS" | grep -E '^[0-9]+$' 2>/dev/null | sort -u || true)
}

# companion_pass_b <primary_title> <candidate_title>
# Outputs (stdout) comma-separated ident:<tok> tags for tokens where <tok>
# is a substring of both lowercased titles AND present in IDENTIFIER_SET.
# Empty output = no overlap. Pure-bash loop — no subprocess per iteration.
companion_pass_b() {
    local primary_title="$1" candidate_title="$2"
    local pt_words ct_words tok matches=""
    # Normalize once each: lowercase + space-pad for word-boundary case matching.
    pt_words=" $(printf '%s' "$primary_title"  | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' ' ') "
    ct_words=" $(printf '%s' "$candidate_title" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' ' ') "
    while IFS= read -r tok; do
        [ -z "$tok" ] && continue
        # Pure-bash word check — no subprocess per iteration.
        case "$pt_words" in *" $tok "*) ;; *) continue ;; esac
        case "$ct_words" in *" $tok "*) ;; *) continue ;; esac
        matches="${matches:+$matches,}ident:$tok"
    done <<< "$IDENTIFIER_SET"
    printf '%s' "$matches"
}

# companion_pass_c <primary_N>
# Sets PASS_C_PARENT_N (parent issue number or empty) and
# PASS_C_SIBLINGS (newline-separated sibling numbers, primary excluded).
companion_pass_c() {
    local primary="$1" repo parent_n sibs
    local repo_json issue_json sibs_json
    PASS_C_PARENT_N=""
    PASS_C_SIBLINGS=""
    repo_json=$(gh repo view --json nameWithOwner 2>/dev/null) || return 0
    repo=$(printf '%s' "$repo_json" | jq -r '.nameWithOwner // ""' 2>/dev/null || true)
    [ -z "$repo" ] && return 0
    # Validate repo format before URL interpolation.
    [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 0
    issue_json=$(gh api "repos/$repo/issues/$primary" 2>/dev/null) || return 0
    parent_n=$(printf '%s' "$issue_json" | jq -r '.parent.number // empty' 2>/dev/null || true)
    [ -z "$parent_n" ] && return 0
    # Validate parent_n is numeric before URL interpolation.
    [[ "$parent_n" =~ ^[0-9]+$ ]] || return 0
    PASS_C_PARENT_N="$parent_n"
    sibs_json=$(gh api "repos/$repo/issues/$PASS_C_PARENT_N/sub_issues" --paginate 2>/dev/null) || return 0
    sibs=$(printf '%s' "$sibs_json" \
        | jq -r '.[] | select(.state=="open") | .number' 2>/dev/null || true)
    PASS_C_SIBLINGS=$(printf '%s\n' "$sibs" | awk -v p="$primary" '$1 != p && $1 != "" {print}' | sort -u)
}
