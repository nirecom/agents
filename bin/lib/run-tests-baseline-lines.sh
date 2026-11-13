#!/usr/bin/env bash
# Content-addressed row files of the baseline ledger (#2956 S7). Source-only; sourced by
# run-tests-baseline-ledger.sh (rtb_ledger_dir). A row file holds one side's failure-line body
# (run-tests-baseline-lines.js: `records=cases|none`, then sorted `<case>\t<normalized line>` rows)
# at $(rtb_ledger_dir)/v3.lines.<fp>, where fp = sha256(file). Every read re-hashes the file, so
# a missing or mismatched file is a miss (the caller re-runs); a reuse touches it against the sweep.

case "${BASH_SOURCE[0]}" in
  */*) RTB_LINES_LIB_DIR="${BASH_SOURCE[0]%/*}" ;;
  *)   RTB_LINES_LIB_DIR="." ;;
esac
RTB_LINES_JS="$RTB_LINES_LIB_DIR/run-tests-baseline-lines.js"

rtb_ledger_valid_fp() {
    [[ "${1:-}" =~ ^[0-9a-f]{64}$ ]]
}

# rtb_ledger_sha256 <file> — prints the file's sha256 (lowercase hex) or fails.
rtb_ledger_sha256() {
    local s
    if command -v sha256sum >/dev/null 2>&1; then
        s="$(sha256sum "$1" 2>/dev/null)" || return 1
    else
        s="$(shasum -a 256 "$1" 2>/dev/null)" || return 1
    fi
    s="${s#\\}"
    s="${s%% *}"
    rtb_ledger_valid_fp "$s" || return 1
    printf '%s' "$s"
}

# rtb_ledger_lines_put <fp> <src> — stores <src> as the row file for <fp> when sha256(<src>) = <fp>.
# Written to a per-process tmp name and renamed, so concurrent writers leave one whole file.
rtb_ledger_lines_put() {
    local fp="${1:-}" src="${2:-}" dir dst tmp
    rtb_ledger_valid_fp "$fp" && [[ -f "$src" ]] || return 1
    dir="$(rtb_ledger_dir)"
    mkdir -p "$dir" 2>/dev/null || return 1
    dst="$dir/v3.lines.$fp"
    if [[ -f "$dst" && "$(rtb_ledger_sha256 "$dst")" == "$fp" ]]; then
        touch "$dst" 2>/dev/null || true
        return 0
    fi
    tmp="$dst.tmp.$$"
    if ! cp "$src" "$tmp" 2>/dev/null || [[ "$(rtb_ledger_sha256 "$tmp")" != "$fp" ]]; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv -f "$tmp" "$dst" 2>/dev/null; then
        # Another writer may hold the name (Windows): its copy counts only when it verifies.
        rm -f "$tmp"
        [[ "$(rtb_ledger_sha256 "$dst")" == "$fp" ]] || return 1
    fi
    # A file this run had to (re)write proves nothing about an earlier base run (see rtb_ledger_lines_fresh).
    [[ -z "${RTB_LINES_WRITTEN_LOG:-}" ]] || printf '%s\n' "$fp" >>"$RTB_LINES_WRITTEN_LOG" 2>/dev/null || true
    return 0
}

# rtb_ledger_lines_fresh <fp> — 0 when this run wrote the row file for <fp> itself (it was missing or
# broken before), so a ledger row pointing at it is a miss. Needs RTB_LINES_WRITTEN_LOG.
rtb_ledger_lines_fresh() {
    [[ -n "${RTB_LINES_WRITTEN_LOG:-}" && -f "$RTB_LINES_WRITTEN_LOG" ]] || return 1
    grep -qxF -- "$1" "$RTB_LINES_WRITTEN_LOG" 2>/dev/null
}

# rtb_ledger_lines_fetch <fp> <out> — copies the verified row file to <out>; 1 = miss.
rtb_ledger_lines_fetch() {
    local fp="${1:-}" out="${2:-}" f
    rtb_ledger_valid_fp "$fp" && [[ -n "$out" ]] || return 1
    f="$(rtb_ledger_dir)/v3.lines.$fp"
    [[ -f "$f" ]] || return 1
    cp "$f" "$out" 2>/dev/null || return 1
    # The copy is what the caller reads, so the copy is what is verified.
    [[ "$(rtb_ledger_sha256 "$out")" == "$fp" ]] || { rm -f "$out"; return 1; }
    touch "$f" 2>/dev/null || true
    return 0
}

# rtb_ledger_lines_get <fp> — prints the verified row file; 1 = miss.
rtb_ledger_lines_get() {
    local tmp rc=0
    tmp="$(mktemp 2>/dev/null)" || return 1
    rtb_ledger_lines_fetch "${1:-}" "$tmp" || rc=1
    [[ "$rc" -eq 0 ]] && cat "$tmp"
    rm -f "$tmp"
    return "$rc"
}

# rtb_ledger_lines_res <body-file> <dir> — rebuilds a result dir (cases.tsv, fail-details.tsv) the
# comparer reads back into the same body: one FAIL case per row, its line as the detail ("" = none).
rtb_ledger_lines_res() {
    local body="${1:-}" dir="${2:-}"
    [[ -f "$body" && -n "$dir" ]] || return 1
    rm -rf "$dir"
    mkdir -p "$dir" 2>/dev/null || return 1
    RTB_AWK_CF="$dir/cases.tsv" RTB_AWK_DF="$dir/fail-details.tsv" LC_ALL=C awk '
        BEGIN { CF = ENVIRON["RTB_AWK_CF"]; DF = ENVIRON["RTB_AWK_DF"] }
        NR == 1 { if ($0 != "records=cases" && $0 != "records=none") { bad = 1; exit } hdr = $0; next }
        {
            t = index($0, "\t")
            if (t < 2) { bad = 1; exit }
            k++
            c = substr($0, 1, t - 1); l = substr($0, t + 1)
            printf "%d\tFAIL\t%s\t-\n", k, c > CF
            if (l != "") printf "%d\t%s\t%s\n", k, c, l > DF
        }
        END {
            if (bad || hdr == "") exit 1
            if (hdr == "records=cases" && k == 0) printf "0\tPASS\t-\t-\n" > CF
        }' "$body" || { rm -rf "$dir"; return 1; }
    return 0
}

# rtb_ledger_lines_store <res-dir> <root> <base-wt> <tmpdir> — stores the result dir's body as a
# row file and prints its fp; prints `-` when the body cannot be made or stored.
rtb_ledger_lines_store() {
    local res="$1" root="$2" wt="$3" out fp
    out="$4/lines.$$.$RANDOM"
    fp="$(node "$(rtb_wt_native "$RTB_LINES_JS")" --res "$(rtb_wt_native "$res")" --root "$(rtb_wt_native "$root")" \
        --base-wt "$(rtb_wt_native "$wt")" --out "$(rtb_wt_native "$out")" 2>/dev/null)" || fp=""
    if rtb_ledger_valid_fp "$fp" && rtb_ledger_lines_put "$fp" "$out"; then
        printf '%s' "$fp"
    else
        printf '%s' "-"
    fi
    rm -f "$out"
    return 0
}

# rtb_ledger_lines_load <fp> <dir> <tmpdir> — rebuilds <dir> from the row file for <fp>; 1 = miss.
rtb_ledger_lines_load() {
    local fp="$1" dir="$2" body rc=0
    body="$3/body.$$.$RANDOM"
    rtb_ledger_lines_fetch "$fp" "$body" && rtb_ledger_lines_res "$body" "$dir" || rc=1
    rm -f "$body"
    return "$rc"
}
