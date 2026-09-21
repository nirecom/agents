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
            else if ($3 == "rejected") { rj++ }
        }
        END { printf "open_high=%d open_medium=%d open_low=%d reopened=%d resolved=%d rejected=%d\n", h+0, m+0, l+0, r+0, s+0, rj+0 }
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

# cl_render_concerns_log <ledger> — the open+reopened concerns keyed by DISCRIM,
# in the bullet form the carrier stores and CTX_CONCERNS_LOG hands to a producer.
# `- <DISCRIM> [SEV] <text>`, defanged (resolved/rejected are NOT emitted here:
# resolved is derived fresh each round, rejected is preserved by the carrier via
# _cl_merge_concerns_log). Empty output when nothing is open; shares cl_render_
# prior's defang/placehold pipeline and pipefail handling (CPR-SSOT, #2025 C13).
cl_render_concerns_log() {
    local f="$1"
    [ -f "$f" ] || return 0
    local body rc
    body="$(set -o pipefail; awk -F'|' '
        /^C[0-9]+\|/ && ($3 == "open" || $3 == "reopened") {
            t = $0
            sub(/^([^|]*\|){10}/, "", t)
            printf "- %s [%s] %s\n", $7, $2, t
        }' "$f" 2>/dev/null | _cl_defang_untrusted | _cl_placehold_empty_concerns)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'concern-ledger: cl_render_concerns_log: rendering pipeline failed (rc=%d) for %s\n' "$rc" "$f" >&2
        return 2
    fi
    printf '%s' "$body"
}

# _cl_merge_concerns_log <carrier-path> <new-lines-file> — write the carrier as
# the union of this round's open lines (from <new-lines-file>, freshly derived by
# cl_render_concerns_log) and the rejected lines the existing carrier already
# holds. Carrier-only NON-rejected lines are dropped, so a stale open line can
# never outlive the ledger state that produced it (#2185 C2, no tombstones). The
# key is the bullet's 2nd token (DISCRIM); a line whose 4th token is REJECTED is
# a rejected line. On a DISCRIM collision rejected wins. Output is DISCRIM byte-
# sorted and atomic (sp_publish_stdin). An empty merge empties the carrier so the
# caller's `-s` test reports "nothing to carry".
_cl_merge_concerns_log() {
    local carrier="$1" newf="$2"
    local -A line_for=() is_rej=()
    local -a order=()
    local ln key tok4
    # Existing carrier: keep only its rejected lines (preserved durable record).
    if [ -f "$carrier" ]; then
        while IFS= read -r ln || [ -n "$ln" ]; do
            case "$ln" in '- '*) ;; *) continue ;; esac
            read -r key _ tok4 _ <<< "${ln#- }"
            [ -n "$key" ] || continue
            [ "$tok4" = "REJECTED" ] || continue
            [ -n "${line_for[$key]:-}" ] || order+=("$key")
            line_for[$key]="$ln"; is_rej[$key]=1
        done < "$carrier"
    fi
    # This round's open lines: added unless a rejected line already claimed the
    # DISCRIM (rejected wins).
    if [ -f "$newf" ]; then
        while IFS= read -r ln || [ -n "$ln" ]; do
            case "$ln" in '- '*) ;; *) continue ;; esac
            read -r key _ <<< "${ln#- }"
            [ -n "$key" ] || continue
            [ "${is_rej[$key]:-0}" = "1" ] && continue
            [ -n "${line_for[$key]:-}" ] || order+=("$key")
            line_for[$key]="$ln"
        done < "$newf"
    fi
    if [ "${#order[@]}" -eq 0 ]; then
        : | sp_publish_stdin "$carrier" || return 1
        return 0
    fi
    {
        printf '### Prior concerns (open + rejected — reference these; do NOT re-raise rejected ones)\n'
        for key in $(printf '%s\n' "${order[@]}" | LC_ALL=C sort); do
            printf '%s\n' "${line_for[$key]}"
        done
    } | sp_publish_stdin "$carrier" || return 1
    return 0
}


:  # load-success rc for the entrypoint's source check
