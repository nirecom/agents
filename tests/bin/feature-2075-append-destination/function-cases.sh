#!/usr/bin/env bash
# Tests: bin/lib/test-route-destination.sh
# Tags: scope:issue-specific
# Part of tests/bin/feature-2075-append-destination.sh (rules/coding/file-split.md).
# Cases F1-F10 (TL1): direct calls into the source-only routing library, for the
# boundaries the CLI's TSV cannot express — rejection statuses, key equality and
# the rank/viable predicates as standalone functions.
# F6/F7 deliberately assert only encoding-agnostic properties (permutation,
# idempotence, subset, path containment): the plan fixes the candidate array's
# ELEMENT format nowhere, so asserting a layout here would pin an invention.

# shellcheck source=../../lib/harness.sh
if ! declare -f case_begin >/dev/null 2>&1; then
  AGENTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  source "$AGENTS_ROOT/tests/lib/harness.sh"
fi

f2075_join() { local IFS=","; printf '%s' "$*"; }

if [[ ! -f "$ROUTE_LIB" ]]; then
    for _fid in F1 F2 F3 F4 F5 F6 F7 F8 F9 F10; do
        case_ran "$_fid"
        fail "$_fid bin/lib/test-route-destination.sh is missing — function-level cases cannot run"
    done
else
    # shellcheck source=../../bin/lib/test-route-destination.sh
    . "$ROUTE_LIB"

    # ── F1 trd_canonicalize_set: ./ strip, dedup, LC_ALL=C sort ─────────────
    case_ran F1
    declare -a F1SET=()
    trd_canonicalize_set F1SET "./b.js" " a.js " "b.js" "./a.js"
    assert_eq "F1 canonical set is deduplicated and sorted" "a.js,b.js" "$(f2075_join "${F1SET[@]}")"
    declare -a F1SET2=()
    trd_canonicalize_set F1SET2 ".//./c.js"
    assert_eq "F1 repeated ./ prefixes are all stripped" "c.js" "$(f2075_join "${F1SET2[@]}")"

    # ── F2 trd_canonicalize_set / trd_normalize_token reject unsafe tokens ──
    case_ran F2
    f2075_rc() { "$@" >/dev/null 2>&1; if [[ "$?" -eq 0 ]]; then printf '0'; else printf '1'; fi; }
    declare -a F2SET=() F2SET2=()
    assert_eq "F2 absolute path is rejected" "1" "$(f2075_rc trd_canonicalize_set F2SET "/etc/passwd")"
    assert_eq "F2 parent-escaping token is rejected" "1" "$(f2075_rc trd_canonicalize_set F2SET2 "../outside.js")"
    assert_eq "F2 a well-formed token is accepted" "0" "$(f2075_rc trd_normalize_token "src/ok.js")"
    # F2 extended: table-driven trd_normalize_token, accepted and rejected patterns (C4/#2290)
    for _f2tok in "src/ok.js" "a.ts" "lib/foo.rs"; do
        assert_eq "F2 accept $_f2tok" "0" "$(f2075_rc trd_normalize_token "$_f2tok")"
    done
    for _f2tok in "/etc/x" "../x" "src/a b.js"; do
        assert_eq "F2 reject $_f2tok" "1" "$(f2075_rc trd_normalize_token "$_f2tok")"
    done

    # ── F3 trd_is_in_corpus decides by canonical category allowlist (#2412) ──
    # tests/bin/bar.sh (canonical category bin) → exit 0 (#2396).
    # tests/_archive/foo.sh, tests/lib/foo.sh → exit 1 (not canonical).
    # tests/fix-1532-node-guard/foo.sh → exit 1 (non-canonical split dir).
    case_ran F3
    if ! declare -F trd_is_in_corpus >/dev/null 2>&1; then
        fail "F3 trd_is_in_corpus is not defined by bin/lib/test-route-destination.sh (#2412 rename not implemented)"
    else
        for _pair in "tests/a.sh:1" "tests/bin/bar.sh:0" "tests/hooks/x.sh:0" "tests/skills/y.sh:0" "tests/_archive/foo.sh:1" "tests/lib/foo.sh:1" "tests/fix-1532-node-guard/foo.sh:1" "bin/a.sh:1" "tests/a.txt:1" "tests:1" "a.sh:1"; do
            _p="${_pair%%:*}"
            _want="${_pair#*:}"
            trd_is_in_corpus "$_p"
            _got=$?
            [[ "$_got" -ne 0 ]] && _got=1
            assert_eq "F3 trd_is_in_corpus $_p" "$_want" "$_got"
        done
    fi
    if declare -F trd_is_top_level_test >/dev/null 2>&1; then
        fail "F3 the legacy name trd_is_top_level_test is still defined (#2412)"
    else
        pass "F3 the legacy name trd_is_top_level_test is gone"
    fi

    # ── F4 trd_set_key is order- and spelling-independent ───────────────────
    case_ran F4
    assert_eq "F4 the same set spelled two ways yields one key" \
        "$(trd_set_key "a.js" "b.js")" "$(trd_set_key "./b.js" "a.js" "b.js")"
    if [[ "$(trd_set_key "a.js" "b.js")" == "$(trd_set_key "a.js" "c.js")" ]]; then
        fail "F4 different sets collapsed onto the same key"
    else
        pass "F4 different sets keep different keys"
    fi

    # ── F5 trd_file_lines ───────────────────────────────────────────────────
    case_ran F5
    F5REPO="$(make_repo)"
    add_test_file "$F5REPO" "bin/a.sh" "a.js" "scope:common" 37
    assert_eq "F5 line count of a known fixture" "37" "$(trd_file_lines "$F5REPO/tests/bin/a.sh")"
    assert_eq "F5 unreadable file is a non-zero status" "1" \
        "$(f2075_rc trd_file_lines "$F5REPO/tests/does-not-exist.sh")"
    TRD_FILE_LINES=""
    trd_file_lines "$F5REPO/tests/bin/a.sh" >/dev/null
    assert_eq "F5 a bare call also sets the TRD_FILE_LINES global" "37" "${TRD_FILE_LINES-}"

    # ── F9 (EQ4) trd_file_lines agrees with wc -l on every line-ending shape ─
    case_ran F9
    F9DIR="$(mktemp -d -p "$TMPDIR_BASE")"
    printf 'a\nb' > "$F9DIR/no-final-newline"
    : > "$F9DIR/empty"
    printf '\n\n\n' > "$F9DIR/only-newlines"
    printf 'a\r\nb\r\nc\r\n' > "$F9DIR/crlf"
    printf '%*s\nshort\n' 70000 'x' > "$F9DIR/long-line"
    printf 'x' > "$F9DIR/single-char"
    for _f9 in no-final-newline empty only-newlines crlf long-line single-char; do
        _f9want="$(wc -l < "$F9DIR/$_f9")"
        _f9want="${_f9want//[[:space:]]/}"
        assert_eq "F9 $_f9 printed count equals wc -l" "$_f9want" "$(trd_file_lines "$F9DIR/$_f9")"
        TRD_FILE_LINES=""
        trd_file_lines "$F9DIR/$_f9" >/dev/null
        assert_eq "F9 $_f9 TRD_FILE_LINES equals wc -l" "$_f9want" "${TRD_FILE_LINES-}"
    done

    # ── F10 (EQ5) trd_rank orders exactly like the sort pipeline it replaces ─
    case_ran F10
    f10_check() {
        local name="$1" want
        shift
        declare -a F10ARR=("$@")
        want="$(printf '%s\n' "$@" | LC_ALL=C sort -t$'\t' -k1,1n -k2,2n -k3,3)"
        trd_rank F10ARR
        assert_eq "F10 $name" "$want" "$(printf '%s\n' "${F10ARR[@]}")"
    }
    f10_check "ties on both numeric keys fall back to the path" \
        $'0\t10\ttests/bin/b.sh' $'0\t10\ttests/bin/a.sh' $'0\t10\ttests/bin/c.sh'
    f10_check "upper case sorts before lower case under C collation" \
        $'1\t5\ttests/bin/b.sh' $'1\t5\ttests/bin/B.sh' $'1\t5\ttests/bin/a.sh' $'1\t5\ttests/bin/A.sh'
    f10_check "punctuation - _ . order by byte value" \
        $'0\t3\ttests/bin/a_b.sh' $'0\t3\ttests/bin/a-b.sh' $'0\t3\ttests/bin/a.b.sh' $'0\t3\ttests/bin/ab.sh'
    f10_check "numbers of different digit counts compare numerically" \
        $'10\t2\ttests/bin/x.sh' $'9\t2\ttests/bin/y.sh' $'100\t1\ttests/bin/z.sh' $'0\t1000\ttests/bin/w.sh' $'0\t99\ttests/bin/v.sh'
    f10_check "a single element is unchanged" $'3\t7\ttests/bin/only.sh'
    declare -a F10EMPTY=()
    trd_rank F10EMPTY; _f10rc=$?
    assert_eq "F10 an empty array: trd_rank exits 0" "0" "$_f10rc"
    assert_eq "F10 an empty array stays empty" "0" "${#F10EMPTY[@]}"
    declare -a F10BIG=()
    for ((_i = 0; _i < 300; _i++)); do
        F10BIG+=("$(( (_i * 7) % 5 ))"$'\t'"$(( (_i * 13) % 17 ))"$'\t'"tests/bin/f$(( (_i * 31) % 300 ))_${_i}.sh")
    done
    f10_check "a 300-element set" "${F10BIG[@]}"

    # ── F6/F7 rank and viable, fed by the real producer ─────────────────────
    F6REPO="$(make_repo)"
    add_test_file "$F6REPO" "bin/exact.sh" "a.js" "scope:common" 40
    add_test_file "$F6REPO" "bin/e1.sh" "a.js,b.js" "scope:common" 20
    add_test_file "$F6REPO" "bin/e2.sh" "a.js,b.js,c.js" "scope:common" 12
    F2075_OLDPWD="$PWD"
    cd "$F6REPO" || fail "F6 could not enter the fixture repo"
    trd_load_corpus "$F6REPO"
    F6KEY="$(trd_set_key "a.js")"
    declare -a F6CANDS=()
    trd_candidates F6CANDS "$F6KEY" ""
    declare -a F6RANKED=("${F6CANDS[@]}")
    trd_rank F6RANKED
    declare -a F6RANKED2=("${F6RANKED[@]}")
    trd_rank F6RANKED2

    case_ran F6
    assert_eq "F6 the fixture yields three candidates" "3" "${#F6CANDS[@]}"
    assert_eq "F6 ranking is a permutation of the candidate set" \
        "$(printf '%s\n' "${F6CANDS[@]}" | LC_ALL=C sort)" \
        "$(printf '%s\n' "${F6RANKED[@]}" | LC_ALL=C sort)"
    assert_eq "F6 ranking is idempotent" \
        "$(printf '%s\n' "${F6RANKED[@]}")" "$(printf '%s\n' "${F6RANKED2[@]}")"
    if [[ "${F6RANKED[0]-}" == *"tests/bin/exact.sh"* ]]; then
        pass "F6 the exact match ranks first"
    else
        fail "F6 the exact match did not rank first — head was '${F6RANKED[0]-}'"
    fi

    case_ran F7
    declare -a F7LOOSE=()
    trd_viable_candidates F7LOOSE F6RANKED 1000
    assert_eq "F7 a loose limit keeps every ranked candidate" "${#F6RANKED[@]}" "${#F7LOOSE[@]}"
    declare -a F7TIGHT=()
    trd_viable_candidates F7TIGHT F6RANKED 5
    assert_eq "F7 a limit below every candidate keeps none" "0" "${#F7TIGHT[@]}"
    declare -a F7MID=()
    trd_viable_candidates F7MID F6RANKED 21
    assert_eq "F7 a mid limit keeps only the candidates under it" "2" "${#F7MID[@]}"
    if [[ "${#F7MID[@]}" -gt 0 && "$(printf '%s\n' "${F7MID[@]}")" == *"tests/bin/exact.sh"* ]]; then
        fail "F7 kept the 40-line candidate under a 21-line limit"
    else
        pass "F7 the over-limit candidate is absent from the viable set"
    fi
    cd "$F2075_OLDPWD" || true

    # ── F8 tdg_scan_corpus is called exactly once across multiple trd_candidates ─
    # Note: this test relies on trd_load_corpus's global-variable memoization.
    # trd_load_corpus calls tdg_scan_corpus inside a process substitution
    # (`< <(...)`), so any counter variable incremented there stays in the
    # subshell. A temp file persists the count across that boundary.
    case_ran F8
    if ! declare -F tdg_scan_corpus >/dev/null 2>&1; then
        fail "F8 tdg_scan_corpus is not defined — corpus-count test cannot run"
    elif ! declare -F trd_candidates >/dev/null 2>&1; then
        fail "F8 trd_candidates is not defined — corpus-count test cannot run"
    else
        F8REPO="$(make_repo)"
        add_test_file "$F8REPO" "bin/p.sh" "p.js" "scope:common" 20
        add_test_file "$F8REPO" "bin/q.sh" "q.js" "scope:common" 20
        add_test_file "$F8REPO" "bin/r.sh" "r.js" "scope:common" 20
        # Use a temp file so the increment survives the process-substitution subshell.
        F8_COUNT_FILE="$(mktemp "${TMPDIR_BASE}/tmp.XXXXXX")"
        printf '0' > "$F8_COUNT_FILE"
        # Rename the original body, then wrap with a file-based counter.
        eval "$(declare -f tdg_scan_corpus | sed 's/^tdg_scan_corpus ()/tdg_scan_corpus_f8_orig ()/')"
        tdg_scan_corpus() {
            local _c; _c="$(cat "$F8_COUNT_FILE")"
            printf '%d' $((_c + 1)) > "$F8_COUNT_FILE"
            tdg_scan_corpus_f8_orig "$@"
        }
        F8_OLD_PWD="$PWD"
        cd "$F8REPO" || fail "F8 could not enter fixture repo"
        trd_load_corpus "$F8REPO"
        declare -a F8C1=() F8C2=() F8C3=()
        trd_candidates F8C1 "$(trd_set_key "p.js")" ""
        trd_candidates F8C2 "$(trd_set_key "q.js")" ""
        trd_candidates F8C3 "$(trd_set_key "r.js")" ""
        TDG_SCAN_COUNT="$(cat "$F8_COUNT_FILE")"
        rm -f "$F8_COUNT_FILE"
        # Restore original by reverting the rename.
        eval "$(declare -f tdg_scan_corpus_f8_orig | sed 's/^tdg_scan_corpus_f8_orig ()/tdg_scan_corpus ()/')"
        unset -f tdg_scan_corpus_f8_orig
        assert_eq "F8 tdg_scan_corpus called once despite 3 trd_candidates calls" "1" "$TDG_SCAN_COUNT"
        cd "$F8_OLD_PWD" || true
    fi
fi

grp_done "function-cases.sh"
