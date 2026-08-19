#!/usr/bin/env bash
# bin/lib/concern-ledger/parse.sh — parse adapters and delta staging; sourced by bin/lib/concern-ledger.sh (not executed directly).

# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------
# cl_read_v1_or_v2 <file> [<round>] — emit 11-field v2 rows for both schemas.
# v1 rows (ID|SEVERITY|TEXT) are promoted conservatively: open, first seen at
# round 1, last confirmed at the previous round, no anchor.
cl_read_v1_or_v2() {
    local f="$1" round="${2:-1}" line prev
    local seps rest sev
    [ -f "$f" ] || return 0
    prev=$((round - 1)); [ "$prev" -lt 1 ] && prev=1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        case "$line" in C[0-9]*'|'*) ;; *) continue ;; esac
        seps="${line//[^|]/}"
        if [ "${#seps}" -ge 10 ]; then
            printf '%s\n' "$line"
            continue
        fi
        # v1 row: ID|SEVERITY|TEXT. Promote conservatively.
        rest="${line#*|}"; sev="${rest%%|*}"; rest="${rest#*|}"
        printf '%s|%s|open|1|%s|%s|%s|unknown|unknown|no-anchor|%s\n' \
            "${line%%|*}" "$sev" "$prev" "$(cl_slot_body "$rest")" "$(cl_discrim "$rest")" "$rest"
    done < "$f"
}

# _cl_load_ledger <file> <round> — CL_IDS + CL_E_* from a v1 or v2 ledger.
_cl_load_ledger() {
    local f="$1" round="${2:-1}" line id
    CL_IDS=()
    unset CL_E_SEV CL_E_STATE CL_E_FIRST CL_E_LAST CL_E_SLOT CL_E_DISCRIM
    unset CL_E_ORIGIN CL_E_PROD CL_E_FLAGS CL_E_TEXT
    declare -gA CL_E_SEV=() CL_E_STATE=() CL_E_FIRST=() CL_E_LAST=() CL_E_SLOT=()
    declare -gA CL_E_DISCRIM=() CL_E_ORIGIN=() CL_E_PROD=() CL_E_FLAGS=() CL_E_TEXT=()
    CL_HDR_FORMAT=""; CL_HDR_SID=""; CL_HDR_CYCLE=1
    [ -f "$f" ] || return 0
    local first
    first="$(head -n1 "$f" 2>/dev/null || true)"
    case "$first" in
        '#concern-ledger-v2|'*)
            CL_HDR_FORMAT="$(printf '%s' "$first" | cut -d'|' -f2)"
            CL_HDR_SID="$(printf '%s' "$first" | cut -d'|' -f3)"
            CL_HDR_CYCLE="$(printf '%s' "$first" | cut -d'|' -f4)"
            CL_HDR_CYCLE="${CL_HDR_CYCLE#cycle=}"
            ;;
    esac
    [ -n "${CL_HDR_CYCLE//[0-9]/}" ] && CL_HDR_CYCLE=1
    [ -z "$CL_HDR_CYCLE" ] && CL_HDR_CYCLE=1
    local c2 c3 c4 c5 c6 c7 c8 c9 c10 c11
    while IFS='|' read -r id c2 c3 c4 c5 c6 c7 c8 c9 c10 c11 || [ -n "$id" ]; do
        [ -n "$id" ] || continue
        CL_IDS+=("$id")
        CL_E_SEV[$id]="$c2";   CL_E_STATE[$id]="$c3"; CL_E_FIRST[$id]="$c4"
        CL_E_LAST[$id]="$c5";  CL_E_SLOT[$id]="$c6";  CL_E_DISCRIM[$id]="$c7"
        CL_E_ORIGIN[$id]="$c8"; CL_E_PROD[$id]="$c9"; CL_E_FLAGS[$id]="$c10"
        CL_E_TEXT[$id]="$c11"
    done < <(cl_read_v1_or_v2 "$f" "$round")
}

# _cl_load_delta <file> — CL_D_* arrays from a normalized delta file.
_cl_load_delta() {
    local f="$1" line
    CL_D_REF=(); CL_D_SEV=(); CL_D_SLOT=(); CL_D_DISCRIM=(); CL_D_CAT=()
    CL_D_PROD=(); CL_D_ANCHOR=(); CL_D_TEXT=()
    local r s sl di ca pr an tx
    [ -f "$f" ] || return 0
    while IFS='|' read -r r s sl di ca pr an tx || [ -n "$r" ]; do
        case "$r" in ''|'#'*) continue ;; esac
        CL_D_REF+=("$r");  CL_D_SEV+=("$s");     CL_D_SLOT+=("$sl")
        CL_D_DISCRIM+=("$di"); CL_D_CAT+=("$ca"); CL_D_PROD+=("$pr")
        CL_D_ANCHOR+=("$an"); CL_D_TEXT+=("$tx")
    done < "$f"
}

# ---------------------------------------------------------------------------
# Parse adapters
# ---------------------------------------------------------------------------
_cl_body() {
    if grep -q -- '<!-- begin-codex-output' "$1" 2>/dev/null; then
        sed -n '/<!-- begin-codex-output/,/<!-- end-codex-output/p' "$1" \
            | sed -e '1d' -e '/<!-- end-codex-output/d'
    else
        cat "$1" 2>/dev/null || true
    fi
}

_cl_delta_section() {
    awk '
        /^##[[:space:]]+Concern Delta[[:space:]]*$/ { inb = 1; found = 1; next }
        inb && /^##[[:space:]]/ { inb = 0 }
        inb { print }
        END { exit !found }
    '
}

# _cl_emit_anchored <line> <producer> <out> — 0 when the line is well formed.
_cl_emit_anchored() {
    local line="$1" prod="$2" out="$3"
    local rest sev ref pa cat text path anchor
    rest="$(_cl_trim "$line")"
    case "$rest" in '- '*|'* '*|'-'[[:space:]]*|'*'[[:space:]]*) rest="$(_cl_trim "${rest#?}")" ;; esac
    case "$rest" in
        '[HIGH]'*)   sev=HIGH ;;
        '[MEDIUM]'*) sev=MEDIUM ;;
        '[LOW]'*)    sev=LOW ;;
        *) return 1 ;;
    esac
    rest="${rest#\[$sev\]}"
    IFS='|' read -r ref pa cat text <<< "$rest"
    ref="$(_cl_trim "${ref:-}")"; pa="$(_cl_trim "${pa:-}")"
    cat="$(_cl_trim "${cat:-}")"; text="$(_cl_trim "${text:-}")"
    [ -n "$text" ] || return 1
    [ -n "$cat" ] || return 1
    case "$pa" in *'#'*) ;; *) return 1 ;; esac
    case "$ref" in -|C[0-9]*) ;; *) return 1 ;; esac
    path="${pa%%#*}"; anchor="${pa#*#}"
    printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$ref" "$sev" \
        "$(cl_slot "$path" "$anchor" "$cat")" "$(cl_discrim "$text")" \
        "$cat" "$prod" "$path#$anchor" "$text" >> "$out"
}

# cl_parse_anchored <raw-report> <producer> <out> — prints the parse label.
cl_parse_anchored() {
    local raw="$1" prod="$2" out="$3"
    : > "$out"
    local body sect line t have_sect=0 nonblank=0 none=0 bad=0
    local -a cand=()
    body="$(_cl_body "$raw")"
    if sect="$(printf '%s\n' "$body" | _cl_delta_section)"; then have_sect=1; fi
    if [ "$have_sect" -eq 1 ]; then
        while IFS= read -r line; do
            t="$(_cl_trim "$line")"
            [ -z "$t" ] && continue
            nonblank=$((nonblank + 1))
            if [ "$t" = "(none)" ]; then none=1; continue; fi
            cand+=("$line")
        done <<< "$sect"
        if [ "$nonblank" -eq 0 ]; then printf 'PARTIAL\n'; return 0; fi
        if [ "${#cand[@]}" -eq 0 ] && [ "$none" -eq 1 ]; then printf 'COMPLETE\n'; return 0; fi
    else
        while IFS= read -r line; do
            t="$(_cl_trim "$line")"
            [ "$t" = "(none)" ] && none=1
            if [[ "$line" =~ ^[[:space:]]*([-*][[:space:]]+)?\[(HIGH|MEDIUM|LOW)\] ]]; then
                cand+=("$line")
            fi
        done <<< "$body"
        if [ "${#cand[@]}" -eq 0 ]; then
            if [ "$none" -eq 1 ]; then printf 'COMPLETE\n'; else printf 'ABSENT\n'; fi
            return 0
        fi
    fi
    for line in "${cand[@]}"; do
        if ! _cl_emit_anchored "$line" "$prod" "$out"; then
            printf '#unparsed|%s\n' "$line" >> "$out"
            bad=1
        fi
    done
    if [ "$bad" -eq 1 ]; then printf 'PARTIAL\n'; else printf 'COMPLETE\n'; fi
}

# cl_parse_numbered <raw-report> <out> — round-1 'N. [SEV] text' reviewer form.
cl_parse_numbered() {
    local raw="$1" out="$2" line sev text
    : > "$out"
    while IFS= read -r line; do
        if printf '%s' "$line" | grep -Eq '^(C[0-9]+|[0-9]+)\.[[:space:]]+\[(HIGH|MEDIUM|LOW)\][[:space:]]+.+'; then
            sev="$(printf '%s' "$line" | sed -E 's/^[^[]*\[(HIGH|MEDIUM|LOW)\].*$/\1/')"
            text="$(_cl_trim "$(printf '%s' "$line" | sed -E 's/^(C[0-9]+|[0-9]+)\.[[:space:]]+\[(HIGH|MEDIUM|LOW)\][[:space:]]+//')")"
            printf -- '-|%s|%s|%s|-|%s|-|%s\n' "$sev" "$(cl_slot_body "$text")" \
                "$(cl_discrim "$text")" "${CL_PRODUCER:-codex}" "$text" >> "$out"
        fi
    done < <(_cl_body "$raw")
    printf 'COMPLETE\n'
}

# cl_parse_cnref <raw-report> <ledger> <out> — round-2+ 'C<N>: ...' reviewer form.
# The reviewer's restatement never overwrites the stored TEXT: the entry it names
# is the authority, so a softened rewording cannot silently redefine the concern.
cl_parse_cnref() {
    local raw="$1" ledger="$2" out="$3" line id rest
    : > "$out"
    _cl_load_ledger "$ledger" 1
    while IFS= read -r line; do
        if printf '%s' "$line" | grep -Eq '^[[:space:]]*C[0-9]+:'; then
            id="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*(C[0-9]+):.*$/\1/')"
            rest="$(_cl_trim "$(printf '%s' "$line" | sed -E 's/^[[:space:]]*C[0-9]+:[[:space:]]*//')")"
            if [ -n "${CL_E_TEXT[$id]+x}" ]; then
                printf '%s|%s|%s|%s|-|%s|-|%s\n' "$id" "${CL_E_SEV[$id]}" \
                    "${CL_E_SLOT[$id]}" "${CL_E_DISCRIM[$id]}" "${CL_PRODUCER:-codex}" \
                    "${CL_E_TEXT[$id]}" >> "$out"
            else
                printf '%s|MEDIUM|%s|%s|-|%s|-|%s\n' "$id" "$(cl_slot_body "$rest")" \
                    "$(cl_discrim "$rest")" "${CL_PRODUCER:-codex}" "$rest" >> "$out"
            fi
        else
            case "$(_cl_trim "$line")" in
                ''|'<!--'*) ;;
                *) printf 'concern-ledger: ignored non-reference reviewer line: %s\n' "$line" >&2 ;;
            esac
        fi
    done < <(_cl_body "$raw")
    printf 'COMPLETE\n'
}

# ---------------------------------------------------------------------------
# Staging
# ---------------------------------------------------------------------------
# cl_stage <dir> <format> <round> <producer> <exec-label> <parse-label> <norm>
cl_stage() {
    local dir="$1" fmt="$2" round="$3" prod="$4" exec="$5" parse="$6" norm="$7"
    local dest comp line ex
    mkdir -p "$dir" 2>/dev/null || return 1
    ex="$(cl_exec_completeness "$exec")"
    comp="$(_cl_label_min "$ex" "$parse")"
    dest="$dir/${CL_STAGE_PREFIX:-}${fmt}-round-${round}-delta-${prod}.txt"
    if [ -e "$dest" ] && [ ! -f "$dest" ]; then
        printf 'concern-ledger: stage destination is not a plain file: %s\n' "$dest" >&2
        return 1
    fi
    local tmp rc
    tmp="$dest.tmp.$$"
    rc=0
    {
        printf '#producer|%s|%s|%s|%s|%s\n' "$prod" "$comp" "$ex" "$parse" "$round"
        if [ -f "$norm" ]; then
            local r s sl di ca an tx rest
            while IFS= read -r line || [ -n "$line" ]; do
                case "$line" in
                    '') continue ;;
                    '#'*) printf '%s\n' "$line"; continue ;;
                esac
                r="${line%%|*}";  rest="${line#*|}"
                s="${rest%%|*}";  rest="${rest#*|}"
                sl="${rest%%|*}"; rest="${rest#*|}"
                di="${rest%%|*}"; rest="${rest#*|}"
                ca="${rest%%|*}"; rest="${rest#*|}"
                rest="${rest#*|}"
                an="${rest%%|*}"; tx="${rest#*|}"
                printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$r" "$s" "$sl" "$di" "$ca" "$prod" "$an" "$tx"
            done < "$norm"
        fi
    } > "$tmp" || rc=$?
    if [ "$rc" -ne 0 ] || [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        printf 'concern-ledger: stage could not write the delta: %s\n' "$dest" >&2
        return 1
    fi
    if ! mv -f "$tmp" "$dest"; then
        rm -f "$tmp"
        printf 'concern-ledger: stage could not publish the delta: %s\n' "$dest" >&2
        return 1
    fi
    printf '%s\n' "$dest"
}

