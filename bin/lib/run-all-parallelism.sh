#!/usr/bin/env bash
# SSOT for the run-all parallelism cache. Sourced by tests/run-all.sh and
# bin/calibrate-test-parallelism.sh; defines constants/functions only.
# Cache values are compared as strings only — never expanded, never used in arithmetic.
# Sibling bin/lib/run-all-durations.sh (the duration ledger) reuses the helpers below, so it requires this file to be sourced first.
# The never-ask record (calibration-never-ask.conf) format is owned here; run_all_never_ask_write is its only writer.
# shellcheck disable=SC2034  # constants and reader outputs are consumed by the sourcing scripts

RUN_ALL_CACHE_SCHEMA=2
RUN_ALL_DEFAULT_MAX_JOBS_PER_RUN=4
RUN_ALL_DEFAULT_MAX_JOBS_PER_HOST=4
RUN_ALL_CALIBRATOR_HINT="RUN_CALIBRATION=1 bash bin/calibrate-test-parallelism.sh"

RUN_ALL_CACHE_BASENAME="parallelism.conf"
RUN_ALL_CALIBRATION_TIME_LIMIT_MIN=90
RUN_ALL_NEVER_ASK_BASENAME="calibration-never-ask.conf"
RUN_ALL_NEVER_ASK_MAX_LINES=8
RUN_ALL_CACHE_MAX_LINES=64
RUN_ALL_CACHE_MAX_LINE_BYTES=512
RUN_ALL_CACHE_MIN_JOBS=1
RUN_ALL_CACHE_MAX_JOBS=1024
RUN_ALL_CACHE_ALLOWED_KEYS="schema host_id os max_jobs_per_host measured_at sample_size repeat"

# Outputs of run_all_cache_read; declared so a `set -u` caller may read them
# unconditionally after a failed call.
RUN_ALL_CACHE_MAX_JOBS_PER_HOST=""
RUN_ALL_CACHE_OS=""
RUN_ALL_CACHE_MEASURED_AT=""
RUN_ALL_CACHE_REASON=""
_RUN_ALL_RAW_OS=""
_RUN_ALL_ARCH=""
_RUN_ALL_HOST_ID=""
_RUN_ALL_OS_ATTR=""

# --- locations --------------------------------------------------------------

run_all_cache_dir() {
    printf '%s\n' "${RUN_ALL_CACHE_DIR:-${HOME:-.}/.claude/run-all}"
}

run_all_cache_file() {
    printf '%s\n' "$(run_all_cache_dir)/$RUN_ALL_CACHE_BASENAME"
}

run_all_never_ask_file() {
    printf '%s/%s\n' "$(run_all_cache_dir)" "$RUN_ALL_NEVER_ASK_BASENAME"
}

# run_all_never_ask_active — 0 when the never-ask record holds exactly one non-empty
# host_id (<= 200 chars) equal to this host's; schema=, recorded_at= and unknown keys are ignored.
run_all_never_ask_active() {
    local file line nlines=0 hits=0 hid=""
    local LC_ALL=C LC_CTYPE=C
    file="$(run_all_never_ask_file)"
    [ -f "$file" ] && [ -r "$file" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        nlines=$((nlines + 1))
        [ "$nlines" -le "$RUN_ALL_NEVER_ASK_MAX_LINES" ] || return 1
        line="${line%$'\r'}"
        [ "${#line}" -le "$RUN_ALL_CACHE_MAX_LINE_BYTES" ] || return 1
        case "$line" in
            host_id=*) hits=$((hits + 1)); hid="${line#host_id=}" ;;
        esac
    done < "$file"
    [ "$hits" -eq 1 ] && [ -n "$hid" ] && [ "${#hid}" -le 200 ] || return 1
    [ "$hid" = "$(run_all_host_id)" ]
}

# run_all_never_ask_write — publish the never-ask record for this host (tmp + mv).
run_all_never_ask_write() {
    local dir file tmp
    dir="$(run_all_cache_dir)"
    file="$(run_all_never_ask_file)"
    tmp="$file.$$.tmp"
    mkdir -p "$dir" 2>/dev/null || return 1
    if { printf 'schema=1\nhost_id=%s\nrecorded_at=%s\n' "$(run_all_host_id)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp"; } 2>/dev/null &&
        mv -f "$tmp" "$file" 2>/dev/null; then
        return 0
    fi
    rm -f "$tmp" 2>/dev/null
    return 1
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

# run_all_host_id_compose <os-field> <arch> <host-digest> — the one owner of the
# identity format. Takes the OS field verbatim (no Windows mapping), so the
# migration module can rebuild a pre-#2079 identity from a raw `uname -s`.
run_all_host_id_compose() {
    printf '%s|%s|%s\n' "$(run_all_id_field "${1:-}")" "$(run_all_id_field "${2:-}")" "$(run_all_id_field "${3:-}")"
}

# _run_all_host_facts — one `uname -s` yields both the key and the OS attribute.
# Sets _RUN_ALL_RAW_OS, _RUN_ALL_ARCH, _RUN_ALL_HOST_ID, _RUN_ALL_OS_ATTR.
# Windows drops launch path and build from the key (#2079 S6); the build lives
# in the attribute instead, because `uname -r` there is the msys runtime version.
_run_all_host_facts() {
    local host fam ver
    _RUN_ALL_RAW_OS="$(uname -s 2>/dev/null)" || _RUN_ALL_RAW_OS=""
    [ -n "$_RUN_ALL_RAW_OS" ] || _RUN_ALL_RAW_OS="unknown"
    _RUN_ALL_ARCH="$(uname -m 2>/dev/null)" || _RUN_ALL_ARCH="unknown"
    host="${HOSTNAME:-}"
    [ -n "$host" ] || host="$(uname -n 2>/dev/null || printf 'unknown')"
    case "$_RUN_ALL_RAW_OS" in
        *_NT-*) fam="Windows"; ver="${_RUN_ALL_RAW_OS#*_NT-}"; ver="${ver/-/.}" ;;
        *) fam="$_RUN_ALL_RAW_OS"; ver="$(uname -r 2>/dev/null)" || ver="" ;;
    esac
    _RUN_ALL_HOST_ID="$(run_all_host_id_compose "$fam" "$_RUN_ALL_ARCH" "$(run_all_id_digest "$host")")"
    fam="$(run_all_id_field "$fam")"; ver="$(run_all_id_field "$ver")"
    _RUN_ALL_OS_ATTR="${fam:0:32}/${ver:0:64}"
}

# run_all_host_id — `<os>|<arch>|<digest-of-hostname>`. Hostname is digested,
# never stored raw. Comparison-only — never display it.
run_all_host_id() {
    _run_all_host_facts
    printf '%s\n' "$_RUN_ALL_HOST_ID"
}

# run_all_os_attr — `<family>/<version>` (e.g. Windows/10.0.26300), display-only.
run_all_os_attr() {
    _run_all_host_facts
    printf '%s\n' "$_RUN_ALL_OS_ATTR"
}

# The attribute shape both ledgers validate; awk lacks portable {m,n}, so the
# length bounds are checked separately wherever this class is used.
# shellcheck disable=SC2034  # read by the sourcing ledger code
RUN_ALL_OS_ATTR_CLASS='^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'

# --- the non-evaluating reader ----------------------------------------------

# run_all_cache_read <file> — success sets RUN_ALL_CACHE_MAX_JOBS_PER_HOST/OS/
# MEASURED_AT, returns 0; failure sets RUN_ALL_CACHE_REASON to one enum token, returns 1.
run_all_cache_read() {
    local file="${1:-}"
    local line key val nlines seen k unknown=0
    local v_schema="" v_host_id="" v_os="" v_max=""
    local v_measured_at="" v_sample_size="" v_repeat=""
    # Byte-exact ${#...} regardless of the caller's locale; restored on return.
    local LC_ALL=C LC_CTYPE=C

    RUN_ALL_CACHE_MAX_JOBS_PER_HOST=""
    RUN_ALL_CACHE_OS=""
    RUN_ALL_CACHE_MEASURED_AT=""
    RUN_ALL_CACHE_REASON=""

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
            schema|host_id|os|max_jobs_per_host|measured_at|sample_size|repeat) ;;
            *) unknown=1; continue ;;
        esac
        case "$seen" in
            *" $key "*) RUN_ALL_CACHE_REASON="duplicate-key"; return 1 ;;
        esac
        seen="$seen$key "
        case "$key" in
            schema)            v_schema="$val" ;;
            host_id)           v_host_id="$val" ;;
            os)                v_os="$val" ;;
            max_jobs_per_host) v_max="$val" ;;
            measured_at)       v_measured_at="$val" ;;
            sample_size)       v_sample_size="$val" ;;
            repeat)            v_repeat="$val" ;;
        esac
    done < "$file"

    # An older schema is named as such even though its keys are unknown to this one.
    case "$v_schema" in
        ''|*[!0-9]*) ;;
        *) [ "$v_schema" = "$RUN_ALL_CACHE_SCHEMA" ] || { RUN_ALL_CACHE_REASON="schema-mismatch"; return 1; } ;;
    esac
    if [ "$unknown" -eq 1 ]; then
        RUN_ALL_CACHE_REASON="unknown-key"; return 1
    fi
    # `os` is left to its own check below, so an absent one reports `bad-os`.
    for k in $RUN_ALL_CACHE_ALLOWED_KEYS; do
        [ "$k" = os ] && continue
        case "$seen" in
            *" $k "*) ;;
            *) RUN_ALL_CACHE_REASON="malformed"; return 1 ;;
        esac
    done

    # Value class + length. `os` and `max_jobs_per_host` are excluded here so that
    # their rejections report their own tokens instead of `malformed`.
    case "$v_schema"       in ''|*[!0-9]*) RUN_ALL_CACHE_REASON="malformed"; return 1 ;; esac
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
    # `os` is the one value ever displayed, so its shape is checked before use.
    if [[ ! $v_os =~ ^[A-Za-z0-9._-]{1,32}/[A-Za-z0-9._-]{1,64}$ ]]; then
        RUN_ALL_CACHE_REASON="bad-os"; return 1
    fi
    if ! run_all_valid_max_jobs "$v_max"; then
        RUN_ALL_CACHE_REASON="bad-max-jobs-per-host"; return 1
    fi

    RUN_ALL_CACHE_MAX_JOBS_PER_HOST="$((10#$v_max))"
    RUN_ALL_CACHE_OS="$v_os"
    RUN_ALL_CACHE_MEASURED_AT="$v_measured_at"
    return 0
}

# run_all_valid_max_jobs <value> — true for a plain integer in 1..1024 (no sign, at most 4 digits).
run_all_valid_max_jobs() {
    [[ ${1:-} =~ ^[0-9]{1,4}$ ]] || return 1
    [ "$((10#$1))" -ge "$RUN_ALL_CACHE_MIN_JOBS" ] && [ "$((10#$1))" -le "$RUN_ALL_CACHE_MAX_JOBS" ]
}

# --- .env layer -------------------------------------------------------------

# run_all_dotenv_value <NAME> — the .env value of NAME into RUN_ALL_DOTENV_VALUE,
# empty when unset or when the resolver is absent. The process env copy is
# unset for the lookup because get-config-var lets it win over .env.
RUN_ALL_DOTENV_VALUE=""
run_all_dotenv_value() {
    local name="${1:?}" self="${BASH_SOURCE[0]}" cmd
    case "$self" in */*) self="${self%/*}" ;; *) self="." ;; esac
    cmd="${RUN_ALL_CONFIG_VAR_CMD:-$self/../get-config-var}"
    RUN_ALL_DOTENV_VALUE=""
    [ -f "$cmd" ] && [ -x "$cmd" ] || return 0
    RUN_ALL_DOTENV_VALUE="$( (unset "$name"; "$cmd" "$name") 2>/dev/null)" || RUN_ALL_DOTENV_VALUE=""
    return 0
}

# --- max jobs per run -------------------------------------------------------

# run_all_resolve_max_jobs_per_run — the .env TEST_MAX_JOBS_PER_RUN layer behind
# an unset / `auto` command line and env. Read-only. Sets RUN_ALL_MAX_JOBS_PER_RUN
# and the RUN_ALL_RESOLVE_NOTE progress line; returns 1 on an invalid .env value,
# whose note never echoes that value.
RUN_ALL_MAX_JOBS_PER_RUN=""
RUN_ALL_RESOLVE_NOTE=""
run_all_resolve_max_jobs_per_run() {
    run_all_dotenv_value TEST_MAX_JOBS_PER_RUN
    RUN_ALL_MAX_JOBS_PER_RUN="$RUN_ALL_DEFAULT_MAX_JOBS_PER_RUN"
    case "$RUN_ALL_DOTENV_VALUE" in
        ''|auto)
            RUN_ALL_RESOLVE_NOTE="max jobs per run: $RUN_ALL_MAX_JOBS_PER_RUN (default)"; return 0 ;;
    esac
    if run_all_valid_max_jobs "$RUN_ALL_DOTENV_VALUE"; then
        RUN_ALL_MAX_JOBS_PER_RUN="$((10#$RUN_ALL_DOTENV_VALUE))"
        RUN_ALL_RESOLVE_NOTE="max jobs per run: $RUN_ALL_MAX_JOBS_PER_RUN (.env)"; return 0
    fi
    # shellcheck disable=SC2034  # read by tests/run-all.sh's resolve_jobs
    RUN_ALL_RESOLVE_NOTE="TEST_MAX_JOBS_PER_RUN in .env must be an integer 1-1024 or auto"
    return 1
}
