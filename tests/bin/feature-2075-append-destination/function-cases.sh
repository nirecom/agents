#!/usr/bin/env bash
# Tests: bin/lib/test-route-destination.sh
# Tags: scope:issue-specific
# Part of tests/bin/feature-2075-append-destination.sh (rules/coding/file-split.md).
# Cases F1-F7 (TL1): direct calls into the source-only routing library, for the
# boundaries the CLI's TSV cannot express — rejection statuses, key equality and
# the rank/viable predicates as standalone functions.
# F6/F7 deliberately assert only encoding-agnostic properties (permutation,
# idempotence, subset, path containment): the plan fixes the candidate array's
# ELEMENT format nowhere, so asserting a layout here would pin an invention.

f2075_join() { local IFS=","; printf '%s' "$*"; }

if [[ ! -f "$ROUTE_LIB" ]]; then
    for _fid in F1 F2 F3 F4 F5 F6 F7; do
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

    # ── F3 trd_is_top_level_test decides by path components, not by glob ────
    case_ran F3
    for _pair in "tests/a.sh:0" "tests/part/bar.sh:1" "bin/a.sh:1" "tests/a.txt:1" "tests:1" "a.sh:1"; do
        _p="${_pair%%:*}"
        _want="${_pair#*:}"
        trd_is_top_level_test "$_p"
        _got=$?
        [[ "$_got" -ne 0 ]] && _got=1
        assert_eq "F3 trd_is_top_level_test $_p" "$_want" "$_got"
    done

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
    add_test_file "$F5REPO" "a.sh" "a.js" "scope:common" 37
    assert_eq "F5 line count of a known fixture" "37" "$(trd_file_lines "$F5REPO/tests/a.sh")"
    assert_eq "F5 unreadable file is a non-zero status" "1" \
        "$(f2075_rc trd_file_lines "$F5REPO/tests/does-not-exist.sh")"

    # ── F6/F7 rank and viable, fed by the real producer ─────────────────────
    F6REPO="$(make_repo)"
    add_test_file "$F6REPO" "exact.sh" "a.js" "scope:common" 40
    add_test_file "$F6REPO" "e1.sh" "a.js,b.js" "scope:common" 20
    add_test_file "$F6REPO" "e2.sh" "a.js,b.js,c.js" "scope:common" 12
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
    if [[ "${F6RANKED[0]-}" == *"tests/exact.sh"* ]]; then
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
    if [[ "${#F7MID[@]}" -gt 0 && "$(printf '%s\n' "${F7MID[@]}")" == *"tests/exact.sh"* ]]; then
        fail "F7 kept the 40-line candidate under a 21-line limit"
    else
        pass "F7 the over-limit candidate is absent from the viable set"
    fi
    cd "$F2075_OLDPWD" || true
fi

grp_done "function-cases.sh"
