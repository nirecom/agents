#!/usr/bin/env bash
# SSOT for the run-all per-test duration ledger. bin/lib/run-all-parallelism.sh must be
# sourced FIRST (run_all_cache_dir, run_all_host_id, run_all_id_digest are used here).
# One segment file per writer process, never rewritten in place, so append atomicity is
# never relied upon; the read caps hold whether or not consolidation (consolidate-durations) ran.
# Raw seconds are stored and the tier is a READ-time classification, so re-cutting the tier
# granularity must NOT bump RUN_ALL_DUR_SCHEMA — only a record structure change does.

RUN_ALL_DUR_SCHEMA=3
RUN_ALL_DUR_DIRNAME="durations"
# Invariant: parallel runners' open segments + segments closed since the last start +
# abandoned ones (<= 6h) + consolidating leftovers + bases (one per OS attribute) stay
# under 64, or the oldest names (the bases first) fall out of the read window.
RUN_ALL_DUR_MAX_SEGMENTS_READ=64
RUN_ALL_DUR_MAX_RECORDS=60000
RUN_ALL_DUR_MAX_LINE_BYTES=512
RUN_ALL_DUR_MAX_KEY_BYTES=400
RUN_ALL_DUR_MAX_SECS_DIGITS=4
RUN_ALL_DUR_TOKEN_WIDTH=16
RUN_ALL_DUR_TIER_UNMEASURED=99

# The one row parser every ledger awk program is prefixed with: a v3 row is
# `<rid16>|<secs>|<verdict>|<termination>|<key>`; on success it sets P_RID, P_SECS, P_VERDICT,
# P_TERM and P_KEY. An unknown verdict/termination token passes (forward compatible).
RUN_ALL_DUR_AWK_PARSE='
function dur_tok(t) { return length(t) >= 1 && length(t) <= '"$RUN_ALL_DUR_TOKEN_WIDTH"' && t ~ /^[A-Za-z0-9?_-]+$/ }
function dur_parse(l,   p, r) {
    if (length(l) > '"$RUN_ALL_DUR_MAX_LINE_BYTES"') return 0
    p = index(l, "|"); if (p == 0) return 0
    P_RID = substr(l, 1, p - 1); r = substr(l, p + 1)
    p = index(r, "|"); if (p == 0) return 0
    P_SECS = substr(r, 1, p - 1); r = substr(r, p + 1)
    p = index(r, "|"); if (p == 0) return 0
    P_VERDICT = substr(r, 1, p - 1); r = substr(r, p + 1)
    p = index(r, "|"); if (p == 0) return 0
    P_TERM = substr(r, 1, p - 1); P_KEY = substr(r, p + 1)
    if (length(P_RID) != '"$RUN_ALL_DUR_TOKEN_WIDTH"' || P_RID !~ /^[A-Za-z0-9]+$/) return 0
    if (P_SECS !~ /^[0-9]+$/ || length(P_SECS) > '"$RUN_ALL_DUR_MAX_SECS_DIGITS"') return 0
    if (!dur_tok(P_VERDICT) || !dur_tok(P_TERM)) return 0
    return P_KEY != "" && index(P_KEY, "|") == 0
}
'

# Outputs; declared so a `set -u` caller may read them even after a failed call.
RUN_ALL_DUR_REASON=""
RUN_ALL_DUR_REPO_ID=""
RUN_ALL_DUR_HOST_TOKEN=""
RUN_ALL_DUR_OS_ATTR=""
RUN_ALL_DUR_SEGMENT=""
RUN_ALL_DUR_WRITE_OK=0
RUN_ALL_DUR_TIER_OUT=""
RUN_ALL_DUR_SEGMENTS_READ=0
RUN_ALL_DUR_KEY_OUT=""
RUN_ALL_DUR_SEGMENTS_OUT=()
RUN_ALL_DUR_FR_VERDICT="?"
RUN_ALL_DUR_FR_TERM="?"
_RADT_OUT=""

# --- identity ---------------------------------------------------------------

# Right-pad to exactly RUN_ALL_DUR_TOKEN_WIDTH characters of [A-Za-z0-9], so the
# segment-name and record-field classes are fixed-width by construction.
run_all_dur_pad16() {
    local v="${1:-}"
    v="${v//[!A-Za-z0-9]/}"
    v="${v}0000000000000000"
    printf '%s' "${v:0:16}"
}

run_all_dur_host_token() {
    if [ -z "$RUN_ALL_DUR_HOST_TOKEN" ]; then
        _run_all_host_facts
        RUN_ALL_DUR_HOST_TOKEN="$(run_all_dur_pad16 "$(run_all_id_digest "$_RUN_ALL_HOST_ID")")"
        [ -n "$RUN_ALL_DUR_OS_ATTR" ] || RUN_ALL_DUR_OS_ATTR="$_RUN_ALL_OS_ATTR"
    fi
    printf '%s' "$RUN_ALL_DUR_HOST_TOKEN"
}

# run_all_dur_repo_id <agents-dir> — keyed on the REPOSITORY, so every linked worktree
# shares one identity. `--path-format=absolute` would need git 2.31+, hence the cd.
run_all_dur_repo_id() {
    local agents_dir="${1:-}" src=""
    if [ -n "$RUN_ALL_DUR_REPO_ID" ]; then
        printf '%s' "$RUN_ALL_DUR_REPO_ID"
        return 0
    fi
    if [ -n "$agents_dir" ] && command -v git >/dev/null 2>&1; then
        src="$( cd "$agents_dir" 2>/dev/null &&
                cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null &&
                pwd -P )" || src=""
    fi
    [ -n "$src" ] || src="$agents_dir"
    RUN_ALL_DUR_REPO_ID="$(run_all_dur_pad16 "$(run_all_id_digest "$src")")"
    printf '%s' "$RUN_ALL_DUR_REPO_ID"
}

run_all_dur_dir() {
    printf '%s' "$(run_all_cache_dir)/$RUN_ALL_DUR_DIRNAME"
}

# --- the key ----------------------------------------------------------------

# run_all_dur_key_into <path> [<agents-dir>] — repo-relative key in RUN_ALL_DUR_KEY_OUT, empty
# on rejection. Fork-free (once per test); only format-breaking bytes are rejected — a space
# or a non-ASCII byte is DATA, and a bare basename is the fallback for an out-of-tree path.
run_all_dur_key_into() {
    local p="${1:-}" root="${2:-}" t LC_ALL=C LC_CTYPE=C
    RUN_ALL_DUR_KEY_OUT=""
    [ -n "$p" ] || return 1
    p="${p//\\//}"
    case "$p" in
        [A-Za-z]:/*|/*) ;;
        *) p="${PWD//\\//}/$p" ;;
    esac
    root="${root//\\//}"
    root="${root%/}"
    t="${TESTS_DIR:-}"
    t="${t//\\//}"
    t="${t%/}"
    if [ -n "$root" ] && [ "${p#"$root"/}" != "$p" ]; then
        p="${p#"$root"/}"
    elif [ -n "$t" ] && [ "${p#"$t"/}" != "$p" ]; then
        p="${p#"$t"/}"
    else
        p="${p##*/}"
    fi
    case "$p" in
        ''|*'|'*) return 1 ;;
    esac
    case "$p" in
        *"$(printf '\t')"*|*"$(printf '\r')"*) return 1 ;;
    esac
    [ "${#p}" -le "$RUN_ALL_DUR_MAX_KEY_BYTES" ] || return 1
    RUN_ALL_DUR_KEY_OUT="$p"
    return 0
}

# --- tier -------------------------------------------------------------------

# run_all_dur_tier_into <secs> — floor(log2(secs)) into RUN_ALL_DUR_TIER_OUT, fork-free;
# n3-duration-ledger-reader.sh N14 pins its 12 tier values directly.
run_all_dur_tier_into() {
    local n="${1:-}" b=0
    RUN_ALL_DUR_TIER_OUT="$RUN_ALL_DUR_TIER_UNMEASURED"
    case "$n" in ''|*[!0-9]*) return 1 ;; esac
    n=$((10#$n))
    while [ "$n" -ge 2 ]; do
        n=$((n / 2))
        b=$((b + 1))
    done
    RUN_ALL_DUR_TIER_OUT="$b"
    return 0
}

run_all_dur_tier() {
    run_all_dur_tier_into "${1:-}" || true
    printf '%s\n' "$RUN_ALL_DUR_TIER_OUT"
}

# --- reader -----------------------------------------------------------------

# Echo every keys-file id back with an empty value: the "nothing measured" answer.
run_all_dur_blank() {
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        printf '%s\t\n' "${line%%	*}"
    done <"$1" >>"$2"
    return 0
}

# run_all_dur_segments_into <dir> <host-token> — this host's own segments in RUN_ALL_DUR_SEGMENTS_OUT,
# newest first, capped at RUN_ALL_DUR_MAX_SEGMENTS_READ (fixed-width stamps make the C-collated glob
# chronological) whether or not consolidation (consolidate-durations) ever ran; empty when <dir> is
# missing. Always returns 0.
run_all_dur_segments_into() {
    local dir="${1:-}" tok="${2:-}" f i LC_ALL=C LC_CTYPE=C
    local -a segs=()
    RUN_ALL_DUR_SEGMENTS_OUT=()
    for f in "$dir"/dur."$RUN_ALL_DUR_SCHEMA"."$tok".*.log; do
        [ -f "$f" ] && segs+=("$f")
    done
    i=$(( ${#segs[@]} - 1 ))
    while [ "$i" -ge 0 ] && [ "${#RUN_ALL_DUR_SEGMENTS_OUT[@]}" -lt "$RUN_ALL_DUR_MAX_SEGMENTS_READ" ]; do
        RUN_ALL_DUR_SEGMENTS_OUT+=("${segs[$i]}")
        i=$((i - 1))
    done
    return 0
}

# run_all_dur_lookup <agents-dir> <keys-file> <out-file> — `<id>\t<key>` lines in, `<id>\t<secs-
# or-empty>` out in the SAME order. ALWAYS returns 0 (a missing or corrupt ledger is normal);
# RUN_ALL_DUR_REASON carries the why.
run_all_dur_lookup() {
    local agents_dir="${1:-}" keys="${2:-}" out="${3:-}"
    local LC_ALL=C LC_CTYPE=C
    local dir tok c

    RUN_ALL_DUR_REASON=""
    RUN_ALL_DUR_SEGMENTS_READ=0
    [ -n "$out" ] || { RUN_ALL_DUR_REASON="missing"; return 0; }
    : >"$out" 2>/dev/null || { RUN_ALL_DUR_REASON="unreadable"; return 0; }
    if [ -z "$keys" ] || [ ! -f "$keys" ]; then RUN_ALL_DUR_REASON="missing"; return 0; fi
    if [ ! -s "$keys" ]; then RUN_ALL_DUR_REASON="empty"; return 0; fi
    if ! command -v awk >/dev/null 2>&1; then
        RUN_ALL_DUR_REASON="no-awk"
        run_all_dur_blank "$keys" "$out"
        return 0
    fi

    # Called bare, never in `$(...)`: the memoised token/id must land in THIS shell.
    run_all_dur_repo_id "$agents_dir" >/dev/null
    run_all_dur_host_token >/dev/null
    tok="$RUN_ALL_DUR_HOST_TOKEN"
    dir="$(run_all_dur_dir)"
    run_all_dur_segments_into "$dir" "$tok"
    c="${#RUN_ALL_DUR_SEGMENTS_OUT[@]}"
    RUN_ALL_DUR_SEGMENTS_READ="$c"
    if [ "$c" -eq 0 ]; then
        RUN_ALL_DUR_REASON="missing"
        run_all_dur_blank "$keys" "$out"
        return 0
    fi

    # Only the 16-alnum repo id and a numeric cap cross into awk; segment text never does.
    if LC_ALL=C awk -v RID="$RUN_ALL_DUR_REPO_ID" -v MAXREC="$RUN_ALL_DUR_MAX_RECORDS" "$RUN_ALL_DUR_AWK_PARSE"'
function merge(   z) {
    for (z in cur) if (!(z in secs)) secs[z] = cur[z]
    split("", cur)
}
NR == FNR {
    n++
    p = index($0, "\t")
    if (p > 0) { id[n] = substr($0, 1, p - 1); k = substr($0, p + 1) }
    else       { id[n] = $0; k = "" }
    key[n] = k
    if (k != "") want[k] = 1
    next
}
{
    if (++nline > MAXREC) exit
    if (FILENAME != pf) { merge(); pf = FILENAME }
    if (substr($0, 1, 1) == "#") next
    if (!dur_parse($0) || P_RID != RID || !(P_KEY in want)) next
    cur[P_KEY] = P_SECS
}
END {
    merge()
    for (j = 1; j <= n; j++) print id[j] "\t" ((key[j] in secs) ? secs[key[j]] : "")
}
' "$keys" "${RUN_ALL_DUR_SEGMENTS_OUT[@]}" >"$out" 2>/dev/null; then
        RUN_ALL_DUR_REASON="ok"
    else
        RUN_ALL_DUR_REASON="unreadable"
        : >"$out" 2>/dev/null
        run_all_dur_blank "$keys" "$out"
    fi
    return 0
}

# --- writer -----------------------------------------------------------------

# run_all_dur_writer_init <agents-dir> — idempotent; every failure is silent, leaving
# RUN_ALL_DUR_WRITE_OK 0. The pid in the name makes the segment this process's own.
run_all_dur_writer_init() {
    local agents_dir="${1:-}" dir tok rid stamp seg
    [ -n "$RUN_ALL_DUR_SEGMENT" ] && return 0
    RUN_ALL_DUR_WRITE_OK=0
    dir="$(run_all_dur_dir)"
    mkdir -p "$dir" 2>/dev/null || return 0
    [ -d "$dir" ] || return 0
    run_all_dur_host_token >/dev/null
    run_all_dur_repo_id "$agents_dir" >/dev/null
    tok="$RUN_ALL_DUR_HOST_TOKEN"
    rid="$RUN_ALL_DUR_REPO_ID"
    case "$tok$rid" in *[!A-Za-z0-9]*) return 0 ;; esac
    [ "${#tok}" -eq "$RUN_ALL_DUR_TOKEN_WIDTH" ] || return 0
    [ "${#rid}" -eq "$RUN_ALL_DUR_TOKEN_WIDTH" ] || return 0
    stamp="$(date -u +%Y%m%dT%H%M%S 2>/dev/null)"
    case "$stamp" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]) ;;
        *) return 0 ;;
    esac
    case "$$" in ''|*[!0-9]*) return 0 ;; esac
    command -v run_all_dur_consolidate >/dev/null 2>&1 && run_all_dur_consolidate "$dir" "$stamp"
    [ -n "$RUN_ALL_DUR_OS_ATTR" ] || RUN_ALL_DUR_OS_ATTR="$(run_all_os_attr)"
    seg="$dir/dur.$RUN_ALL_DUR_SCHEMA.$tok.$stamp-$$.log"
    printf '#os %s\n' "$RUN_ALL_DUR_OS_ATTR" >"$seg" 2>/dev/null || return 0
    RUN_ALL_DUR_SEGMENT="$seg"
    RUN_ALL_DUR_WRITE_OK=1
    return 0
}

# run_all_dur_close — mark this runner's segment closed so the next start consolidates it;
# a missing segment (never opened, or taken by another round) or a taken name is a no-op.
run_all_dur_close() {
    local seg="$RUN_ALL_DUR_SEGMENT" dest
    RUN_ALL_DUR_WRITE_OK=0
    [ -n "$seg" ] && [ -f "$seg" ] || return 0
    dest="${seg%.log}.closed.log"
    [ -e "$dest" ] && return 0
    mv "$seg" "$dest" 2>/dev/null
    return 0
}

# run_all_dur_file_result <state> — `<verdict> <termination>` of a run-all file state; the table's
# SSOT is docs/architecture/claude-code/test-result-contract.md (the "file result" section).
# The `_into` form is fork-free: RUN_ALL_DUR_FR_VERDICT / RUN_ALL_DUR_FR_TERM.
run_all_dur_file_result_into() {
    RUN_ALL_DUR_FR_VERDICT="-"
    case "${1:-}" in
        PASS|FAIL|SKIP) RUN_ALL_DUR_FR_VERDICT="$1"; RUN_ALL_DUR_FR_TERM=completed ;;
        TIMEOUT) RUN_ALL_DUR_FR_TERM=timeout ;;
        UNRUNNABLE) RUN_ALL_DUR_FR_TERM=unrunnable ;;
        UNSUPPORTED) RUN_ALL_DUR_FR_TERM=unsupported ;;
        *) RUN_ALL_DUR_FR_VERDICT="?"; RUN_ALL_DUR_FR_TERM="?" ;;
    esac
    return 0
}
run_all_dur_file_result() {
    run_all_dur_file_result_into "${1:-}"
    printf '%s %s\n' "$RUN_ALL_DUR_FR_VERDICT" "$RUN_ALL_DUR_FR_TERM"
}

# _run_all_dur_token_into <value> — fork-free: the value when it is a valid row token, else
# `?`, in _RADT_OUT.
_run_all_dur_token_into() {
    _RADT_OUT="?"
    case "${1:-}" in ''|*[!A-Za-z0-9?_-]*) return 0 ;; esac
    [ "${#1}" -le "$RUN_ALL_DUR_TOKEN_WIDTH" ] && _RADT_OUT="$1"
    return 0
}

# run_all_dur_append <key> <secs> [<verdict> <termination>] — one
# `<repo_id>|<secs>|<verdict>|<termination>|<key>` line, or nothing at all; an invalid
# verdict or termination is recorded as `?` rather than dropping the row.
run_all_dur_append() {
    local key="${1:-}" secs="${2:-}" v t LC_ALL=C LC_CTYPE=C
    _run_all_dur_token_into "${3:-}"; v="$_RADT_OUT"
    _run_all_dur_token_into "${4:-}"; t="$_RADT_OUT"
    [ "$RUN_ALL_DUR_WRITE_OK" -eq 1 ] || return 0
    [ -n "$RUN_ALL_DUR_SEGMENT" ] || return 0
    case "$secs" in ''|*[!0-9]*) return 0 ;; esac
    [ "${#secs}" -le "$RUN_ALL_DUR_MAX_SECS_DIGITS" ] || return 0
    case "$key" in ''|*'|'*) return 0 ;; esac
    case "$key" in *"$(printf '\t')"*|*"$(printf '\r')"*) return 0 ;; esac
    [ "${#key}" -le "$RUN_ALL_DUR_MAX_KEY_BYTES" ] || return 0
    [ "${#RUN_ALL_DUR_REPO_ID}" -eq "$RUN_ALL_DUR_TOKEN_WIDTH" ] || return 0
    # A consolidation round may have taken an abandoned-looking segment; restart it headed.
    [ -f "$RUN_ALL_DUR_SEGMENT" ] || printf '#os %s\n' "$RUN_ALL_DUR_OS_ATTR" >"$RUN_ALL_DUR_SEGMENT" 2>/dev/null
    printf '%s|%s|%s|%s|%s\n' "$RUN_ALL_DUR_REPO_ID" "$secs" "$v" "$t" "$key" \
        >>"$RUN_ALL_DUR_SEGMENT" 2>/dev/null || true
    return 0
}

# Consolidation (closed/abandoned segments → one base per OS attribute); absent module = no-op.
# shellcheck source=bin/lib/run-all-durations-consolidate.sh
if [ -f "${BASH_SOURCE[0]%/*}/run-all-durations-consolidate.sh" ]; then . "${BASH_SOURCE[0]%/*}/run-all-durations-consolidate.sh"; fi

# Time-limited #2079 migration hook; absent module = legacy files simply go unread.
# shellcheck source=bin/lib/run-all-ledger-migrate.sh
if [ -f "${BASH_SOURCE[0]%/*}/run-all-ledger-migrate.sh" ]; then . "${BASH_SOURCE[0]%/*}/run-all-ledger-migrate.sh"; fi
