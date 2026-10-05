#!/usr/bin/env bash
# tests/tests/feature-1832-run-all-parallel/_cal-fixture.sh — calibrator fixture (SOURCE ONLY).
# Tests: bin/calibrate-test-parallelism.sh
# Tags: tests, bin, parallel, calibrator, fixture, scope:issue-specific
# WHY (#2079 S5): the calibrator samples from the duration ledger, so its tests need a
# 2-level corpus, a synthetic ledger in a throwaway "real area", and a recording seam stub.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "SKIP: _cal-fixture.sh is a sourceable library, not a test" >&2
    exit 77
fi

# API: cf_init; cf_new_suite / cf_new_real; cf_add <suite> <cat/name> [serial];
# cf_populate <suite> <real|-> <cat/prefix> <count> <secs> [noledger|serial];
# cf_ledger_raw <real> <suite> <file "<cat/name>\t<secs>">; cf_stub [ms-spec]; cf_stub_drift;
# cf_run <suite> <real> <stub|-> <args...> (sets CF_RC CF_OUT CF_ERR); cf_calls <stub> [phase];
# cf_call_field <stub> <n> <col> (1 n, 2 phase, 3 width, 4 deadline, 5 cache dir, 6 count);
# cf_call_nums <stub> <phase>; cf_keys <stub> <n>; cf_key_of <suite> <cat/name>;
# cf_inconclusive <token>; cf_selected; cf_lane_holder <real> alive|stale; cf_tree_sig <dir>.
CF_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CF_CAL="$CF_REPO/bin/calibrate-test-parallelism.sh"
CF_LIB_PAR="$CF_REPO/bin/lib/run-all-parallelism.sh"
CF_LIB_DUR="$CF_REPO/bin/lib/run-all-durations.sh"
CF_T=""
CF_RC=0
CF_OUT=""
CF_ERR=""

cf_cleanup() { [ -n "$CF_T" ] && rm -rf "$CF_T"; return 0; }

# cf_init — pins or drops every config-dependent variable (real cache, real .env, lanes).
cf_init() {
    local d
    d="$(mktemp -d 2>/dev/null || mktemp -d -t calfx)" || { echo "SKIP: mktemp unavailable" >&2; exit 77; }
    CF_T="$(cd "$d" && pwd -P)"
    mkdir -p "$CF_T/workflow" "$CF_T/plans" "$CF_T/home-cache"
    export CLAUDE_WORKFLOW_DIR="$CF_T/workflow"
    export WORKFLOW_PLANS_DIR="$CF_T/plans"
    unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
    unset TEST_LANES TEST_LANES_HELD TEST_LANES_BUDGET TEST_MAX_JOBS_PER_HOST TEST_MAX_JOBS_PER_RUN \
          RUN_ALL_JOBS RUN_ALL_DEADLINE RUN_ALL_PROGRESS RUN_ALL_LANES_LIB RUN_ALL_DURATIONS_LIB \
          RUN_ALL_CALIBRATION_MEASURE_CMD RUN_CALIBRATION TESTS_DIR 2>/dev/null || true
    export RUN_ALL_CONFIG_VAR_CMD="$CF_T/no-such-config-resolver"
    export RUN_ALL_CACHE_DIR="$CF_T/home-cache"
    trap cf_cleanup EXIT
}

cf_new_suite() {
    local d
    d="$(mktemp -d "$CF_T/suite.XXXXXX")" || return 1
    mkdir -p "$d/bin" "$d/hooks"
    : > "$d.truth.tsv"
    printf '%s' "$d"
}

cf_new_real() {
    local d
    d="$(mktemp -d "$CF_T/real.XXXXXX")" || return 1
    printf '%s' "$d"
}

# cf_add <suite> <cat/name> [serial]
cf_add() {
    local f="$1/$2.sh"
    mkdir -p "${f%/*}"
    {
        printf '#!/usr/bin/env bash\n'
        printf '# Tests: tests/run-all.sh\n'
        [ "${3:-}" = "serial" ] && printf '# Serial: calibrator fixture\n'
        printf 'exit 0\n'
    } > "$f"
}

# cf_key_of <suite> <cat/name> — the key the real library derives (root = this repo).
cf_key_of() {
    env "TESTS_DIR=$1" bash -c '. "$1" >/dev/null 2>&1; . "$2" >/dev/null 2>&1
        run_all_dur_key_into "$3" "$4" && printf "%s\n" "$RUN_ALL_DUR_KEY_OUT"' \
        _ "$CF_LIB_PAR" "$CF_LIB_DUR" "$1/$2.sh" "$CF_REPO"
}

# cf_ledger_raw <real> <suite> <file> — one segment via the real writer (real token + repo id).
cf_ledger_raw() {
    env "RUN_ALL_CACHE_DIR=$1" "TESTS_DIR=$2" bash -c '
        . "$1" >/dev/null 2>&1; . "$2" >/dev/null 2>&1
        run_all_dur_writer_init "$3"
        while IFS="	" read -r rel secs; do
            [ -n "$rel" ] || continue
            run_all_dur_key_into "$4/$rel.sh" "$3" || continue
            run_all_dur_append "$RUN_ALL_DUR_KEY_OUT" "$secs"
        done < "$5"' _ "$CF_LIB_PAR" "$CF_LIB_DUR" "$CF_REPO" "$2" "$3"
}

# cf_populate — dummies, their truth (<suite>.truth.tsv: what the stub "measures"), and,
# unless noledger, one real-area ledger segment carrying the same seconds.
cf_populate() {
    local suite="$1" real="$2" pre="$3" count="$4" secs="$5" mode="${6:-}" i rel lf
    lf="$CF_T/ledger.$RANDOM$RANDOM.tsv"
    : > "$lf"
    i=1
    while [ "$i" -le "$count" ]; do
        rel="$(printf '%s%02d' "$pre" "$i")"
        if [ "$mode" = "serial" ]; then cf_add "$suite" "$rel" serial; else cf_add "$suite" "$rel"; fi
        printf '%s\t%s\n' "$rel" "$secs" >> "$lf"
        i=$((i + 1))
    done
    env "TESTS_DIR=$suite" bash -c '. "$1" >/dev/null 2>&1; . "$2" >/dev/null 2>&1
        while IFS="	" read -r rel secs; do
            run_all_dur_key_into "$4/$rel.sh" "$3" && printf "%s\t%s\n" "$RUN_ALL_DUR_KEY_OUT" "$secs"
        done < "$5"' _ "$CF_LIB_PAR" "$CF_LIB_DUR" "$CF_REPO" "$suite" "$lf" >> "$suite.truth.tsv"
    if [ "$mode" != "noledger" ] && [ "$real" != "-" ]; then
        cf_ledger_raw "$real" "$suite" "$lf"
    fi
    rm -f "$lf"
}

# SEAM (#2079 S3): measure.sh <width> <list> <deadline> <probe|warmup|measure>; stdout = ms, then
# optional rc= / width= / unfinished=. Controls in the stub dir, <sel> = call.<N> | <phase>.<K>:
# <sel>.secs "@<idx>\t<v>" or "<key>\t<v>" (v secs, "-" unrecorded, "~" never submitted);
# <sel>.extra raw stdout lines; force_width; noseg (no segment written).
# cf_stub [spec] — spec "<w>:<ms>,<ms>"; Nth call at a width gets the Nth value (last repeats),
# default 1000 ms. Unknown tests "measure" 6 s. calls.log: n phase width deadline cache count.
cf_stub() {
    local d
    d="$(mktemp -d "$CF_T/stub.XXXXXX")" || return 1
    mkdir -p "$d/state"
    printf '%s\n' "${1:-}" > "$d/spec"
    : > "$d/calls.log"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'D=%q\nREPO=%q\nLIBP=%q\nLIBD=%q\n' "$d" "$CF_REPO" "$CF_LIB_PAR" "$CF_LIB_DUR"
        cat <<'STUB'
w="${1:-}"; list="${2:-}"; dl="${3:-}"; ph="${4:-}"
n=$(( $(cat "$D/n" 2>/dev/null || echo 0) + 1 )); printf '%s\n' "$n" > "$D/n"
k=$(( $(cat "$D/state/ph.$ph" 2>/dev/null || echo 0) + 1 )); printf '%s\n' "$k" > "$D/state/ph.$ph"
cnt=0; [ -f "$list" ] && cnt=$(grep -c . "$list")
printf '%s %s %s %s %s %s\n' "$n" "$ph" "$w" "$dl" "${RUN_ALL_CACHE_DIR:-unset}" "$cnt" >> "$D/calls.log"
[ -f "$list" ] && cp "$list" "$D/call.$n.list"
ov=""; for f in "$D/call.$n.secs" "$D/$ph.$k.secs"; do [ -f "$f" ] && ov="$f"; done
ex=""; for f in "$D/call.$n.extra" "$D/$ph.$k.extra"; do [ -f "$f" ] && ex="$f"; done
unf=""
if [ -f "$list" ]; then
    . "$LIBP" >/dev/null 2>&1; . "$LIBD" >/dev/null 2>&1
    [ -f "$D/noseg" ] || run_all_dur_writer_init "$REPO"
    i=0
    while IFS= read -r p || [ -n "$p" ]; do
        p="${p%$'\r'}"; [ -n "$p" ] || continue
        i=$((i + 1)); q="$p"
        case "$q" in /*|[A-Za-z]:*) ;; *) [ -e "${TESTS_DIR:-}/$q" ] && q="$TESTS_DIR/$q" ;; esac
        run_all_dur_key_into "$q" "$REPO" || continue
        key="$RUN_ALL_DUR_KEY_OUT"; printf '%s\n' "$key" >> "$D/call.$n.keys"
        v="$(awk -F'\t' -v k="$key" '$1 == k { v = $2 } END { print v }' "${TESTS_DIR:-/nonexistent}.truth.tsv" 2>/dev/null)"
        [ -n "$v" ] || v=6
        if [ -n "$ov" ]; then
            o="$(awk -F'\t' -v k="$key" -v i="@$i" '$1 == k || $1 == i { v = $2 } END { print v }' "$ov")"
            [ -n "$o" ] && { v="$o"; printf '%s\n' "$key" >> "$D/call.$n.overridden"; }
        fi
        case "$v" in
            -) unf="$unf$p"$'\n' ;;
            '~') : ;;
            *) [ -f "$D/noseg" ] || run_all_dur_append "$key" "$v" ;;
        esac
    done < "$list"
fi
ms=1000
for grp in $(cat "$D/spec"); do
    case "$grp" in "$w":*)
        IFS=',' read -r -a arr <<< "${grp#*:}"
        c=$(( $(cat "$D/state/w.$w" 2>/dev/null || echo 0) + 1 )); printf '%s\n' "$c" > "$D/state/w.$w"
        j=$((c - 1)); [ "$j" -ge "${#arr[@]}" ] && j=$(( ${#arr[@]} - 1 ))
        ms="${arr[$j]}" ;;
    esac
done
printf '%s\n' "$ms"
[ -f "$D/force_width" ] && printf 'width=%s\n' "$(cat "$D/force_width")"
[ -n "$ex" ] && cat "$ex"
if [ -n "$unf" ]; then printf '%s' "$unf" | while IFS= read -r p; do printf 'unfinished=%s\n' "$p"; done; fi
exit 0
STUB
    } > "$d/measure.sh"
    chmod +x "$d/measure.sh" 2>/dev/null || true
    printf '%s' "$d"
}

# cf_stub_drift <base-ms> <step-ms> — elapsed grows with the GLOBAL call index only.
cf_stub_drift() {
    local d
    d="$(mktemp -d "$CF_T/stub.XXXXXX")" || return 1
    : > "$d/calls.log"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'D=%q\nB=%q\nS=%q\n' "$d" "$1" "$2"
        cat <<'STUB'
n=$(( $(cat "$D/n" 2>/dev/null || echo 0) + 1 )); printf '%s\n' "$n" > "$D/n"
printf '%s %s %s %s %s %s\n' "$n" "${4:-}" "${1:-}" "${3:-}" "${RUN_ALL_CACHE_DIR:-unset}" 0 >> "$D/calls.log"
printf '%s\n' "$(( B + S * (n - 1) ))"
STUB
    } > "$d/measure.sh"
    printf '%s' "$d"
}

# cf_run <suite> <real> <stub|-> <args...> — RUN_CALIBRATION=1 unless CF_NO_OPTIN=1.
cf_run() {
    local suite="$1" real="$2" stub="$3"; shift 3
    local -a e=("RUN_ALL_CACHE_DIR=$real" "TESTS_DIR=$suite" "RUN_ALL_CONFIG_VAR_CMD=$CF_T/no-such-config-resolver")
    [ "${CF_NO_OPTIN:-0}" = "1" ] || e+=("RUN_CALIBRATION=1")
    [ "$stub" = "-" ] || e+=("RUN_ALL_CALIBRATION_MEASURE_CMD=$stub/measure.sh")
    CF_RC=0
    CF_OUT="$(bash "$CF_REPO/bin/run-with-timeout.sh" "${CF_TIMEOUT:-120}" env "${e[@]}" \
        bash "$CF_CAL" "$@" 2>"$CF_T/cal.err")" || CF_RC=$?
    CF_ERR="$(cat "$CF_T/cal.err" 2>/dev/null)"
}

cf_calls() {
    if [ -n "${2:-}" ]; then
        awk -v p="$2" '$2 == p { c++ } END { print c + 0 }' "$1/calls.log" 2>/dev/null || echo 0
    else
        awk 'END { print NR + 0 }' "$1/calls.log" 2>/dev/null || echo 0
    fi
}

# ck <name> <want> <got> — needs the caller's pass/fail (tests/lib/harness.sh).
ck() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=$(printf '%q' "$2") got=$(printf '%q' "$3")"; fi; }

cf_call_field() { awk -v n="$2" -v c="$3" '$1 == n { print $c }' "$1/calls.log" 2>/dev/null; }
cf_call_nums() { awk -v p="$2" '$2 == p { print $1 }' "$1/calls.log" 2>/dev/null; }
cf_keys() { cat "$1/call.$2.keys" 2>/dev/null; return 0; }

cf_inconclusive() {
    [ "$CF_RC" = "5" ] || return 1
    printf '%s\n' "$CF_ERR" | grep -qE "^calibrate: inconclusive: $1([^a-z-]|\$)"
}

cf_selected() {
    printf '%s\n%s\n' "$CF_OUT" "$CF_ERR" | sed -n 's/.*calibrate: selected max jobs per host \([0-9][0-9]*\) .*/\1/p' | tail -n 1
}

# cf_lane_holder <real> alive|stale — the owner/hb format bin/lib/test-host-lanes.sh reads.
cf_lane_holder() {
    local d="$1/slots/lane.1" now pid
    mkdir -p "$d"
    now="$(date +%s)"
    if [ "$2" = "alive" ]; then pid="$$"; else pid=999999999; fi
    printf 'pid=%s\nenv=%s\nkind=run-all\nstart=%s\ntoken=1.2.3\n' "$pid" "${OSTYPE:-}" "$now" > "$d/owner"
    printf '%s\n' "$now" > "$d/hb"
}

cf_tree_sig() {
    [ -d "$1" ] || { echo "absent"; return 0; }
    (cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done)
}
