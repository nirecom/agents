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
# This is the single generation point for prior text, so the defanging lives
# here rather than in each consumer (#2025 C3/C7). Filtering after formatting
# rather than before keeps the sed rules in one place: doing it inside the awk
# field split would either fork per record or duplicate the patterns.
# The husk filter runs last and never deletes a line, so the emptiness test
# below still means "nothing is open" and nothing else.
cl_render_prior() {
    local f="$1"
    [ -f "$f" ] || return 0
    local body rc
    # pipefail scoped to this subshell: an emptied $body is otherwise
    # indistinguishable from "nothing is open" (fail-open), and a broken
    # defang/placehold stage would silently drop every prior ID from the
    # next round's reviewer prompt (#2025 C13).
    body="$(set -o pipefail; awk -F'|' '
        /^C[0-9]+\|/ && ($3 == "open" || $3 == "reopened") {
            t = $0
            sub(/^([^|]*\|){10}/, "", t)
            printf "- %s [%s] %s\n", $1, $2, t
        }' "$f" 2>/dev/null | _cl_defang_untrusted | _cl_placehold_empty_concerns)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'concern-ledger: cl_render_prior: rendering pipeline failed (rc=%d) for %s\n' "$rc" "$f" >&2
        return 2
    fi
    [ -n "$body" ] || return 0
    printf '### Prior open concerns (reference these IDs)\n%s\n' "$body"
}


:  # load-success rc for the entrypoint's source check
