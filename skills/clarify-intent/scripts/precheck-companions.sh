#!/usr/bin/env bash
# precheck-companions.sh — companion pre-check phase for clarify-intent CI-2b (#1237)
# Args: --seed <N> --exclude <csv> [--session <sid>]
# stdout: 7-column TSV per candidate:
#   N\ttitle\treason\tstate\tpurity-flag\tdecomp-verdict\tcompanion-driven-signals
# exit: 0 candidates exist, 1 no candidates, 2 usage / unresolved control dir
# Phases: 1 companion-search.sh → candidate TSV; 2 ident-only candidates → purity-flag=low-purity (kept);
#   3-5 decomposition trials — baseline (seed only), full set, per candidate (placeholders);
#   6 --session: JSON snapshot of baseline + per-candidate verdicts at <session control dir>/companion-precheck.json.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

SEED=""
EXCLUDE_CSV=""
SESSION=""
LEGACY_OUTPUT=""
OUTPUT_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --seed)        SEED="${2:-}"; shift 2 ;;
        --exclude)     EXCLUDE_CSV="${2:-}"; shift 2 ;;
        --session)     SESSION="${2:-}"; shift 2 ;;
        --output-file) LEGACY_OUTPUT="${2:-}"; shift 2 ;;
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

# --- BEGIN temporary: plans-dir control files -> workflow control dir migration added 2026-09-28 ---
# deletion-condition: remove after 2026-12-28 (release + 3 months) together with hooks/lib/temporary-migrations/control-dir-split/, bin/migrate-control-dir and the legacy-argument shims; keep guard (c) until then
if [[ -n "$LEGACY_OUTPUT" ]]; then
    if ! LEGACY_HIT="$(node "${SCRIPT_CHECKOUT_ROOT}/hooks/lib/temporary-migrations/control-dir-split/legacy-arg.js" "$LEGACY_OUTPUT" "$SESSION" companion-precheck.json)"; then
        echo "[precheck-companions] --output-file is accepted only as the legacy session-prefixed companion-precheck.json path in the plans dir" >&2
        exit 2
    fi
    SESSION="${LEGACY_HIT%%$'\t'*}"
fi
# --- END temporary: plans-dir control files -> workflow control dir migration ---

if [[ -n "$SESSION" ]]; then
    if ! OUTPUT_FILE="$(node "${SCRIPT_CHECKOUT_ROOT}/bin/workflow-control-dir" --session "$SESSION" --file companion-precheck.json --for-write)"; then
        echo "[precheck-companions] session control directory unresolved for '$SESSION'" >&2
        exit 2
    fi
fi

# Locate companion-search.sh: prefer sibling, then PATH
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPANION_SEARCH="${SCRIPT_DIR}/companion-search.sh"
if [[ ! -x "$COMPANION_SEARCH" ]]; then
    COMPANION_SEARCH="companion-search.sh"
fi

# Phase 1: get candidates via companion-search.sh
SEARCH_ARGS=("--seed" "$SEED")
[[ -n "$EXCLUDE_CSV" ]] && SEARCH_ARGS+=("--exclude" "$EXCLUDE_CSV")
CAND_TSV=""
CAND_TSV=$(bash "$COMPANION_SEARCH" "${SEARCH_ARGS[@]}" 2>/dev/null) || exit 1
[[ -z "$CAND_TSV" ]] && exit 1

# Phases 2-5: process each candidate
declare -a OUTPUT_ROWS=()
declare -a JSON_CANDS=()

while IFS=$'\t' read -r N title reason state _rest; do
    [[ -z "$N" ]] && continue

    # Phase 2: purity flag — low-purity when ONLY ident: tags (no file:/xref/sibling-of:/kw:)
    purity_flag="ok"
    if [[ "$reason" =~ ident: ]] \
        && ! [[ "$reason" =~ (^|,)(xref|file:|sibling-of:|kw:) ]]; then
        purity_flag="low-purity"
    fi

    # Phases 3-5: decomposition verdict (placeholder — real evaluation reads judge-decomposition.md)
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

# Phase 6: write the JSON snapshot when a session was given
if [[ -n "$OUTPUT_FILE" ]]; then
    CANDS_JSON=$(printf '%s,' "${JSON_CANDS[@]}")
    CANDS_JSON="[${CANDS_JSON%,}]"
    jq -n --argjson seed "$SEED" --argjson cands "$CANDS_JSON" \
        '{"seed":$seed,"baseline_verdict":"wf-code","baseline_signals":[],"candidates":$cands}' \
        > "$OUTPUT_FILE"
fi

exit 0
