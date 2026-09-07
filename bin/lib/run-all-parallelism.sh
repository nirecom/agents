#!/usr/bin/env bash
# SSOT for the run-all parallelism cache. Sourced by tests/run-all.sh and
# bin/calibrate-test-parallelism.sh; defines constants/functions only.
# Cache values are compared as strings only — never expanded, never used in arithmetic.
# Sibling bin/lib/run-all-durations.sh (the duration ledger) reuses the helpers below, so it requires this file to be sourced first.

RUN_ALL_CACHE_SCHEMA=1
RUN_ALL_FALLBACK_JOBS=4
RUN_ALL_CALIBRATOR_HINT="bin/calibrate-test-parallelism.sh"

RUN_ALL_CACHE_BASENAME="parallelism.conf"
RUN_ALL_CACHE_MAX_LINES=64
RUN_ALL_CACHE_MAX_LINE_BYTES=512
RUN_ALL_CACHE_MIN_JOBS=1
RUN_ALL_CACHE_MAX_JOBS=1024
RUN_ALL_CACHE_ALLOWED_KEYS="schema host_id count_bucket jobs measured_at sample_size repeat"

# Outputs of run_all_cache_read; declared so a `set -u` caller may read them
# unconditionally after a failed call.
RUN_ALL_CACHE_JOBS=""
RUN_ALL_CACHE_MEASURED_AT=""
RUN_ALL_CACHE_REASON=""

# --- locations --------------------------------------------------------------

run_all_cache_dir() {
    printf '%s\n' "${RUN_ALL_CACHE_DIR:-${HOME:-.}/.claude/run-all}"
}

run_all_cache_file() {
    printf '%s\n' "$(run_all_cache_dir)/$RUN_ALL_CACHE_BASENAME"
}

# --- host identity ----------------------------------------------------------

# Keep only characters the reader's host_id class accepts; '|' is the field
# separator so it is excluded from the per-field class.
run_all_id_field() {
    local v="${1:-}"
    v="${v//[!A-Za-z0-9._-]/-}"
    [ -n "$v" ] || v="unknown"
    printf '%s' "$v"
}

# Digest a string to hex/decimal. Cascade so the identity stays stable on any
# host carrying at least one of the four standard checksum tools.
run_all_id_digest() {
    local s="${1:-}" out=""
    if command -v sha256sum >/dev/null 2>&1; then
        out="$(printf '%s' "$s" | sha256sum 2>/dev/null)"
    elif command -v shasum >/dev/null 2>&1; then
        out="$(printf '%s' "$s" | shasum -a 256 2>/dev/null)"
    elif command -v md5sum >/dev/null 2>&1; then
        out="$(printf '%s' "$s" | md5sum 2>/dev/null)"
    elif command -v cksum >/dev/null 2>&1; then
        out="$(printf '%s' "$s" | cksum 2>/dev/null)"
    fi
    out="${out%% *}"
    out="${out//[!A-Za-z0-9]/}"
    [ -n "$out" ] || out="nodigest"
    printf '%s' "${out:0:16}"
}

# run_all_host_id — `<os>|<arch>|<digest-of-hostname>`. Hostname is digested,
# never stored raw. Comparison-only — never display it.
run_all_host_id() {
    local os arch host
    os="$(uname -s 2>/dev/null || printf 'unknown')"
    arch="$(uname -m 2>/dev/null || printf 'unknown')"
    host="${HOSTNAME:-}"
    [ -n "$host" ] || host="$(uname -n 2>/dev/null || printf 'unknown')"
    printf '%s|%s|%s\n' \
        "$(run_all_id_field "$os")" \
        "$(run_all_id_field "$arch")" \
        "$(run_all_id_digest "$host")"
}

# --- corpus bucketing -------------------------------------------------------

# run_all_count_bucket <n> — floor(log2(n)); n=0 and n=1 both map to bucket 0.
run_all_count_bucket() {
    local n="${1:-0}" b=0
    case "$n" in
        ''|*[!0-9]*) printf '0\n'; return 1 ;;
    esac
    n=$((10#$n))
    while [ "$n" -ge 2 ]; do
        n=$((n / 2))
        b=$((b + 1))
    done
    printf '%s\n' "$b"
}

# run_all_corpus_count <dir> — top-level *.sh files only, never recursive, so a
# fixture or archive subdirectory cannot inflate the bucket.
run_all_corpus_count() {
    local dir="${1:-}" f n=0
    if [ -z "$dir" ] || [ ! -d "$dir" ]; then printf '0\n'; return 1; fi
    for f in "$dir"/*.sh; do
        [ -f "$f" ] && n=$((n + 1))
    done
    printf '%s\n' "$n"
}

run_all_corpus_bucket() {
    run_all_count_bucket "$(run_all_corpus_count "${1:-}")"
}

# --- the non-evaluating reader ----------------------------------------------

# run_all_cache_read <file> [<expected-count-bucket>] — success sets
# RUN_ALL_CACHE_JOBS/MEASURED_AT, returns 0; failure sets RUN_ALL_CACHE_REASON
# to one enum token, returns 1. Bucket falls back: arg2 > RUN_ALL_EXPECT_BUCKET > TESTS_DIR corpus > skip.
run_all_cache_read() {
    local file="${1:-}"
    local want_bucket=""
    local line key val nlines seen k
    local v_schema="" v_host_id="" v_count_bucket="" v_jobs=""
    local v_measured_at="" v_sample_size="" v_repeat=""
    # Byte-exact ${#...} regardless of the caller's locale; restored on return.
    local LC_ALL=C LC_CTYPE=C

    RUN_ALL_CACHE_JOBS=""
    RUN_ALL_CACHE_MEASURED_AT=""
    RUN_ALL_CACHE_REASON=""

    if [ "$#" -ge 2 ]; then
        want_bucket="$2"
    elif [ -n "${RUN_ALL_EXPECT_BUCKET:-}" ]; then
        want_bucket="$RUN_ALL_EXPECT_BUCKET"
    elif [ -n "${TESTS_DIR:-}" ] && [ -d "${TESTS_DIR:-}" ]; then
        want_bucket="$(run_all_corpus_bucket "$TESTS_DIR")"
    fi

    if [ -z "$file" ] || [ ! -e "$file" ]; then
        RUN_ALL_CACHE_REASON="missing"; return 1
    fi
    if [ ! -f "$file" ] || [ ! -r "$file" ]; then
        RUN_ALL_CACHE_REASON="unreadable"; return 1
    fi

    nlines=0
    seen=" "
    while IFS= read -r line || [ -n "$line" ]; do
        nlines=$((nlines + 1))
        if [ "$nlines" -gt "$RUN_ALL_CACHE_MAX_LINES" ]; then
            RUN_ALL_CACHE_REASON="malformed"; return 1
        fi
        # Measured on the line as stored, excluding only the newline, so a CRLF
        # file is judged on its real byte count.
        if [ "${#line}" -gt "$RUN_ALL_CACHE_MAX_LINE_BYTES" ]; then
            RUN_ALL_CACHE_REASON="malformed"; return 1
        fi
        line="${line%$'\r'}"
        case "$line" in
            '') continue ;;
            '#'*) continue ;;
            *=*) ;;
            *) RUN_ALL_CACHE_REASON="malformed"; return 1 ;;
        esac
        # Split on the FIRST '=' only. No quote, escape or expansion handling:
        # the value stays opaque text and is matched with globs below.
        key="${line%%=*}"
        val="${line#*=}"
        case "$key" in
            schema|host_id|count_bucket|jobs|measured_at|sample_size|repeat) ;;
            *) RUN_ALL_CACHE_REASON="unknown-key"; return 1 ;;
        esac
        case "$seen" in
            *" $key "*) RUN_ALL_CACHE_REASON="duplicate-key"; return 1 ;;
        esac
        seen="$seen$key "
        case "$key" in
            schema)       v_schema="$val" ;;
            host_id)      v_host_id="$val" ;;
            count_bucket) v_count_bucket="$val" ;;
            jobs)         v_jobs="$val" ;;
            measured_at)  v_measured_at="$val" ;;
            sample_size)  v_sample_size="$val" ;;
            repeat)       v_repeat="$val" ;;
        esac
    done < "$file"

    for k in $RUN_ALL_CACHE_ALLOWED_KEYS; do
        case "$seen" in
            *" $k "*) ;;
            *) RUN_ALL_CACHE_REASON="malformed"; return 1 ;;
        esac
    done

    # Value class + length. `jobs` is excluded here so that every rejection of
    # the payload width reports `bad-jobs` instead of `malformed`.
    case "$v_schema"       in ''|*[!0-9]*) RUN_ALL_CACHE_REASON="malformed"; return 1 ;; esac
    case "$v_count_bucket" in ''|*[!0-9]*) RUN_ALL_CACHE_REASON="malformed"; return 1 ;; esac
    case "$v_sample_size"  in ''|*[!0-9]*) RUN_ALL_CACHE_REASON="malformed"; return 1 ;; esac
    case "$v_repeat"       in ''|*[!0-9]*) RUN_ALL_CACHE_REASON="malformed"; return 1 ;; esac
    case "$v_measured_at"  in ''|*[!0-9TZ:+-]*) RUN_ALL_CACHE_REASON="malformed"; return 1 ;; esac
    if [ "${#v_measured_at}" -gt 24 ]; then
        RUN_ALL_CACHE_REASON="malformed"; return 1
    fi
    case "$v_host_id" in ''|*[!A-Za-z0-9._\|-]*) RUN_ALL_CACHE_REASON="malformed"; return 1 ;; esac
    if [ "${#v_host_id}" -gt 200 ]; then
        RUN_ALL_CACHE_REASON="malformed"; return 1
    fi

    if [ "$v_schema" != "$RUN_ALL_CACHE_SCHEMA" ]; then
        RUN_ALL_CACHE_REASON="schema-mismatch"; return 1
    fi
    # String equality only — host_id is never split on '|' and never displayed.
    if [ "$v_host_id" != "$(run_all_host_id)" ]; then
        RUN_ALL_CACHE_REASON="host-mismatch"; return 1
    fi
    case "$want_bucket" in
        ''|*[!0-9]*) ;;
        *)
            if [ "$((10#$v_count_bucket))" -ne "$((10#$want_bucket))" ]; then
                RUN_ALL_CACHE_REASON="bucket-mismatch"; return 1
            fi ;;
    esac

    case "$v_jobs" in
        ''|*[!0-9]*) RUN_ALL_CACHE_REASON="bad-jobs"; return 1 ;;
    esac
    if [ "${#v_jobs}" -gt 4 ]; then
        RUN_ALL_CACHE_REASON="bad-jobs"; return 1
    fi
    if [ "$((10#$v_jobs))" -lt "$RUN_ALL_CACHE_MIN_JOBS" ] ||
       [ "$((10#$v_jobs))" -gt "$RUN_ALL_CACHE_MAX_JOBS" ]; then
        RUN_ALL_CACHE_REASON="bad-jobs"; return 1
    fi

    RUN_ALL_CACHE_JOBS="$((10#$v_jobs))"
    RUN_ALL_CACHE_MEASURED_AT="$v_measured_at"
    return 0
}
