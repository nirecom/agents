#!/usr/bin/env bash
# bin/lib/concern-ledger/upstream-tag.sh — the single owner of the [upstream-inconsistency …]
# concern tag (#2814). A tagged concern is never rejected; the user decides it, and only a
# recorded C (cycle + id + exact body hash) lets cl_accept close it. Tag format, causes and the
# format table: skills/_shared/priority-hierarchy/core.md (read here, never copied).
# Sourced by bin/lib/concern-ledger.sh; no `set -e` (a sourced library).

CL_UPSTREAM_TAG_PREFIX='[upstream-inconsistency '
CL_UPSTREAM_ACCEPT_LABEL='accepted(upstream-inconsistency)'
CL_UPSTREAM_HDR_RE='\[upstream-inconsistency cause=([^] ]*) recommend=([^] ]*) source=([^] ]*)\]'
CL_UPSTREAM_CHECKOUT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null && pwd)"
CL_UPSTREAM_CORE_MD="$CL_UPSTREAM_CHECKOUT/skills/_shared/priority-hierarchy/core.md"
# Control characters built at runtime: MSYS bash drops a $'\r' literal read from a sourced file.
printf -v CL_UPSTREAM_TAB '\t'
printf -v CL_UPSTREAM_CR '\r'
printf -v CL_UPSTREAM_LF '\n'

# Minimum defect length (trimmed characters) for B to survive; a shorter defect shows nothing concrete.
CL_UPSTREAM_DEFECT_MIN=12

# _cl_upstream_head <text> — the text minus an optional leading `[SEV] ` and one leading
# `$CL_DRIFT_TAG_PREFIX…] ` tag (core.md and combined-glossary.md both place their tag right after
# [SEV], so either may come first).
_cl_upstream_head() {
    local s="$1"
    if [[ "$s" =~ ^\[[A-Z]+\]\  ]]; then s="${s#"${BASH_REMATCH[0]}"}"; fi
    case "$s" in "$CL_DRIFT_TAG_PREFIX"*"]"*) s="${s#*]}"; s="${s# }" ;; esac
    printf '%s' "$s"
}

# cl_is_upstream_tagged <text> — the one tag predicate (list, reject, accept, parse): rc 0 when the
# text after [SEV] opens with the tag, alone or after one drift tag; a later tag does not count.
cl_is_upstream_tagged() {
    case "$(_cl_upstream_head "$1")" in "$CL_UPSTREAM_TAG_PREFIX"*) return 0 ;; esac
    return 1
}

# cl_upstream_header <text> — set CLU_CAUSE, CLU_REC, CLU_SRC from the leading tag;
# rc 1 (all empty) when the text does not open with a well-formed tag header.
cl_upstream_header() {
    CLU_CAUSE=""; CLU_REC=""; CLU_SRC=""
    [[ "$(_cl_upstream_head "$1")" =~ ^$CL_UPSTREAM_HDR_RE ]] || return 1
    CLU_CAUSE="${BASH_REMATCH[1]}"; CLU_REC="${BASH_REMATCH[2]}"; CLU_SRC="${BASH_REMATCH[3]}"
    return 0
}

# cl_upstream_text_hash <line> — sha256 of the body: the line minus its `C<N>. ` / `<N>. `
# prefix and trailing whitespace (CR/LF included). Inner whitespace is kept as is.
cl_upstream_text_hash() {
    local b="$1"
    b="${b%"${b##*[![:space:]]}"}"
    if [[ "$b" =~ ^C?[0-9]+\.\  ]]; then b="${b#"${BASH_REMATCH[0]}"}"; fi
    cl_sha256 "$b"
}

# cl_upstream_tsv_field <text> — one TSV-safe field: \ -> \\, tab -> \t, CR -> \r, LF -> \n.
cl_upstream_tsv_field() {
    # shellcheck disable=SC1003  # a literal backslash, not an escaped quote
    local s="$1" bs='\'
    s="${s//"$bs"/"$bs$bs"}"
    s="${s//"$CL_UPSTREAM_TAB"/"${bs}t"}"
    s="${s//"$CL_UPSTREAM_CR"/"${bs}r"}"
    s="${s//"$CL_UPSTREAM_LF"/"${bs}n"}"
    printf '%s' "$s"
}

# cl_upstream_reject_control <value> — rc 2 when the value holds a tab, CR or LF.
cl_upstream_reject_control() {
    case "$1" in *"$CL_UPSTREAM_TAB"*|*"$CL_UPSTREAM_CR"*|*"$CL_UPSTREAM_LF"*) return 2 ;; esac
    return 0
}

# _cl_upstream_parse <text> — set CLU_SECTION … CLU_QUOTE2 from the tag's fields. rc 1 (all
# empty) unless every field delimiter occurs exactly once (quote2 at most once), in fixed order.
_cl_upstream_parse() {
    CLU_SECTION=""; CLU_QUOTE=""; CLU_DOWNSTREAM=""; CLU_DEFECT=""; CLU_REASON=""; CLU_QUOTE2=""
    local s="$1" d t pre last=-1 n rest
    cl_is_upstream_tagged "$s" || return 1
    s="$(_cl_upstream_head "$s")"; s="${s#"$CL_UPSTREAM_TAG_PREFIX"}"
    case "$s" in *"]"*) ;; *) return 1 ;; esac
    s="${s#*]}"; s="${s# }"
    case "$s" in "$CL_DRIFT_TAG_PREFIX"*"]"*) s="${s#*]}"; s="${s# }" ;; esac
    s="${s%"${s##*[![:space:]]}"}"
    case "$s" in "section: "*) ;; *) return 1 ;; esac
    for d in " ; section: " " ; quote: " " ; downstream: " " ; defect: " " ; reason: " " ; quote2: "; do
        t="${s//"$d"/}"; n=$(( (${#s} - ${#t}) / ${#d} ))
        case "$d:$n" in " ; section: :0"|" ; quote2: :0") continue ;; " ; section: :"*) return 1 ;; *:1) ;; *) return 1 ;; esac
        pre="${s%%"$d"*}"
        [ "${#pre}" -gt "$last" ] || return 1
        last="${#pre}"
    done
    rest="${s#section: }"
    CLU_SECTION="${rest%%" ; quote: "*}"; rest="${rest#*" ; quote: "}"
    CLU_QUOTE="${rest%%" ; downstream: "*}"; rest="${rest#*" ; downstream: "}"
    CLU_DOWNSTREAM="${rest%%" ; defect: "*}"; rest="${rest#*" ; defect: "}"
    CLU_DEFECT="${rest%%" ; reason: "*}"; rest="${rest#*" ; reason: "}"
    CLU_REASON="${rest%%" ; quote2: "*}"
    case "$rest" in *" ; quote2: "*) CLU_QUOTE2="${rest#*" ; quote2: "}" ;; esac
    CLU_QUOTE="${CLU_QUOTE#«}"; CLU_QUOTE="${CLU_QUOTE%»}"
    CLU_DOWNSTREAM="${CLU_DOWNSTREAM#«}"; CLU_DOWNSTREAM="${CLU_DOWNSTREAM%»}"
    CLU_QUOTE2="${CLU_QUOTE2#«}"; CLU_QUOTE2="${CLU_QUOTE2%»}"
    return 0
}

# cl_upstream_field <text> <name> — one field's value («» stripped); empty when unreadable.
cl_upstream_field() {
    _cl_upstream_parse "$1" || return 0
    case "$2" in
        section) printf '%s' "$CLU_SECTION" ;; quote) printf '%s' "$CLU_QUOTE" ;;
        downstream) printf '%s' "$CLU_DOWNSTREAM" ;; defect) printf '%s' "$CLU_DEFECT" ;;
        reason) printf '%s' "$CLU_REASON" ;; quote2) printf '%s' "$CLU_QUOTE2" ;;
    esac
    return 0
}

# cl_upstream_cycle <ctl> <fmt> — the review cycle (file absent = 1); rc 1 when unreadable.
cl_upstream_cycle() {
    local f="$1/$2-review-cycle.txt" c
    [ -e "$f" ] || { printf '1'; return 0; }
    c="$(tr -d '\r\n ' < "$f" 2>/dev/null)" || return 1
    case "$c" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s' "$c"
}

# cl_upstream_prior_choice <ctl> <fmt> <cycle> <id> <hash> — "C" when the latest decision for
# exactly this (cycle, id, hash) is C; nothing otherwise.
cl_upstream_prior_choice() {
    local f="$1/$2-upstream-decisions.tsv"
    [ -f "$f" ] || return 0
    awk -F'\t' -v c="$3" -v i="$4" -v h="$5" '{sub(/\r$/,"")} $1==c && $2==i && $3==h {ch=$4}
        END{if (ch=="C") print "C"}' "$f"
}

# cl_upstream_is_listed <ctl> <fmt> <cycle> <id> <hash> — rc 0 when the pair is in the cycle's
# highest round of upstream-seen.tsv, which holds only the latest list (each list replaces the
# cycle's rows at its round and later); rc 2 otherwise (a missing file lists nothing).
cl_upstream_is_listed() {
    local f="$1/$2-upstream-seen.tsv"
    [ -f "$f" ] || return 2
    awk -F'\t' -v c="$3" -v i="$4" -v h="$5" '{sub(/\r$/,"")} $1==c {r[NR]=$2+0; id[NR]=$3; hs[NR]=$4; if ($2+0>m) m=$2+0}
        END{for (k in r) if (r[k]==m && id[k]==i && hs[k]==h) exit 0; exit 2}' "$f"
}

# cl_upstream_format_row <fmt> — "reviewed|roles|returns" from the core.md format table.
cl_upstream_format_row() {
    local line c
    local -a cells
    while IFS= read -r line; do
        line="${line%$'\r'}"
        case "$line" in "|"*) ;; *) continue ;; esac
        IFS='|' read -r -a cells <<< "$line"
        c="${cells[1]//[ \`]/}"
        [ "$c" = "$1" ] || continue
        printf '%s|%s|%s' "$(_cl_upstream_trim "${cells[2]}")" "$(_cl_upstream_trim "${cells[4]}")" "$(_cl_upstream_trim "${cells[5]}")"
        return 0
    done < "$CL_UPSTREAM_CORE_MD"
    return 1
}
_cl_upstream_trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# cl_upstream_return_step <fmt> <source> — the B return step for a source, or nothing.
cl_upstream_return_step() {
    local row ret part
    row="$(cl_upstream_format_row "$1")" || return 1
    ret="${row##*|}"
    while [ -n "$ret" ]; do
        part="${ret%%" / "*}"
        [ "$(_cl_upstream_trim "${part%%→*}")" = "$2" ] && { _cl_upstream_trim "${part#*→}"; return 0; }
        [ "$part" = "$ret" ] && break
        ret="${ret#*" / "}"
    done
    return 1
}

# _cl_upstream_unit_in <file> <quote> — rc 0 when the quote is one whole line (list marker
# stripped) or one sentence of a line, whitespace runs and a final period aside.
_cl_upstream_unit_in() {
    [ -f "$1" ] && [ -n "$2" ] || return 1
    CLU_Q="$2" awk 'function norm(s) {gsub(/[[:space:]]+/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s); sub(/\.$/, "", s); return s}
        BEGIN {q = norm(ENVIRON["CLU_Q"]); if (q == "") exit}
        {sub(/\r$/, ""); l = $0; sub(/^[[:space:]]*/, "", l)
         if (match(l, /^(#+|[-*+]|[0-9]+[.)])[[:space:]]+/)) l = substr(l, RLENGTH + 1)
         l = norm(l); if (l == q) {f = 1; exit}
         n = split(l, p, /\. /); if (n > 1) for (i = 1; i <= n; i++) if (norm(p[i]) == q) {f = 1; exit}}
        END {exit f ? 0 : 1}' "$1"
}

# _cl_upstream_source_file <source> <sid> <ctx-files…> — the upstream artifact for a source:
# the plan step's file, or for test-design a --context-file whose basename says so.
_cl_upstream_source_file() {
    local src="$1" sid="$2" p; shift 2
    if [ "$src" = test-design ]; then
        for p in "$@"; do case "${p##*/}" in *test-design*) printf '%s' "$p"; return 0 ;; esac; done
        return 1
    fi
    p="$(node "$CL_UPSTREAM_CHECKOUT/bin/plan-artifact-path" --stage "$src" --session "$sid" 2>/dev/null)" || return 1
    [ -n "$p" ] || return 1
    printf '%s' "${p//\\//}"
}

# cl_upstream_effective_recommend <fmt> <text> <sid> [ctx-files…] — "<eff>\t<return step>\t<why>".
# A is the default; B survives only with a verbatim whole-unit quote and a real defect.
cl_upstream_effective_recommend() {
    local fmt="$1" text="$2" sid="$3" ret=""; shift 3
    cl_upstream_header "$text" || true
    ret="$(cl_upstream_return_step "$fmt" "$CLU_SRC" 2>/dev/null)"
    _cl_upstream_reco "$fmt" "$text" "$sid" "$CLU_CAUSE" "$CLU_REC" "$CLU_SRC" "$@"
    printf '%s\t%s\t%s' "$CLU_EFF" "$ret" "$CLU_WHY"
}
# _cl_upstream_defect_why <defect> <quote> — why the defect shows no concrete upstream contradiction
# or omission (empty, a placeholder, too short, or the quote again); nothing when it does.
_cl_upstream_defect_why() {
    local d k
    d="$(_cl_upstream_trim "$1")"
    [ -n "$d" ] || { printf 'the defect is empty'; return 0; }
    k="${d,,}"; k="${k//[[:space:][:punct:]]/}"; k="${k//…/}"; k="${k//—/}"
    case "$k" in
        ''|tbd|tba|todo|fixme|xxx|na|none|nil|null|unknown|unspecified|placeholder|same|seeabove|etc)
            printf 'the defect is a placeholder, not a concrete upstream contradiction or omission'; return 0 ;;
    esac
    [ "${#d}" -ge "$CL_UPSTREAM_DEFECT_MIN" ] || { printf 'the defect is shorter than %s characters' "$CL_UPSTREAM_DEFECT_MIN"; return 0; }
    [ "$d" != "$(_cl_upstream_trim "$2")" ] || printf 'the defect only repeats the quote'
    return 0
}
_cl_upstream_reco() {
    local fmt="$1" text="$2" sid="$3" cause="$4" rec="$5" src="$6" row roles file; shift 6
    CLU_EFF=A; CLU_WHY=""
    _cl_upstream_parse "$text" || { CLU_WHY="the tag fields are unreadable (a delimiter is missing, doubled or out of order)"; return; }
    case "$cause" in
        wording-only) CLU_EFF=C; [ "$rec" = C ] || CLU_WHY="cause=wording-only recommends C"; return ;;
        deviation-add|deviation-relax|deviation-remove|deviation-reinterpret)
            [ "$rec" = A ] || CLU_WHY="a downstream deviation is revised downstream (A)"; return ;;
        upstream-gap|upstream-conflict) ;;
        *) CLU_WHY="unknown cause: $cause"; return ;;
    esac
    case "$rec" in
        A) return ;;
        C) CLU_WHY="C applies only to cause=wording-only"; return ;;
        B) ;;
        *) CLU_WHY="unknown recommend: $rec"; return ;;
    esac
    row="$(cl_upstream_format_row "$fmt")" || { CLU_WHY="unknown format: $fmt"; return; }
    roles="${row#*|}"; roles="${roles%%|*}"
    case ", $roles, " in *", $src, "*) ;; *) CLU_WHY="source=$src is not an upstream of $fmt"; return ;; esac
    file="$(_cl_upstream_source_file "$src" "$sid" "$@")" || { CLU_WHY="the $src artifact is not available"; return; }
    _cl_upstream_unit_in "$file" "$CLU_QUOTE" || { CLU_WHY="the quote is not a whole line or sentence of the $src artifact"; return; }
    CLU_WHY="$(_cl_upstream_defect_why "$CLU_DEFECT" "$CLU_QUOTE")"
    [ -z "$CLU_WHY" ] || return
    if [ "$cause" = upstream-conflict ]; then
        _cl_upstream_unit_in "$file" "$CLU_QUOTE2" || { CLU_WHY="upstream-conflict needs a whole-unit quote2 of the $src artifact"; return; }
    fi
    CLU_EFF=B
}

# cl_upstream_guard_reject <ledger> <id> — 4 when the target concern carries the tag, else 0.
cl_upstream_guard_reject() {
    local row rest
    row="$(_cl_drift_row "$1" "$2")" || return 0
    IFS='|' read -r _ _ _ _ _ _ _ _ _ _ rest <<< "$row"
    cl_is_upstream_tagged "$rest" && return 4
    return 0
}

# cl_upstream_accept <ledger> <id> <reason> — close a tagged concern when decisions.tsv beside
# the ledger holds a C for (current cycle, id, hash of the ledger body). 4 refused; 1 write failure.
cl_upstream_accept() {
    local ledger="$1" id="$2" reason="$3" row sev rest ctl fmt cyc h
    row="$(_cl_drift_row "$ledger" "$id")" || return 4
    IFS='|' read -r _ sev _ _ _ _ _ _ _ _ rest <<< "$row"
    ctl="$(dirname "$ledger")"; fmt="$(basename "$ledger")"; fmt="${fmt%-concern-ledger.txt}"
    cyc="$(cl_upstream_cycle "$ctl" "$fmt")" || return 4
    h="$(cl_upstream_text_hash "[$sev] $rest")"
    [ "$(cl_upstream_prior_choice "$ctl" "$fmt" "$cyc" "$id" "$h")" = C ] || return 4
    _cl_dismiss_write "$ledger" "$id" "$reason" "$CL_UPSTREAM_ACCEPT_LABEL" "$CL_UPSTREAM_ACCEPT_LABEL" || return 1
    return 0
}

:  # load-success rc for the entrypoint's source check
