#!/usr/bin/env bash
# bin/lib/test-heavy-judge.sh — which test files are heavy tests, read from this host's
# duration ledger (bin/lib/run-all-durations.sh, #2932). Source only; Bash 3.2 compatible.

_THJ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/run-all-parallelism.sh
declare -F run_all_cache_dir >/dev/null || . "$_THJ_DIR/run-all-parallelism.sh"
# Guarded: re-sourcing would clear the caller's memoised RUN_ALL_DUR_REPO_ID.
# shellcheck source=bin/lib/run-all-durations.sh
declare -F run_all_dur_segments_into >/dev/null || . "$_THJ_DIR/run-all-durations.sh"

_thj_unknown_rows() {
    local reason="$1" pf="$2" out="$3" p
    printf '#heavy-judge reason=%s host=%s suite_median=- suite_files=0\n' "$reason" "$RUN_ALL_DUR_HOST_TOKEN" >"$out" || return 1
    while IFS= read -r p || [ -n "$p" ]; do
        p="${p%$'\r'}"
        [ -n "$p" ] || continue
        printf '%s\t?\t-\t0\t-\t0\t-\n' "$p"
    done <"$pf" >>"$out"
}

# thj_judge <repo-root> <paths-file> <out-file> — header `#heavy-judge reason=<ok|missing|unreadable>
# host=<tok> suite_median=<s|-> suite_files=<n>`, then per input path, in order, the TSV row
# path, tier (- WARN HARD ?), basis (- median timeout-floor median+timeout-floor), samples, median,
# timeouts, criteria (- abs rel abs+rel). Medians use only (PASS, completed) rows, the newest
# TEST_TIME.samples (newer segment first, later row first); a `timeout` row at or over the HARD
# budget raises to HARD. Limits come from bin/print-size-limits, read only when a segment exists.
thj_judge() {
    local root="${1:-}" pf="${2:-}" out="${3:-}" p paths="" keys="" sep="" lim params cli
    local LC_ALL=C LC_CTYPE=C
    [ -n "$root" ] && [ -n "$pf" ] && [ -n "$out" ] || return 2
    [ -f "$pf" ] || pf=/dev/null
    run_all_dur_repo_id "$root" >/dev/null
    run_all_dur_host_token >/dev/null
    run_all_dur_segments_into "$(run_all_dur_dir)" "$RUN_ALL_DUR_HOST_TOKEN"
    if [ "${#RUN_ALL_DUR_SEGMENTS_OUT[@]}" -eq 0 ]; then
        _thj_unknown_rows missing "$pf" "$out"
        return 0
    fi
    cli="$_THJ_DIR/../print-size-limits"
    command -v cygpath >/dev/null 2>&1 && cli="$(cygpath -m "$cli")"
    if ! lim="$(node "$cli" --get test-time 2>/dev/null)" ||
        ! params="$(node "$cli" --test-time-params 2>/dev/null)"; then
        _thj_unknown_rows unreadable "$pf" "$out"
        return 0
    fi
    while IFS= read -r p || [ -n "$p" ]; do
        p="${p%$'\r'}"
        [ -n "$p" ] || continue
        run_all_dur_key_into "${root%/}/$p" "$root" || RUN_ALL_DUR_KEY_OUT=""
        paths="$paths$sep$p"
        keys="$keys$sep$RUN_ALL_DUR_KEY_OUT"
        sep=$'\n'
    done <"$pf"
    THJ_PATHS="$paths" THJ_KEYS="$keys" THJ_LIM="$lim" THJ_PARAMS="$params" \
        awk -v RID="$RUN_ALL_DUR_REPO_ID" -v TOK="$RUN_ALL_DUR_HOST_TOKEN" \
        -v MAXREC="$RUN_ALL_DUR_MAX_RECORDS" "$RUN_ALL_DUR_AWK_PARSE"'
function merge(   k, i) {
    for (k in fc)
        for (i = fc[k]; i >= 1 && g[k] < N; i--) { g[k]++; gs[k, g[k]] = fb[k, i] }
    split("", fc); split("", fb)
}
function qsort(A, lo, hi,   i, j, p, t) {
    if (lo >= hi) return
    p = A[int((lo + hi) / 2)]; i = lo; j = hi
    while (i <= j) {
        while (A[i] < p) i++
        while (A[j] > p) j--
        if (i <= j) { t = A[i]; A[i] = A[j]; A[j] = t; i++; j-- }
    }
    qsort(A, lo, j); qsort(A, i, hi)
}
function median(A, n) {
    qsort(A, 1, n)
    return (n % 2) ? A[(n + 1) / 2] : int((A[n / 2] + A[n / 2 + 1]) / 2)
}
function join(a, b) { return a != "" && b != "" ? a "+" b : (a b != "" ? a b : "-") }
function param(s, name,   i, n, kv) {
    n = split(s, kv, " ")
    for (i = 1; i <= n; i++) if (index(kv[i], name "=") == 1) return substr(kv[i], length(name) + 2) + 0
    return -1
}
BEGIN {
    split(ENVIRON["THJ_LIM"], lim, " "); W = lim[1] + 0; H = lim[2] + 0
    P = ENVIRON["THJ_PARAMS"]
    N = param(P, "samples"); MINH = param(P, "min_hard")
    RW = param(P, "ratio_warn"); RH = param(P, "ratio_hard")
    FW = param(P, "floor_warn"); FH = param(P, "floor_hard")
    if (W <= 0 || H <= 0 || N < 1 || MINH < 0 || RW < 0 || RH < 0 || FW < 0 || FH < 0) { BAD = 1; exit 3 }
}
{
    if (++nline > MAXREC) exit
    if (FILENAME != pf) { merge(); pf = FILENAME }
    if (substr($0, 1, 1) == "#") next
    if (!dur_parse($0) || P_RID != RID) next
    seen[P_KEY] = 1
    if (P_TERM == "timeout" && P_SECS + 0 >= H) to[P_KEY]++
    if (P_VERDICT == "PASS" && P_TERM == "completed") { fc[P_KEY]++; fb[P_KEY, fc[P_KEY]] = P_SECS + 0 }
}
END {
    if (BAD) exit 3
    merge()
    nf = 0
    for (k in g) {
        split("", v)
        for (i = 1; i <= g[k]; i++) v[i] = gs[k, i]
        med[k] = median(v, g[k])
        all[++nf] = med[k]
    }
    SM = nf > 0 ? median(all, nf) : ""
    printf "#heavy-judge reason=ok host=%s suite_median=%s suite_files=%d\n", TOK, (nf > 0 ? SM : "-"), nf
    np = split(ENVIRON["THJ_PATHS"], path, "\n"); split(ENVIRON["THJ_KEYS"], key, "\n")
    for (i = 1; i <= np; i++) {
        k = key[i]
        if (k == "" || !(k in seen)) { printf "%s\t?\t-\t0\t-\t0\t-\n", path[i]; continue }
        n = g[k] + 0; t = to[k] + 0; tier = "-"; crit = "-"; m = "-"
        if (n > 0) {
            m = med[k]
            aw = m > W ? "abs" : ""; ah = m > H ? "abs" : ""
            rw = (SM != "" && m > SM * RW && m > FW) ? "rel" : ""
            rh = (SM != "" && m > SM * RH && m > FH) ? "rel" : ""
            if (ah rh != "" && n >= MINH) { tier = "HARD"; crit = join(ah, rh) }
            else if (aw rw != "") { tier = "WARN"; crit = join(aw, rw) }
        }
        basis = tier == "-" ? "" : "median"
        if (t > 0) { tier = "HARD"; basis = basis == "" ? "timeout-floor" : basis "+timeout-floor" }
        printf "%s\t%s\t%s\t%d\t%s\t%d\t%s\n", path[i], tier, (basis == "" ? "-" : basis), n, m, t, crit
    }
}' "${RUN_ALL_DUR_SEGMENTS_OUT[@]}" >"$out" 2>/dev/null || _thj_unknown_rows unreadable "$pf" "$out"
    return 0
}

# thj_report <repo-root> <paths-file> — the `--heavy` inventory of bin/audit-tests*.sh: thj_judge's
# header, then its rows HARD first, then WARN, then the rest, each tier by median descending.
thj_report() {
    local out rc=0 tab=$'\t'
    out="$(mktemp)" || return 2
    thj_judge "${1:-}" "${2:-}" "$out" || rc=$?
    if [ "$rc" -eq 0 ]; then
        head -n 1 "$out"
        tail -n +2 "$out" | awk -F'\t' -v OFS='\t' '{
            r = $2 == "HARD" ? 0 : ($2 == "WARN" ? 1 : ($2 == "-" ? 2 : 3))
            print r, ($5 ~ /^[0-9]+$/ ? $5 : -1), $0 }' |
            LC_ALL=C sort -t "$tab" -k1,1n -k2,2nr -k3,3 | cut -f3-
    fi
    rm -f "$out"
    return "$rc"
}

# thj_audit_heavy <repo-root> — thj_report over every direct test file of the test dirs, the
# runner excluded; needs the caller's tdg_use_root (bin/lib/test-dup-group.sh) already run.
thj_audit_heavy() {
    local pf d f rc=0
    pf="$(mktemp)" || return 2
    for d in ${_TDG_TEST_DIRS[@]+"${_TDG_TEST_DIRS[@]}"}; do
        tlr_list_dir_into "$d" supported || continue
        for f in ${TLR_LIST[@]+"${TLR_LIST[@]}"}; do tdg_is_runner "$f" || printf '%s\n' "$f"; done
    done >"$pf"
    thj_report "${1:-.}" "$pf" || rc=$?
    rm -f "$pf"
    return "$rc"
}

# thj_mode_guard <explicit-apply> <fix-headers> <format> <dup-groups> — `--heavy` is read-only TSV
# and its own mode: rc 1 (message on stderr) when combined with any of them.
thj_mode_guard() {
    local why=""
    [ "${1:-0}" -eq 1 ] && why="--apply is not applicable (read-only)"
    [ "${2:-0}" -eq 1 ] && why="--fix-headers is a separate mode"
    [ "${3:-text}" = json ] && why="--format json is not supported (TSV only)"
    [ "${4:-0}" -eq 1 ] && why="--dup-groups is a separate mode"
    [ -z "$why" ] && return 0
    echo "ERROR: --heavy: $why" >&2
    return 1
}

# thj_dispatcher_of <path> [<repo-root>] — the top-level test file run-all runs for <path>: a
# fragment `<dir>/<stem>/.../x` maps to `<dir>/<stem>.<ext>` when that file is a registered test
# of stem <stem> (the outermost wins); anything else passes through. The ledger measures only these.
thj_dispatcher_of() {
    local p="${1:-}" root="${2:-.}" d name parent cand b found=""
    d="${p%/*}"
    if [ "$d" != "$p" ] && { declare -F tlr_load >/dev/null || . "$_THJ_DIR/test-language-registry.sh"; } && tlr_load; then
        while [ -n "$d" ] && [ "$d" != "." ]; do
            name="${d##*/}"
            parent=""; [ "$d" != "$name" ] && parent="${d%/*}/"
            for cand in "$root/$parent$name".*; do
                [ -f "$cand" ] || continue
                b="${cand##*/}"
                tlr_match "$b" || continue
                _tlr_stem_set "$b"
                [ "$TLR_STEM" = "$name" ] && { found="$parent$b"; break; }
            done
            [ -n "$parent" ] || break
            d="${parent%/}"
        done
    fi
    printf '%s\n' "${found:-$p}"
}
