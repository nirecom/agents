#!/usr/bin/env bash
#
# bin/lib/concern-ledger/render.sh
#
# Sourced by bin/lib/concern-ledger.sh. The two rendered surfaces of a ledger:
# the one-line tally a review loop prints after each round, and the prior-open-
# concerns block a producer is handed before it runs. Both are read by humans or
# by an LLM, so they are kept apart from the state machine that produces them.
#
# Must be `source`d, not executed directly.

# cl_tally <ledger> — the round summary line the loops print.
cl_tally() {
    local f="$1"
    awk -F'|' -v OFS=' ' '
        /^C[0-9]+\|/ {
            if ($3 == "open" || $3 == "reopened") {
                if ($2 == "HIGH") h++; else if ($2 == "MEDIUM") m++; else l++
                if (index($10, "reopen") > 0) r++
            } else if ($3 == "resolved") { s++ }
        }
        END { printf "open_high=%d open_medium=%d open_low=%d reopened=%d resolved=%d\n", h+0, m+0, l+0, r+0, s+0 }
    ' "$f" 2>/dev/null
}

# cl_render_prior <ledger> — the open concerns, in the form the reviewer must
# reference next round. Empty output when nothing is open.
cl_render_prior() {
    local f="$1"
    [ -f "$f" ] || return 0
    local body
    body="$(awk -F'|' '
        /^C[0-9]+\|/ && ($3 == "open" || $3 == "reopened") {
            t = $0
            sub(/^([^|]*\|){10}/, "", t)
            printf "- %s [%s] %s\n", $1, $2, t
        }' "$f" 2>/dev/null)"
    [ -n "$body" ] || return 0
    printf '### Prior open concerns (reference these IDs)\n%s\n' "$body"
}

