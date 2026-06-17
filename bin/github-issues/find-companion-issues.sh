#!/usr/bin/env bash
# find-companion-issues.sh --primary <N> [--exclude <N>[,<N>...]] [--max-candidates <int>]
#
# Discover open GitHub issues that look related to a primary issue, using a
# 2-pass keyword search over the primary's title+body tokens.
#
# stdout (TSV, one candidate per line; no header):
#   <issue-number>\t<title>\t<matched-token-count>\t<state>
# Sorted by matched-token-count desc, then issue-number asc. Empty stdout = no candidates.
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
# Prefer PATH lookup so tests can inject mocks; fall back to absolute path if absent.
if command -v is-github-dotcom-remote >/dev/null 2>&1; then
    _NGH_CMD=is-github-dotcom-remote
else
    _NGH_CMD="${AGENTS_CONFIG_DIR}/bin/is-github-dotcom-remote"
fi
if ! "${_NGH_CMD}" >/dev/null 2>&1; then
    echo "[find-companion-issues] non-GitHub remote — skipping" >&2
    exit 1
fi

# Fetch primary issue.
if ! PRIMARY_JSON=$(gh issue view "$PRIMARY" --json number,title,body,labels 2>/dev/null); then
    echo "[find-companion-issues] gh issue view failed for #$PRIMARY" >&2
    exit 1
fi

# Stopwords (space-separated for grep -wF -f).
STOPWORDS="the and for this that with from into when then been have will which your their there these those about after before issue error should would could using make used also just does more like some what over than such only other need both each same most"

# Extract tokens from title+body: ≥4-char, lowercase, alnum, drop stopwords,
# sort by frequency desc, take top 5.
TITLE_BODY=$(printf '%s' "$PRIMARY_JSON" | jq -r '(.title // "") + " " + (.body // "")')

# Build stopword file for fast filtering.
STOPWORD_FILE=$(mktemp)
trap 'rm -f "$STOPWORD_FILE"' EXIT
# shellcheck disable=SC2086  # intentional word-splitting to one-word-per-line
printf '%s\n' $STOPWORDS > "$STOPWORD_FILE"

# Tokenize: lowercase, split on non-alnum, keep ≥4-char, drop stopwords, dedup-by-frequency.
mapfile -t TOP_TOKENS < <(
    printf '%s' "$TITLE_BODY" \
        | tr '[:upper:]' '[:lower:]' \
        | tr -c 'a-z0-9' '\n' \
        | awk 'length($0) >= 3' \
        | grep -vxFf "$STOPWORD_FILE" \
        | sort \
        | uniq -c \
        | sort -k1,1nr -k2,2 \
        | awk '{print $2}' \
        | head -n 5
)

if [[ "${#TOP_TOKENS[@]}" -lt 2 ]]; then
    echo "[find-companion-issues] fewer than 2 useful tokens extracted — skipping search" >&2
    exit 0
fi

# Build exclude set.
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

# Helper: run a single keyword search pass and emit raw TSV lines
# (number\ttitle\tlabels_csv\tstate). Best-effort: warn on failure, emit nothing.
# Pipes gh output through jq separately so PATH-based mock gh works in tests.
run_search() {
    local query="$1"
    local json raw
    if json=$(gh issue list --state open --limit 50 --search "$query" \
            --json number,title,labels,state \
            2>/dev/null); then
        raw=$(printf '%s' "$json" \
            | jq -r '.[] | [.number, .title, (.labels | map(.name) | join(",")), .state] | @tsv' \
            2>/dev/null || true)
        printf '%s\n' "$raw"
    else
        echo "[find-companion-issues] gh issue list failed for query: $query" >&2
    fi
}

# Pass 1 — first 3 tokens.
PASS1_QUERY="${TOP_TOKENS[0]} ${TOP_TOKENS[1]}"
if [[ "${#TOP_TOKENS[@]}" -ge 3 ]]; then
    PASS1_QUERY="${TOP_TOKENS[0]} ${TOP_TOKENS[1]} ${TOP_TOKENS[2]}"
fi
PASS1_RAW=$(run_search "$PASS1_QUERY" || true)

# Pass 2 — tokens 4-5, or token1 alone, or skip if <2 tokens total.
PASS2_RAW=""
if [[ "${#TOP_TOKENS[@]}" -ge 5 ]]; then
    PASS2_QUERY="${TOP_TOKENS[3]} ${TOP_TOKENS[4]}"
    PASS2_RAW=$(run_search "$PASS2_QUERY" || true)
elif [[ "${#TOP_TOKENS[@]}" -eq 4 ]]; then
    PASS2_QUERY="${TOP_TOKENS[3]}"
    PASS2_RAW=$(run_search "$PASS2_QUERY" || true)
fi
# (For 2-3 tokens: skip pass 2 — pass 1 already covered the meaningful tokens.)

# Merge, dedup by issue number, filter (exclude set, meta label).
declare -A SEEN
MERGED=""
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    num="${line%%	*}"
    [[ -z "$num" ]] && continue
    [[ -n "${SEEN[$num]:-}" ]] && continue
    [[ -n "${EXCLUDE_SET[$num]:-}" ]] && continue
    # labels is field 3
    labels=$(printf '%s' "$line" | awk -F'\t' '{print $3}')
    # Drop meta-labelled issues.
    if printf '%s' ",$labels," | grep -q ',meta,'; then
        continue
    fi
    SEEN["$num"]=1
    MERGED+="${line}"$'\n'
done <<< "$PASS1_RAW
$PASS2_RAW"

if [[ -z "$MERGED" ]]; then
    exit 0
fi

# Rank: count how many of TOP_TOKENS appear in each candidate's title
# (case-insensitive substring). Output: match_count\tnumber\ttitle\tstate
RANKED=""
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    num=$(printf '%s' "$line" | awk -F'\t' '{print $1}')
    title=$(printf '%s' "$line" | awk -F'\t' '{print $2}')
    state=$(printf '%s' "$line" | awk -F'\t' '{print $4}')
    title_lc=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]')
    match_count=0
    for tok in "${TOP_TOKENS[@]}"; do
        if [[ "$title_lc" == *"$tok"* ]]; then
            match_count=$((match_count + 1))
        fi
    done
    RANKED+="${match_count}	${num}	${title}	${state}"$'\n'
done <<< "$MERGED"

# Sort by match_count desc, number asc; then reorder columns to:
# number\ttitle\tmatch_count\tstate. Cap to MAX_CANDIDATES.
printf '%s' "$RANKED" \
    | grep -v '^$' \
    | sort -t $'\t' -k1,1nr -k2,2n \
    | awk -F'\t' -v OFS='\t' '{print $2, $3, $1, $4}' \
    | head -n "$MAX_CANDIDATES"

exit 0
