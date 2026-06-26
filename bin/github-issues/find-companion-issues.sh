#!/usr/bin/env bash
# find-companion-issues.sh --primary <N> [--exclude <N>[,<N>...]] [--max-candidates <int>]
#
# Discover open GitHub issues related to <primary> via three explicit signals:
# (A) cross-reference (#M in primary body+comments), (B) identifier overlap
# (token shared in both titles AND in $AGENTS_CONFIG_DIR/{skills,hooks,bin,agents,rules}
# code-identifier namespace), and (C) sub-issue siblings (only when Pass B fires).
#
# stdout (TSV, one candidate per line; no header):
#   <issue-number>\t<title>\t<reason>\t<state>
# reason: comma-separated tag list: xref | ident:<tok> | sibling-of:#<P>
# Sorted by tag-count desc, then issue-number asc. Empty stdout = no candidates.
#
# stderr: human-readable diagnostics only.
#
# Exit codes:
#   0 — search completed (zero or more candidates emitted)
#   1 — gh failure / non-GitHub remote / unreachable primary issue
#   2 — bad arguments
set -euo pipefail

: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR not set}"

PRIMARY=""
EXCLUDE_CSV=""
MAX_CANDIDATES=5

while [[ $# -gt 0 ]]; do
    case "$1" in
        --primary)
            PRIMARY="${2:-}"
            shift 2
            ;;
        --exclude)
            EXCLUDE_CSV="${2:-}"
            shift 2
            ;;
        --max-candidates)
            MAX_CANDIDATES="${2:-}"
            shift 2
            ;;
        *)
            echo "[find-companion-issues] unknown argument: $1" >&2
            echo "Usage: find-companion-issues.sh --primary <N> [--exclude <N>[,<N>...]] [--max-candidates <int>]" >&2
            exit 2
            ;;
    esac
done

if [[ -z "$PRIMARY" ]] || [[ ! "$PRIMARY" =~ ^[0-9]+$ ]]; then
    echo "[find-companion-issues] --primary <N> required (numeric)" >&2
    exit 2
fi

if [[ ! "$MAX_CANDIDATES" =~ ^[0-9]+$ ]] || [[ "$MAX_CANDIDATES" -lt 1 ]]; then
    echo "[find-companion-issues] --max-candidates must be a positive integer" >&2
    exit 2
fi

# NON_GITHUB gate — must be the very first runtime check.
if command -v is-github-dotcom-remote >/dev/null 2>&1; then
    _NGH_CMD=is-github-dotcom-remote
else
    _NGH_CMD="${AGENTS_CONFIG_DIR}/bin/is-github-dotcom-remote"
fi
if ! "${_NGH_CMD}" >/dev/null 2>&1; then
    echo "[find-companion-issues] non-GitHub remote — skipping" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/companion-passes.sh
. "$SCRIPT_DIR/lib/companion-passes.sh"

if ! PRIMARY_JSON=$(gh issue view "$PRIMARY" --json number,title,body 2>/dev/null); then
    echo "[find-companion-issues] gh issue view failed for #$PRIMARY" >&2
    exit 1
fi
PRIMARY_TITLE=$(printf '%s' "$PRIMARY_JSON" | jq -r '.title // ""')

# Build exclude set. Primary is always excluded first.
declare -A EXCLUDE_SET
EXCLUDE_SET["$PRIMARY"]=1
if [[ -n "$EXCLUDE_CSV" ]]; then
    IFS=',' read -ra EXCLUDE_ARR <<< "$EXCLUDE_CSV"
    for n in "${EXCLUDE_ARR[@]}"; do
        n="${n// /}"
        if [[ -n "$n" ]] && [[ "$n" =~ ^[0-9]+$ ]]; then
            EXCLUDE_SET["$n"]=1
        fi
    done
fi

companion_pass_a "$PRIMARY"
companion_pass_b_identifiers
companion_pass_b_candidates "$PRIMARY_TITLE"
companion_pass_c "$PRIMARY"

declare -A CAND_SEEN
declare -a CANDIDATES=()
add_candidate() {
    local n="$1"
    [ -z "$n" ] && return
    [[ ! "$n" =~ ^[0-9]+$ ]] && return
    [ -n "${EXCLUDE_SET[$n]:-}" ] && return
    [ -n "${CAND_SEEN[$n]:-}" ] && return
    CAND_SEEN[$n]=1
    CANDIDATES+=("$n")
}
while IFS= read -r n; do add_candidate "$n"; done <<< "$PASS_A_NUMBERS"
while IFS= read -r n; do add_candidate "$n"; done <<< "$PASS_B_NUMBERS"
while IFS= read -r n; do add_candidate "$n"; done <<< "$PASS_C_SIBLINGS"

[ "${#CANDIDATES[@]}" -eq 0 ] && exit 0

for n in "${CANDIDATES[@]}"; do
    if ! cand_json=$(gh issue view "$n" --json number,title,labels,state 2>/dev/null); then
        continue
    fi
    cand_title=$(printf '%s' "$cand_json" | jq -r '.title // ""' | tr -d '\t\n\r')
    cand_state=$(printf '%s' "$cand_json" | jq -r '.state // ""')
    cand_labels=$(printf '%s' "$cand_json" | jq -r '[.labels[].name] | join(",")' 2>/dev/null || true)
    [ "$cand_state" = "OPEN" ] || continue
    if printf '%s' ",$cand_labels," | grep -q ',meta,'; then continue; fi

    # 3-axis filter axis 1: CLOSED — handled above (cand_state=OPEN check)
    # 3-axis filter axis 2: parent filter — skip if candidate IS the primary's parent issue
    # (PASS_C_PARENT_N holds the primary's parent number from companion_pass_c; empty = no parent)
    if [[ -n "$PASS_C_PARENT_N" ]] && [[ "$n" = "$PASS_C_PARENT_N" ]]; then continue; fi
    # 3-axis filter axis 3: WIP filter — skip if owned by another session
    _wip_check_result=""
    _wip_rc=0
    _wip_check_result=$(bash "$AGENTS_CONFIG_DIR/bin/github-issues/wip-state.sh" check "$n" 2>/dev/null) || _wip_rc=$?
    if [[ $_wip_rc -eq 0 ]] && [[ "$_wip_check_result" = "other" ]]; then continue; fi

    reasons=""
    if printf '%s\n' "$PASS_A_NUMBERS" | grep -qx "$n"; then
        reasons="xref"
    fi
    pb=$(companion_pass_b "$PRIMARY_TITLE" "$cand_title")
    if [ -n "$pb" ]; then
        reasons="${reasons:+$reasons,}$pb"
    fi
    if [ -n "$pb" ] && [ -n "$PASS_C_PARENT_N" ] && \
       printf '%s\n' "$PASS_C_SIBLINGS" | grep -qx "$n"; then
        reasons="${reasons:+$reasons,}sibling-of:#${PASS_C_PARENT_N}"
    fi

    [ -z "$reasons" ] && continue
    tag_count=$(( $(printf '%s' "$reasons" | tr -cd , | wc -c) + 1 ))
    printf '%d\t%s\t%s\t%s\n' "$tag_count" "$n" "$cand_title" "$reasons"
done | sort -t $'\t' -k1,1nr -k2,2n \
     | awk -F'\t' -v OFS='\t' '{print $2, $3, $4, "OPEN"}' \
     | head -n "$MAX_CANDIDATES"
