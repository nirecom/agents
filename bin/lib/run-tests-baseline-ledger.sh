#!/usr/bin/env bash
# Baseline result ledger for bin/run-tests-baseline (#2431). Source-only.
# One append-only segment per process at
#   $(run_all_cache_dir)/baseline/<repo_id>/<host>-<epoch>-<pid>.seg
# with lines `v1\t<base-sha>\t<host>\t<rel-path>\t<fail|pass>\t<epoch>`.
# Identity helpers are reused from the duration ledger; reads are capped and
# corrupt lines skipped; a write failure only warns (the ledger is a cache).

case "${BASH_SOURCE[0]}" in
  */*) RTB_LEDGER_LIB_DIR="${BASH_SOURCE[0]%/*}" ;;
  *)   RTB_LEDGER_LIB_DIR="." ;;
esac
# shellcheck source=bin/lib/run-all-parallelism.sh
. "$RTB_LEDGER_LIB_DIR/run-all-parallelism.sh"
# shellcheck source=bin/lib/run-all-durations.sh
. "$RTB_LEDGER_LIB_DIR/run-all-durations.sh"

RTB_LEDGER_SCHEMA="v1"
RTB_LEDGER_RETENTION_DAYS=30
RTB_LEDGER_MAX_SEGMENTS_READ=256
RTB_LEDGER_MAX_RECORDS=60000
RTB_LEDGER_MAX_LINE_BYTES=1024
RTB_LEDGER_SEGMENT=""
RTB_LEDGER_WRITE_OK=0

# The repository the ledger is keyed on: RTB_LEDGER_REPO when set, else the cwd.
rtb_ledger_dir() {
    run_all_dur_repo_id "${RTB_LEDGER_REPO:-$PWD}" >/dev/null
    printf '%s' "$(run_all_cache_dir)/baseline/$RUN_ALL_DUR_REPO_ID"
}

rtb_ledger_warn() {
    printf 'run-tests-baseline: ledger: %s\n' "$1" >&2
}

rtb_ledger_valid_sha() {
    case "${1:-}" in
        ''|*[!0-9a-f]*) return 1 ;;
    esac
    [ "${#1}" -ge 7 ] && [ "${#1}" -le 64 ]
}

rtb_ledger_valid_path() {
    local p="${1:-}"
    [ -n "$p" ] || return 1
    case "$p" in
        *$'\t'*|*$'\r'*|*$'\n'*) return 1 ;;
    esac
    [ "${#p}" -le 400 ]
}

# Delete this repo's segments whose mtime is past the retention window.
rtb_ledger_sweep() {
    local dir
    dir="$(rtb_ledger_dir)"
    [ -d "$dir" ] || return 0
    find "$dir" -maxdepth 1 -type f -name '*.seg' \
        -mmin +$((RTB_LEDGER_RETENTION_DAYS * 1440)) -exec rm -f {} + 2>/dev/null || true
    return 0
}

# Idempotent per process; on failure leaves RTB_LEDGER_WRITE_OK=0 after one warning.
rtb_ledger_writer_init() {
    local dir seg
    [ -n "$RTB_LEDGER_SEGMENT" ] && return 0
    RTB_LEDGER_WRITE_OK=0
    run_all_dur_host_token >/dev/null
    dir="$(rtb_ledger_dir)"
    if ! mkdir -p "$dir" 2>/dev/null || [ ! -d "$dir" ]; then
        rtb_ledger_warn "cannot create $dir; results not recorded"
        RTB_LEDGER_SEGMENT="-"
        return 0
    fi
    seg="$dir/$RUN_ALL_DUR_HOST_TOKEN-$(date +%s)-$$.seg"
    if ! : >>"$seg" 2>/dev/null; then
        rtb_ledger_warn "cannot write $seg; results not recorded"
        RTB_LEDGER_SEGMENT="-"
        return 0
    fi
    RTB_LEDGER_SEGMENT="$seg"
    RTB_LEDGER_WRITE_OK=1
    rtb_ledger_sweep
    return 0
}

# rtb_ledger_append <base-sha> <rel-path> <fail|pass> — always returns 0.
rtb_ledger_append() {
    local sha="${1:-}" rel="${2:-}" res="${3:-}"
    case "$res" in fail|pass) ;; *) rtb_ledger_warn "bad result '$res'"; return 0 ;; esac
    rtb_ledger_valid_sha "$sha" || { rtb_ledger_warn "bad sha"; return 0; }
    rtb_ledger_valid_path "$rel" || { rtb_ledger_warn "bad path"; return 0; }
    rtb_ledger_writer_init
    [ "$RTB_LEDGER_WRITE_OK" -eq 1 ] || return 0
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$RTB_LEDGER_SCHEMA" "$sha" "$RUN_ALL_DUR_HOST_TOKEN" \
        "$rel" "$res" "$(date +%s)" >>"$RTB_LEDGER_SEGMENT" 2>/dev/null \
        || rtb_ledger_warn "append to $RTB_LEDGER_SEGMENT failed"
    return 0
}

# rtb_ledger_scan <sha-or-empty> <rel-path> <min-epoch> — prints valid records for this
# host and path as `<epoch>\t<sha>\t<result>`; only fixed-shape fields enter awk.
rtb_ledger_scan() {
    local want_sha="${1:-}" rel="${2:-}" min_epoch="${3:-0}" dir f i
    local -a all=() segs=()
    dir="$(rtb_ledger_dir)"
    [ -d "$dir" ] || return 0
    run_all_dur_host_token >/dev/null
    for f in "$dir"/"$RUN_ALL_DUR_HOST_TOKEN"-*.seg; do
        [ -f "$f" ] || continue
        all+=("$f")
    done
    # Names embed the 10-digit creation epoch, so glob order is oldest-first; read
    # newest-first so both caps drop the oldest records, never the latest verdict.
    for ((i = ${#all[@]} - 1; i >= 0 && ${#segs[@]} < RTB_LEDGER_MAX_SEGMENTS_READ; i--)); do
        segs+=("${all[i]}")
    done
    [ "${#segs[@]}" -gt 0 ] || return 0
    LC_ALL=C awk -F '\t' -v HOST="$RUN_ALL_DUR_HOST_TOKEN" -v REL="$rel" -v SHA="$want_sha" \
        -v MIN="$min_epoch" -v MAXREC="$RTB_LEDGER_MAX_RECORDS" \
        -v MAXLEN="$RTB_LEDGER_MAX_LINE_BYTES" -v SCHEMA="$RTB_LEDGER_SCHEMA" '
{
    if (++n > MAXREC) exit
    if (length($0) > MAXLEN || NF != 6) next
    if ($1 != SCHEMA || $3 != HOST || $4 != REL) next
    if ($2 !~ /^[0-9a-f]+$/ || length($2) < 7 || length($2) > 64) next
    if ($5 != "fail" && $5 != "pass") next
    if ($6 !~ /^[0-9]+$/ || ($6 + 0) < (MIN + 0)) next
    if (SHA != "" && $2 != SHA) next
    print $6 "\t" $2 "\t" $5
}' "${segs[@]}" 2>/dev/null || true
}

# rtb_ledger_lookup_same_base <sha> <rel-path> — prints the newest result (fail|pass) or nothing.
rtb_ledger_lookup_same_base() {
    rtb_ledger_valid_sha "${1:-}" || return 0
    rtb_ledger_valid_path "${2:-}" || return 0
    rtb_ledger_scan "$1" "$2" 0 | sort -t "$(printf '\t')" -k1,1n | tail -n 1 | cut -f3
}

# rtb_ledger_lookup_inheritable <rel-path> — base SHAs with a `fail` record for this host
# inside the retention window, newest first, one per line.
rtb_ledger_lookup_inheritable() {
    local now min
    rtb_ledger_valid_path "${1:-}" || return 0
    now="$(date +%s)"
    min=$((now - RTB_LEDGER_RETENTION_DAYS * 86400))
    rtb_ledger_scan "" "$1" "$min" | awk -F '\t' '$3 == "fail"' \
        | sort -t "$(printf '\t')" -k1,1nr | awk -F '\t' '!seen[$2]++ { print $2 }'
}
