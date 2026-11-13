#!/usr/bin/env bash
# Baseline result ledger for bin/run-tests-baseline (#2431). Source-only.
# One append-only segment per process at
#   $(run_all_cache_dir)/baseline/<repo_id>/v3.<host>-<epoch>-<pid>.seg
# with lines `v3\t<base-sha>\t<host>\t<rel-path>\t<fail|pass|und:..>\t<fp|->\t<epoch>\t<os-attr>`;
# <fp> names the row file v3.lines.<fp> (run-tests-baseline-lines.sh). v1/v2 rows are never read.
# Legacy carry-over: run-all-ledger-migrate.sh. Reads are capped, corrupt lines skipped, and a
# write failure only warns (the ledger is a cache). Format: docs/architecture/claude-code/test-result-contract.md.

case "${BASH_SOURCE[0]}" in
  */*) RTB_LEDGER_LIB_DIR="${BASH_SOURCE[0]%/*}" ;;
  *)   RTB_LEDGER_LIB_DIR="." ;;
esac
# shellcheck source=bin/lib/run-all-parallelism.sh
. "$RTB_LEDGER_LIB_DIR/run-all-parallelism.sh"
# shellcheck source=bin/lib/run-all-durations.sh
. "$RTB_LEDGER_LIB_DIR/run-all-durations.sh"
# shellcheck source=bin/lib/run-tests-baseline-lines.sh
. "$RTB_LEDGER_LIB_DIR/run-tests-baseline-lines.sh"

RTB_LEDGER_SCHEMA="v3"
RTB_LEDGER_RETENTION_DAYS=30
RTB_LEDGER_MAX_SEGMENTS_READ=256
RTB_LEDGER_MAX_RECORDS=60000
RTB_LEDGER_MAX_LINE_BYTES=1024
RTB_LEDGER_SEGMENT=""
RTB_LEDGER_WRITE_OK=0
RTB_LEDGER_OPENED=""
RTB_LEDGER_SEGS=()
# und: results the same base reproduces every time; any other und: is never reused.
RTB_LEDGER_UND_CACHEABLE_RE='^und:(unsupported-at-base|base-launcher-predates-result-conversion)$'

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

# Delete this repo's segments and row files whose mtime is past the retention window.
rtb_ledger_sweep() {
    local dir
    dir="$(rtb_ledger_dir)"
    [ -d "$dir" ] || return 0
    find "$dir" -maxdepth 1 -type f \( -name '*.seg' -o -name 'v3.lines.*' \) \
        -mmin +$((RTB_LEDGER_RETENTION_DAYS * 1440)) -exec rm -f {} + 2>/dev/null || true
    return 0
}

# Time-limited #2079 hook: fold this repo's legacy segments in before any read or write.
rtb_ledger_migrate() {
    command -v run_all_ledger_migrate_baseline >/dev/null 2>&1 || return 0
    run_all_ledger_migrate_baseline "$1"
    return 0
}

# rtb_ledger_seg_open <prefix> — creates this process's <prefix>.<host>-<epoch>-<pid>.seg and
# sets RTB_LEDGER_OPENED to its path; returns 1 after one warning when it cannot.
rtb_ledger_seg_open() {
    local prefix="${1:-}" dir seg
    RTB_LEDGER_OPENED=""
    [[ "$prefix" =~ ^[a-z][a-z0-9.]*$ ]] || { rtb_ledger_warn "bad segment prefix '$prefix'"; return 1; }
    run_all_dur_host_token >/dev/null
    dir="$(rtb_ledger_dir)"
    if ! mkdir -p "$dir" 2>/dev/null || [[ ! -d "$dir" ]]; then
        rtb_ledger_warn "cannot create $dir; results not recorded"
        return 1
    fi
    rtb_ledger_migrate "$dir"
    seg="$dir/$prefix.$RUN_ALL_DUR_HOST_TOKEN-$(date +%s)-$$.seg"
    if ! : >>"$seg" 2>/dev/null; then
        rtb_ledger_warn "cannot write $seg; results not recorded"
        return 1
    fi
    RTB_LEDGER_OPENED="$seg"
    rtb_ledger_sweep
    return 0
}

# rtb_ledger_seg_list <prefix> — sets RTB_LEDGER_SEGS to this host's <prefix> segments,
# newest first, capped at RTB_LEDGER_MAX_SEGMENTS_READ.
rtb_ledger_seg_list() {
    local prefix="${1:-}" dir f i
    local -a all=()
    RTB_LEDGER_SEGS=()
    [[ "$prefix" =~ ^[a-z][a-z0-9.]*$ ]] || return 0
    dir="$(rtb_ledger_dir)"
    [[ -d "$dir" ]] || return 0
    run_all_dur_host_token >/dev/null
    rtb_ledger_migrate "$dir"
    for f in "$dir"/"$prefix.$RUN_ALL_DUR_HOST_TOKEN"-*.seg; do
        [[ -f "$f" ]] || continue
        all+=("$f")
    done
    # Names embed the 10-digit creation epoch, so glob order is oldest-first; read
    # newest-first so both caps drop the oldest records, never the latest verdict.
    for ((i = ${#all[@]} - 1; i >= 0 && ${#RTB_LEDGER_SEGS[@]} < RTB_LEDGER_MAX_SEGMENTS_READ; i--)); do
        RTB_LEDGER_SEGS+=("${all[i]}")
    done
    return 0
}

# Idempotent per process; on failure leaves RTB_LEDGER_WRITE_OK=0 after one warning.
rtb_ledger_writer_init() {
    [ -n "$RTB_LEDGER_SEGMENT" ] && return 0
    RTB_LEDGER_WRITE_OK=0
    if ! rtb_ledger_seg_open "$RTB_LEDGER_SCHEMA"; then
        RTB_LEDGER_SEGMENT="-"
        return 0
    fi
    [ -n "$RUN_ALL_DUR_OS_ATTR" ] || RUN_ALL_DUR_OS_ATTR="$(run_all_os_attr)"
    RTB_LEDGER_SEGMENT="$RTB_LEDGER_OPENED"
    RTB_LEDGER_WRITE_OK=1
    return 0
}

# rtb_ledger_append <base-sha> <rel-path> <fail|pass|und:<detail>> [<fp>] — always returns 0.
# <fp> (default `-`) names the row file holding the side's failure lines.
rtb_ledger_append() {
    local sha="${1:-}" rel="${2:-}" res="${3:-}" fp="${4:--}"
    [[ "$res" =~ ^(fail|pass|und:[a-z0-9][a-z0-9-]*)$ && "${#res}" -le 80 ]] \
        || { rtb_ledger_warn "bad result '$res'"; return 0; }
    rtb_ledger_valid_sha "$sha" || { rtb_ledger_warn "bad sha"; return 0; }
    rtb_ledger_valid_path "$rel" || { rtb_ledger_warn "bad path"; return 0; }
    [[ "$fp" == "-" ]] || rtb_ledger_valid_fp "$fp" || { rtb_ledger_warn "bad fp"; fp="-"; }
    rtb_ledger_writer_init
    [ "$RTB_LEDGER_WRITE_OK" -eq 1 ] || return 0
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$RTB_LEDGER_SCHEMA" "$sha" "$RUN_ALL_DUR_HOST_TOKEN" \
        "$rel" "$res" "$fp" "$(date +%s)" "$RUN_ALL_DUR_OS_ATTR" >>"$RTB_LEDGER_SEGMENT" 2>/dev/null \
        || rtb_ledger_warn "append to $RTB_LEDGER_SEGMENT failed"
    return 0
}

# rtb_ledger_scan <sha-or-empty> <rel-path> <min-epoch> — prints valid records for this
# host and path as `<epoch>\t<sha>\t<result>\t<fp|->`; only fixed-shape fields enter awk.
rtb_ledger_scan() {
    local want_sha="${1:-}" rel="${2:-}" min_epoch="${3:-0}"
    rtb_ledger_seg_list "$RTB_LEDGER_SCHEMA"
    [ "${#RTB_LEDGER_SEGS[@]}" -gt 0 ] || return 0
    # REL travels through the environment: awk -v would interpret backslash escapes in it.
    RTB_AWK_REL="$rel" LC_ALL=C awk -F '\t' -v HOST="$RUN_ALL_DUR_HOST_TOKEN" -v SHA="$want_sha" \
        -v MIN="$min_epoch" -v MAXREC="$RTB_LEDGER_MAX_RECORDS" \
        -v MAXLEN="$RTB_LEDGER_MAX_LINE_BYTES" -v SCHEMA="$RTB_LEDGER_SCHEMA" \
        -v ATTRRE="$RUN_ALL_OS_ATTR_CLASS" '
BEGIN { REL = ENVIRON["RTB_AWK_REL"] }
{
    if (++n > MAXREC) exit
    if (length($0) > MAXLEN || NF != 8) next
    if ($1 != SCHEMA || $3 != HOST || $4 != REL) next
    s = index($8, "/")
    if (s < 2 || s > 33 || length($8) - s < 1 || length($8) - s > 64) next
    if ($8 !~ ATTRRE) next
    if ($2 !~ /^[0-9a-f]+$/ || length($2) < 7 || length($2) > 64) next
    if ($5 != "fail" && $5 != "pass" && $5 !~ /^und:[a-z0-9][a-z0-9-]*$/) next
    if ($6 != "-" && ($6 !~ /^[0-9a-f]+$/ || length($6) != 64)) next
    if ($7 !~ /^[0-9]+$/ || ($7 + 0) < (MIN + 0)) next
    if (SHA != "" && $2 != SHA) next
    print $7 "\t" $2 "\t" $5 "\t" $6
}' "${RTB_LEDGER_SEGS[@]}" 2>/dev/null || true
}

# rtb_ledger_lookup_same_base <sha> <rel-path> — prints the newest reusable result (fail|pass,
# or a deterministic und:<detail>) and its fp as `<result>\t<fp|->`, or nothing.
rtb_ledger_lookup_same_base() {
    rtb_ledger_valid_sha "${1:-}" || return 0
    rtb_ledger_valid_path "${2:-}" || return 0
    rtb_ledger_scan "$1" "$2" 0 | awk -F '\t' -v UND="$RTB_LEDGER_UND_CACHEABLE_RE" \
        '$3 == "fail" || $3 == "pass" || $3 ~ UND' \
        | sort -t "$(printf '\t')" -k1,1n | tail -n 1 | cut -f3,4
}

# rtb_ledger_lookup_inheritable_fp <rel-path> — `<sha>\t<fp>` for each base SHA whose newest
# `fail` record in the retention window carries a row file fp, newest first.
rtb_ledger_lookup_inheritable_fp() {
    local now min
    rtb_ledger_valid_path "${1:-}" || return 0
    now="$(date +%s)"
    min=$((now - RTB_LEDGER_RETENTION_DAYS * 86400))
    rtb_ledger_scan "" "$1" "$min" | awk -F '\t' '$3 == "fail" && $4 != "-"' \
        | sort -t "$(printf '\t')" -k1,1nr | awk -F '\t' '!seen[$2]++ { print $2 "\t" $4 }'
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
