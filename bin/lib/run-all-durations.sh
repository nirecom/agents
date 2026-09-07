#!/usr/bin/env bash
# SSOT for the run-all per-test duration ledger. bin/lib/run-all-parallelism.sh must be
# sourced FIRST (run_all_cache_dir, run_all_host_id, run_all_id_digest are used here).
# One segment file per writer process, never rewritten in place, so append atomicity is
# never relied upon; the read caps are enforced independently of the retention sweep.
# Raw seconds are stored and the tier is a READ-time classification, so re-cutting the tier
# granularity must NOT bump RUN_ALL_DUR_SCHEMA — only a record structure change does.

RUN_ALL_DUR_SCHEMA=1
RUN_ALL_DUR_DIRNAME="durations"
RUN_ALL_DUR_KEEP_SEGMENTS=16
RUN_ALL_DUR_MAX_SEGMENTS_READ=64
RUN_ALL_DUR_MAX_RECORDS=60000
RUN_ALL_DUR_MAX_LINE_BYTES=512
RUN_ALL_DUR_MAX_KEY_BYTES=400
RUN_ALL_DUR_MAX_SECS_DIGITS=4
RUN_ALL_DUR_TOKEN_WIDTH=16
RUN_ALL_DUR_TIER_UNMEASURED=99
RUN_ALL_DUR_SWEEP_MAX=64

# Outputs; declared so a `set -u` caller may read them even after a failed call.
RUN_ALL_DUR_REASON=""
RUN_ALL_DUR_REPO_ID=""
RUN_ALL_DUR_HOST_TOKEN=""
RUN_ALL_DUR_SEGMENT=""
RUN_ALL_DUR_WRITE_OK=0
RUN_ALL_DUR_TIER_OUT=""
RUN_ALL_DUR_SEGMENTS_READ=0
RUN_ALL_DUR_KEY_OUT=""

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
        RUN_ALL_DUR_HOST_TOKEN="$(run_all_dur_pad16 "$(run_all_id_digest "$(run_all_host_id)")")"
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

# run_all_dur_tier_into <secs> — floor(log2(secs)) into RUN_ALL_DUR_TIER_OUT. A DELIBERATE
# fork-free duplicate of run_all_count_bucket; n3-duration-ledger-reader.sh N14 pins the two.
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

# run_all_dur_lookup <agents-dir> <keys-file> <out-file> — `<id>\t<key>` lines in, `<id>\t<secs-
# or-empty>` out in the SAME order. ALWAYS returns 0 (a missing or corrupt ledger is normal);
# RUN_ALL_DUR_REASON carries the why.
run_all_dur_lookup() {
    local agents_dir="${1:-}" keys="${2:-}" out="${3:-}"
    local LC_ALL=C LC_CTYPE=C
    local dir tok f i c
    local -a segs=() use=()

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
    # Fixed-width stamps make the C-collated glob chronological; walking it backwards yields
    # newest-first, capped here whether or not the sweep ever ran.
    for f in "$dir"/dur."$RUN_ALL_DUR_SCHEMA"."$tok".*.log; do
        [ -f "$f" ] && segs+=("$f")
    done
    i=$(( ${#segs[@]} - 1 ))
    c=0
    while [ "$i" -ge 0 ] && [ "$c" -lt "$RUN_ALL_DUR_MAX_SEGMENTS_READ" ]; do
        use+=("${segs[$i]}")
        i=$((i - 1))
        c=$((c + 1))
    done
    RUN_ALL_DUR_SEGMENTS_READ="$c"
    if [ "$c" -eq 0 ]; then
        RUN_ALL_DUR_REASON="missing"
        run_all_dur_blank "$keys" "$out"
        return 0
    fi

    # Only the 16-alnum repo id and a numeric cap cross into awk; segment text never does.
    if LC_ALL=C awk -v RID="$RUN_ALL_DUR_REPO_ID" -v MAXREC="$RUN_ALL_DUR_MAX_RECORDS" '
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
    p1 = index($0, "|")
    if (p1 == 0 || substr($0, 1, p1 - 1) != RID) next
    r = substr($0, p1 + 1)
    p2 = index(r, "|")
    if (p2 == 0) next
    s = substr(r, 1, p2 - 1)
    if (s !~ /^[0-9][0-9]?[0-9]?[0-9]?$/) next
    k = substr(r, p2 + 1)
    if (k == "" || index(k, "|") > 0 || !(k in want)) next
    cur[k] = s
}
END {
    merge()
    for (j = 1; j <= n; j++) print id[j] "\t" ((key[j] in secs) ? secs[key[j]] : "")
}
' "$keys" "${use[@]}" >"$out" 2>/dev/null; then
        RUN_ALL_DUR_REASON="ok"
    else
        RUN_ALL_DUR_REASON="unreadable"
        : >"$out" 2>/dev/null
        run_all_dur_blank "$keys" "$out"
    fi
    return 0
}

# --- writer -----------------------------------------------------------------

# Trim this host/schema class to KEEP_SEGMENTS, oldest first; a refused unlink is ignored.
run_all_dur_sweep() {
    local LC_ALL=C LC_CTYPE=C
    local dir f n drop i=0
    local -a segs=()
    run_all_dur_host_token >/dev/null
    dir="$(run_all_dur_dir)"
    for f in "$dir"/dur."$RUN_ALL_DUR_SCHEMA"."$RUN_ALL_DUR_HOST_TOKEN".*.log; do
        [ -f "$f" ] && segs+=("$f")
    done
    n=${#segs[@]}
    [ "$n" -gt "$RUN_ALL_DUR_KEEP_SEGMENTS" ] || return 0
    drop=$((n - RUN_ALL_DUR_KEEP_SEGMENTS))
    [ "$drop" -gt "$RUN_ALL_DUR_SWEEP_MAX" ] && drop="$RUN_ALL_DUR_SWEEP_MAX"
    while [ "$i" -lt "$drop" ]; do
        rm -f "${segs[$i]}" 2>/dev/null || true
        i=$((i + 1))
    done
    return 0
}

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
    seg="$dir/dur.$RUN_ALL_DUR_SCHEMA.$tok.$stamp-$$.log"
    : >"$seg" 2>/dev/null || return 0
    RUN_ALL_DUR_SEGMENT="$seg"
    run_all_dur_sweep
    RUN_ALL_DUR_WRITE_OK=1
    return 0
}

# run_all_dur_append <key> <secs> — one `<repo_id>|<secs>|<key>` line, or nothing at all.
run_all_dur_append() {
    local key="${1:-}" secs="${2:-}" LC_ALL=C LC_CTYPE=C
    [ "$RUN_ALL_DUR_WRITE_OK" -eq 1 ] || return 0
    [ -n "$RUN_ALL_DUR_SEGMENT" ] || return 0
    case "$secs" in ''|*[!0-9]*) return 0 ;; esac
    [ "${#secs}" -le "$RUN_ALL_DUR_MAX_SECS_DIGITS" ] || return 0
    case "$key" in ''|*'|'*) return 0 ;; esac
    case "$key" in *"$(printf '\t')"*|*"$(printf '\r')"*) return 0 ;; esac
    [ "${#key}" -le "$RUN_ALL_DUR_MAX_KEY_BYTES" ] || return 0
    [ "${#RUN_ALL_DUR_REPO_ID}" -eq "$RUN_ALL_DUR_TOKEN_WIDTH" ] || return 0
    printf '%s|%s|%s\n' "$RUN_ALL_DUR_REPO_ID" "$secs" "$key" \
        >>"$RUN_ALL_DUR_SEGMENT" 2>/dev/null || true
    return 0
}
