#!/usr/bin/env bash
# bin/lib/codex-review-loop/boundary-journal.sh — the #2020 threat boundary classifier and the
# append-only concern journal <CTL>/<format>-concern-journal.tsv (15-column j1 rows).
# The handling of each axis A row is read from the `## Threat boundary` table of the criteria SSOT
# (skills/_shared/review-criteria.md) of this tree, never restated here.
# Classify/journal functions need bin/lib/concern-ledger.sh loaded; the round gate and the
# wrapper helpers live in journal-gate.sh (sourced at the end).

_BJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
_BJ_CATS=" correctness security contract performance style docs test maintainability portability concurrency usability other "
_BJ_TABLE_RE='^[|][[:space:]]*(A[0-6])[[:space:]]*[|].*[|][[:space:]]*(in|out|no-path)[[:space:]]*[|][[:space:]]*$'
_BJ_MARKER_AXIS_RE='^\[NOT-CONCERN\][[:space:]]+axis:(A[0-6])/(B[0-3])'
_BJ_NUMBERED_RE='^(C[0-9]+|[0-9]+)\.[[:space:]]+\[(HIGH|MEDIUM|LOW)\][[:space:]]+(.+)$'
_BJ_ANCHORED_RE='^([-*][[:space:]]+)?\[(HIGH|MEDIUM|LOW)\](.*)$'

_bj_load_table() {
    [ "${_BJ_TABLE_LOADED:-0}" = 1 ] && return 0
    declare -gA _BJ_HANDLING=()
    local f line
    for f in "$_BJ_ROOT/skills/_shared/review-criteria.md" "$_BJ_ROOT/skills/_shared/review-criteria/threat-boundary.md"; do
        [ -f "$f" ] || continue
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%$'\r'}"
            [[ "$line" =~ $_BJ_TABLE_RE ]] && _BJ_HANDLING[${BASH_REMATCH[1]}]="${BASH_REMATCH[2]}"
        done < "$f"
    done
    _BJ_TABLE_LOADED=1
}

# bj_kind <category> <axisA> [<nfr-in 0|1>] — concern | out-of-boundary | no-path. Only security
# is bounded; an unknown or untabled axis stays a concern, so a malformed tag never hides a finding.
# nfr-in 1 (an `nfr:in` tag in a round that was sent a PROJECT NFR block) keeps an `out` row a
# concern: the reviewer reconsidered it under the NFR, as the Threat boundary allows.
bj_kind() {
    _bj_load_table
    if [ "$1" != security ]; then printf concern; return 0; fi
    case "${_BJ_HANDLING[$2]:-}" in
        out) if [ "${3:-0}" = 1 ]; then printf concern; else printf out-of-boundary; fi ;;
        no-path) printf no-path ;;
        *) printf concern ;;
    esac
}

_bj_valid_cat() {
    local c="${1,,}"
    case "$_BJ_CATS" in *" $c "*) [ -n "$c" ] && { printf '%s' "$c"; return 0; } ;; esac
    printf other
}

# _bj_tags <text> — sets BJ_A BJ_B BJ_CAT BJ_NFR_IN BJ_BODY from the leading
# 'axis:<A>/<B> cat:<c> [nfr:in]' tags; a missing or out-of-range axis is 'untagged'.
_bj_tags() {
    local t="$1" w a b seen=0
    BJ_A=untagged; BJ_B=untagged; BJ_CAT=""; BJ_NFR_IN=0
    while :; do
        w="${t%%[[:space:]]*}"
        if [ "$seen" -eq 0 ] && [[ "$w" =~ ^axis:([^/]*)/(.*)$ ]]; then
            a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"; seen=1
            [[ "$a" =~ ^A[0-6]$ ]] && BJ_A="$a"
            [[ "$b" =~ ^B[0-3]$ ]] && BJ_B="$b"
        elif [ -z "$BJ_CAT" ] && [[ "$w" =~ ^cat:(.+)$ ]]; then
            BJ_CAT="${BASH_REMATCH[1]}"
        elif [ "$BJ_NFR_IN" -eq 0 ] && [ "$w" = nfr:in ]; then
            BJ_NFR_IN=1
        else
            break
        fi
        t="${t#"$w"}"; t="${t#"${t%%[![:space:]]*}"}"
    done
    BJ_BODY="$t"
}

_bj_marker_fields() {
    local _h _p body
    BJ_A=untagged; BJ_B=untagged; BJ_NFR_IN=0
    [[ "$1" =~ $_BJ_MARKER_AXIS_RE ]] && { BJ_A="${BASH_REMATCH[1]}"; BJ_B="${BASH_REMATCH[2]}"; }
    IFS='|' read -r _h _p body <<< "$1"
    BJ_BODY="$(_cl_trim "${body:-}")"
}

# bj_extract_rows <report> <concern|marker|all> <out> — 'src<TAB>cat<TAB>text' per finding
# (src n numbered, a anchored, m marker; cat '-' means "read it from the text tags").
bj_extract_rows() {
    local mode="$2" out="$3" line t cat text
    : > "$out" || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"; line="${line//$'\t'/ }"
        t="$(_cl_trim "$line")"
        if cl_is_marker_line "$t"; then
            [ "$mode" = concern ] || printf 'm\tsecurity\t%s\n' "$t" >> "$out"
            continue
        fi
        [ "$mode" = marker ] && continue
        if [[ "$t" =~ $_BJ_NUMBERED_RE ]]; then
            printf 'n\t-\t%s\n' "$(_cl_trim "${BASH_REMATCH[3]}")" >> "$out"
        elif [[ "$t" =~ $_BJ_ANCHORED_RE ]]; then
            IFS='|' read -r _ _ cat text <<< "${BASH_REMATCH[3]}"
            text="$(_cl_trim "${text:-}")"; cat="$(_cl_trim "${cat:-}")"
            [ -n "$text" ] && printf 'a\t%s\t%s\n' "${cat:--}" "$text" >> "$out"
        fi
    done < <(_cl_body "$1")
    return 0
}

# bj_classify_rows <extracted> <out> — 'kind<TAB>cat<TAB>A<TAB>B<TAB>body<TAB>text' per row. An
# `nfr:in` tag counts only when the side record (REVIEW_CRITERIA_HASH_OUT) says a PROJECT NFR block
# was delivered.
bj_classify_rows() {
    local src cat text nfr=0
    _bj_load_table
    [ "$(bj_nfr_from "${REVIEW_CRITERIA_HASH_OUT:-}")" = nfr:present ] && nfr=1
    : > "$2" || return 1
    while IFS=$'\t' read -r src cat text; do
        [ -n "$src" ] || continue
        if [ "$src" = m ]; then
            _bj_marker_fields "$text"; cat=security
        else
            _bj_tags "$text"
            [ "$cat" = "-" ] && cat="$BJ_CAT"
            cat="$(_bj_valid_cat "$cat")"
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(bj_kind "$cat" "$BJ_A" $((nfr & BJ_NFR_IN)))" "$cat" "$BJ_A" "$BJ_B" \
            "${BJ_BODY:--}" "$text" >> "$2"
    done < "$1"
}

# bj_journal_lines <classified> <sid> <fmt> <round> <producer> <reviewer> <criteria-hash> <version> <out>
# — the j1 row columns (the SSOT of the row contract): j1 ts sid fmt round producer reviewer kind
# category axisA axisB discrim texthash criteria_hash text boundary_version. Readers take a legacy
# 15-column row as boundary version 'unknown'.
bj_journal_lines() {
    local kind cat a b body text ts th
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    : > "$9" || return 1
    while IFS=$'\t' read -r kind cat a b body text; do
        [ -n "$kind" ] || continue
        th="$(cl_sha256 "$(_cl_norm "$body")")"
        printf 'j1\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$2" "$3" "$4" \
            "$5" "$6" "$kind" "$cat" "$a" "$b" "$(cl_discrim "$text")" "${th:0:16}" "$7" \
            "$(printf '%s' "$text" | _cl_defang_untrusted | tr '\t\r' '  ')" "$8" >> "$9"
    done < "$1"
}

# _bj_journal_lock <lock-dir> — takes the mkdir lock, waiting up to ~10 s for a concurrent writer
# (two producers stage the same round at once); a lock older than a minute is taken as stale.
_bj_journal_lock() {
    local n=0
    while ! mkdir "$1" 2>/dev/null; do
        [ -n "$(find "$1" -maxdepth 0 -mmin +1 2>/dev/null)" ] && rmdir "$1" 2>/dev/null && continue
        n=$((n + 1)); [ "$n" -le 100 ] || return 1
        sleep 0.1
    done
}

# _bj_journal_write <journal> <pending-prefix> <rows> — under the lock, writes journal + parked
# pending files + rows to a temp copy, renames it over the journal and only then removes the
# replayed pending files. Pending files are listed inside the lock, so two writers never replay the
# same one. A failure at any point leaves the journal as it was: no row is half-written or doubled.
_bj_journal_write() {
    local j="$1" lk="$1.lock" tmp pf rc=1
    local -a pend=()
    # A non-file journal would take the temp copy inside it on `mv` and report success.
    if [ -e "$j" ] && [ ! -f "$j" ]; then return 1; fi
    _bj_journal_lock "$lk" || return 1
    for pf in "$2".*.txt; do [ -f "$pf" ] && pend+=("$pf"); done
    tmp="$j.tmp.$$${RANDOM}"
    if { if [ -f "$j" ]; then cat "$j"; fi; cat ${pend[@]+"${pend[@]}"} "$3"; } > "$tmp" 2>/dev/null \
        && mv -f "$tmp" "$j" 2>/dev/null; then
        rc=0
        [ "${#pend[@]}" -eq 0 ] || rm -f "${pend[@]}"
    fi
    rm -f "$tmp" 2>/dev/null
    rmdir "$lk" 2>/dev/null
    return "$rc"
}

# bj_journal_append <ctl> <fmt> <rows> <park 0|1> — replays parked rows first, then appends
# <rows>, all in one atomic write. On failure with park=1 the rows go to
# <fmt>-journal-pending.<nonce>.txt (WARN, rc 1); rc 2 when they could not be parked either.
bj_journal_append() {
    local j="$1/$2-concern-journal.tsv" pf
    if _bj_journal_write "$j" "$1/$2-journal-pending" "$3"; then
        return 0
    fi
    [ "$4" = 1 ] && [ -s "$3" ] || return 1
    pf="$1/$2-journal-pending.$(date +%s)$$${RANDOM}.txt"
    if ( set -C; cat "$3" > "$pf" ) 2>/dev/null; then
        printf 'WARN: concern journal append failed (%s); rows parked in %s for the next append\n' "$j" "$pf" >&2
        return 1
    fi
    rm -f "$pf" 2>/dev/null
    printf 'WARN: concern journal append failed (%s) and the rows could not be parked\n' "$j" >&2
    return 2
}

# bj_journal_report <ctl> <sid> <fmt> <round> <producer> <reviewer> <rows-mode> <report> <hash>
# <version> [<buffer>] — rc 0 when journaled, parked or buffered, 5 when the rows could not be
# built or buffered.
bj_journal_report() {
    local d rc=0
    d="$(mktemp -d)" || return 5
    if bj_extract_rows "$8" "$7" "$d/x" && bj_classify_rows "$d/x" "$d/c" \
        && bj_journal_lines "$d/c" "$2" "$3" "$4" "$5" "$6" "$9" "${10}" "$d/j"; then
        if [ -n "${11:-}" ]; then
            cat "$d/j" >> "${11}" || rc=5
        else
            bj_journal_append "$1" "$3" "$d/j" 1 || true
        fi
    else
        rc=5
    fi
    rm -rf "$d"
    return "$rc"
}

# _bj_appendable <file> — the journal file can be appended to (or created in its directory).
_bj_appendable() {
    if [ -e "$1" ]; then [ -f "$1" ] && [ -w "$1" ]; else [ -w "${1%/*}" ]; fi
}

# _bj_fallback_producer <ledger-fmt> <producer> — the producer is a CC-fallback agent of the
# format (cl_allowed_producers lines 2+).
_bj_fallback_producer() {
    local a n=0
    while IFS= read -r a; do
        n=$((n + 1))
        [ "$n" -gt 1 ] && [ "$a" = "$2" ] && return 0
    done < <(cl_allowed_producers "$1")
    return 1
}

# bj_criteria_hash_from <file> — its first line when it is a hash token, else 'unknown'.
bj_criteria_hash_from() {
    local h=""
    [ -n "${1:-}" ] && [ -s "$1" ] && h="$(head -n 1 "$1" 2>/dev/null | tr -d '\r\n ')"
    if [[ "$h" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then printf '%s' "$h"; else printf unknown; fi
}

# bj_boundary_version_from <file> — its second line when it is a boundary version, else 'unknown'.
bj_boundary_version_from() {
    local v=""
    [ -n "${1:-}" ] && [ -s "$1" ] && v="$(sed -n 2p "$1" 2>/dev/null | tr -d '\r\n')"
    if [[ "$v" =~ ^(v[0-9]+|unknown)$ ]]; then printf '%s' "$v"; else printf unknown; fi
}

# bj_nfr_from <file> — its third line when it is nfr:present or nfr:absent, else 'nfr:absent'
# (an unreadable record never lets an `nfr:in` tag keep a finding).
bj_nfr_from() {
    local n=""
    [ -n "${1:-}" ] && [ -s "$1" ] && n="$(sed -n 3p "$1" 2>/dev/null | tr -d '\r\n')"
    if [ "$n" = nfr:present ]; then printf '%s' "$n"; else printf nfr:absent; fi
}

# bj_stage_filter <norm> <ctl> <sid> <fmt> <round> <producer> — P1 inside `concern-ledger stage`:
# journals the round's new rows (ref '-') and drops security rows outside the boundary from
# <norm>. Inside a stage wrapper (BJ_JOURNAL_BUFFER set) the rows go to the per-call buffer under
# the loop format. Hash and version come from REVIEW_CRITERIA_HASH_OUT. rc 1 (nothing rewritten)
# when the journal cannot be appended.
# Named exception: a stage outside a wrapper has no exit code to gate on, so its rows are appended
# at once and cc-fallback is read from cl_allowed_producers; no such caller exists (pinned in TL2).
bj_stage_filter() {
    local norm="$1" d line rest cat text kind ccat reviewer=codex kept=0 dropped=0
    local fmt="${BJ_LOOP_FORMAT:-$4}" buf="${BJ_JOURNAL_BUFFER:-}" side="${REVIEW_CRITERIA_HASH_OUT:-}" written
    d="$(mktemp -d)" || return 1
    : > "$d/x"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        [ "${line%%|*}" = "-" ] || continue
        rest="${line#*|}"; rest="${rest#*|}"; rest="${rest#*|}"; rest="${rest#*|}"
        cat="${rest%%|*}"; rest="${rest#*|}"; rest="${rest#*|}"; text="${rest#*|}"
        text="${text//$'\t'/ }"
        if [ "$cat" = "-" ]; then printf 'n\t-\t%s\n' "$text"; else printf 'a\t%s\t%s\n' "$cat" "$text"; fi >> "$d/x"
    done < "$norm"
    if [ -n "$buf" ]; then
        [ "$6" = "${BJ_PRESTAGED_PRODUCER:-}" ] && reviewer=cc-fallback
    elif _bj_fallback_producer "$4" "$6"; then
        reviewer=cc-fallback
    fi
    written=1
    if bj_classify_rows "$d/x" "$d/c" \
        && bj_journal_lines "$d/c" "$3" "$fmt" "$5" "$6" "$reviewer" "$(bj_criteria_hash_from "$side")" \
            "$(bj_boundary_version_from "$side")" "$d/j"; then
        if [ -n "$buf" ]; then
            _bj_appendable "$2/$fmt-concern-journal.tsv" && cat "$d/j" >> "$buf" && written=0
        else
            bj_journal_append "$2" "$fmt" "$d/j" 0 && written=0
        fi
    fi
    if [ "$written" -ne 0 ]; then
        printf 'concern-ledger: stage: the concern journal could not be appended under %s; nothing staged\n' "$2" >&2
        rm -rf "$d"; return 1
    fi
    : > "$d/n"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            '') continue ;;
            '#'*) printf '%s\n' "$line" >> "$d/n"; continue ;;
        esac
        if [ "${line%%|*}" = "-" ]; then
            IFS=$'\t' read -r kind ccat _ <&4 || kind=concern
            if [ "$ccat" = security ] && [ "$kind" != concern ]; then dropped=$((dropped + 1)); continue; fi
        fi
        printf '%s\n' "$line" >> "$d/n"; kept=$((kept + 1))
    done < "$norm" 4< "$d/c"
    cat "$d/n" > "$norm" || { rm -rf "$d"; return 1; }
    rm -rf "$d"
    if [ "$kept" -eq 0 ] && [ "$dropped" -gt 0 ]; then
        printf 'concern-ledger: stage: every new finding of round %s is a security finding outside the Threat boundary (skills/_shared/review-criteria.md); %s journaled, none staged\n' "$5" "$dropped" >&2
    fi
    return 0
}

# shellcheck source=bin/lib/codex-review-loop/journal-gate.sh
. "$_BJ_ROOT/bin/lib/codex-review-loop/journal-gate.sh"
