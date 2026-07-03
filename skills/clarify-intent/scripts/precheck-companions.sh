#!/usr/bin/env bash
# precheck-companions.sh — companion pre-check phase for clarify-intent CI-2b (#1237)
# Args: --seed <N> --exclude <csv> [--output-file <path>]
# stdout: 7-column TSV per candidate:
#   N\ttitle\treason\tstate\tpurity-flag\tdecomp-verdict\tcompanion-driven-signals
# exit: 0 candidates exist, 1 no candidates
#
# Steps:
#   1. companion-search.sh --seed <N> --exclude <csv> → candidate TSV (exit 1 = no candidates)
#   2. ident-only candidates → purity-flag=low-purity (kept, annotated)
#   3. baseline decomposition trial (seed-only, placeholder)
#   4. full-set trial (seed + all candidates, placeholder)
#   5. per-candidate trial (seed + {M}, placeholder)
#   6. --output-file: JSON snapshot of baseline + per-candidate verdicts
set -uo pipefail

SEED=""
EXCLUDE_CSV=""
OUTPUT_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --seed)        SEED="${2:-}"; shift 2 ;;
        --exclude)     EXCLUDE_CSV="${2:-}"; shift 2 ;;
        --output-file) OUTPUT_FILE="${2:-}"; shift 2 ;;
        *) echo "[precheck-companions] unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$SEED" ]]; then
    echo "[precheck-companions] --seed required" >&2
    exit 2
fi
if [[ ! "$SEED" =~ ^[0-9]+$ ]]; then
    echo "[precheck-companions] --seed must be a positive integer" >&2
    exit 2
fi

# Locate companion-search.sh: prefer sibling, then PATH
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPANION_SEARCH="${SCRIPT_DIR}/companion-search.sh"
if [[ ! -x "$COMPANION_SEARCH" ]]; then
    COMPANION_SEARCH="companion-search.sh"
fi

# Step 1: get candidates via companion-search.sh
SEARCH_ARGS=("--seed" "$SEED")
[[ -n "$EXCLUDE_CSV" ]] && SEARCH_ARGS+=("--exclude" "$EXCLUDE_CSV")
CAND_TSV=""
CAND_TSV=$(bash "$COMPANION_SEARCH" "${SEARCH_ARGS[@]}" 2>/dev/null) || exit 1
[[ -z "$CAND_TSV" ]] && exit 1

# Steps 2-5: process each candidate
declare -a OUTPUT_ROWS=()
declare -a JSON_CANDS=()

while IFS=$'\t' read -r N title reason state _rest; do
    [[ -z "$N" ]] && continue

    # Step 2: purity flag — low-purity when ONLY ident: tags (no file:/xref/sibling-of:/kw:)
    purity_flag="ok"
    if [[ "$reason" =~ ident: ]] \
        && ! [[ "$reason" =~ (^|,)(xref|file:|sibling-of:|kw:) ]]; then
        purity_flag="low-purity"
    fi

    # Steps 3-5: decomposition verdict (placeholder — real evaluation reads judge-decomposition.md)
    decomp_verdict="wf-code"
    companion_driven_signals=""

    OUTPUT_ROWS+=("${N}"$'\t'"${title}"$'\t'"${reason}"$'\t'"${state}"$'\t'"${purity_flag}"$'\t'"${decomp_verdict}"$'\t'"${companion_driven_signals}")
    JSON_CANDS+=("$(jq -n --argjson n "$N" --arg title "$title" --arg reason "$reason" --arg state "$state" --arg purity "$purity_flag" --arg decomp "$decomp_verdict" '{number:$n,title:$title,reason:$reason,state:$state,purity:$purity,decomp_verdict:$decomp}')")
done <<< "$CAND_TSV"

[[ "${#OUTPUT_ROWS[@]}" -eq 0 ]] && exit 1

# Emit TSV
for row in "${OUTPUT_ROWS[@]}"; do
    printf '%s\n' "$row"
done

# Step 6: write JSON snapshot if --output-file specified
if [[ -n "$OUTPUT_FILE" ]]; then
    CANDS_JSON=$(printf '%s,' "${JSON_CANDS[@]}")
    CANDS_JSON="[${CANDS_JSON%,}]"
    jq -n --argjson seed "$SEED" --argjson cands "$CANDS_JSON" \
        '{"seed":$seed,"baseline_verdict":"wf-code","baseline_signals":[],"candidates":$cands}' \
        > "$OUTPUT_FILE"
fi

exit 0
