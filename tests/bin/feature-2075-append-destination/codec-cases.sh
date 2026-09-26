#!/usr/bin/env bash
# Tests: bin/lib/test-dup-group.sh
# Tags: scope:issue-specific
# Part of tests/feature-2075-append-destination.sh (rules/coding/file-split.md).
# Cases K1-K5 (TL1): the reverse codec added next to tdg_escape_field. The whole
# assertion harness of this suite decodes through these two functions, so a
# silent decode bug would corrupt every other case's `got` side instead of
# failing it — the table-driven rows below are what keeps that from happening
# (skills/_shared/test-design/parser-regex-tests.md, Table-Driven Tests).
# The `\\t` vs `\t` distinction is the one the plan names as the silent-corruption
# risk: a `${var//}` chain cannot tell them apart, a left-to-right scan can.

if ! declare -F tdg_unescape_field >/dev/null 2>&1 || ! declare -F tdg_split_escaped_csv >/dev/null 2>&1; then
    for _kid in K1 K2 K3 K4 K5; do
        case_ran "$_kid"
        fail "$_kid tdg_unescape_field / tdg_split_escaped_csv are not defined by bin/lib/test-dup-group.sh — the reverse codec cases cannot run"
    done
else
    # ── K1 tdg_unescape_field, one row per escape class ─────────────────────
    # Column 3 is a printf %b spec, never a bare literal: TAB / LF / CR have no
    # readable in-table spelling otherwise. Column 2 is the raw escaped input.
    case_ran K1
    while IFS='|' read -r k1_name k1_in k1_want; do
        [[ -z "$k1_name" ]] && continue
        assert_eq "K1 unescape $k1_name" "$(printf '%b' "$k1_want")" "$(tdg_unescape_field "$k1_in")"
    done <<'K1_TABLE'
plain|src/x.js|src/x.js
escaped-backslash|a\\b|a\\b
escaped-tab|a\tb|a\tb
escaped-newline|a\nb|a\nb
escaped-cr|a\rb|a\rb
escaped-comma|a\,b|a,b
unknown-escape-drops-the-backslash|a\xb|axb
dangling-backslash-survives|ab\|ab\\
escaped-backslash-then-literal-t|a\\tb|a\\tb
two-escaped-backslashes|a\\\\b|a\\\\b
leading-escape|\,x|,x
K1_TABLE

    # ── K2 escape → unescape is the identity (both directions, one SSOT) ────
    case_ran K2
    while IFS='|' read -r k2_name k2_spec; do
        [[ -z "$k2_name" ]] && continue
        k2_raw="$(printf '%b' "$k2_spec")"
        assert_eq "K2 round-trip $k2_name" "$k2_raw" \
            "$(tdg_unescape_field "$(tdg_escape_field "$k2_raw")")"
    done <<'K2_TABLE'
comma|a,b
backslash|a\\b
tab|a\tb
newline|a\nb
cr|a\rb
backslash-followed-by-t|a\\tb
every-class-at-once|a\\,b\tc\\\\d,e
K2_TABLE

    # ── K3 tdg_split_escaped_csv: where an element boundary is, and is not ──
    # Column 4 joins the expected elements with `~`, a character none of the
    # rows contains, so element COUNT and element CONTENT are asserted apart.
    case_ran K3
    k3_join() { local IFS='~'; printf '%s' "$*"; }
    while IFS='|' read -r k3_name k3_in k3_count k3_joined; do
        [[ -z "$k3_name" ]] && continue
        declare -a K3OUT=()
        tdg_split_escaped_csv "$k3_in" K3OUT
        assert_eq "K3 $k3_name element count" "$k3_count" "${#K3OUT[@]}"
        assert_eq "K3 $k3_name elements" "$(printf '%b' "$k3_joined")" "$(k3_join "${K3OUT[@]}")"
    done <<'K3_TABLE'
single-element|a|1|a
plain-boundary|a,b|2|a~b
escaped-comma-is-not-a-boundary|a\,b|1|a,b
escaped-and-plain-mixed|a\,b,c|2|a,b~c
trailing-boundary|a,|2|a~
leading-boundary|,a|2|~a
two-escaped-commas-one-boundary|a\,b\,c,d|2|a,b,c~d
escaped-backslash-does-not-escape-the-comma|a\\,b|2|a\\~b
K3_TABLE

    # ── K4 the double escape the 6-8 columns are built from ─────────────────
    # Inner element `file,lines,extra_count` escaped once, then escaped again as
    # one outer element. Two split passes must return the original three fields.
    case_ran K4
    K4_INNER="$(tdg_escape_field "tests/we,ird.sh"),20,2"
    K4_COL="$(tdg_escape_field "$K4_INNER"),$(tdg_escape_field "$(tdg_escape_field "tests/plain.sh"),31,0")"
    declare -a K4OUTER=() K4INNER=()
    tdg_split_escaped_csv "$K4_COL" K4OUTER
    assert_eq "K4 the outer pass yields two entries" "2" "${#K4OUTER[@]}"
    tdg_split_escaped_csv "${K4OUTER[0]}" K4INNER
    assert_eq "K4 the inner pass yields three fields" "3" "${#K4INNER[@]}"
    assert_eq "K4 a comma inside the path survives both passes" "tests/we,ird.sh" "${K4INNER[0]-}"
    assert_eq "K4 the line count survives both passes" "20" "${K4INNER[1]-}"
    assert_eq "K4 the extra_count survives both passes" "2" "${K4INNER[2]-}"

    # ── K5 the escaped form is TSV-safe, and still decodes back ─────────────
    case_ran K5
    K5_RAW="$(printf 'a\tb\nc,d\\e')"
    K5_ESC="$(tdg_escape_field "$K5_RAW")"
    if [[ "$K5_ESC" == *$'\t'* || "$K5_ESC" == *$'\n'* || "$K5_ESC" == *$'\r'* ]]; then
        fail "K5 the escaped form still carries a raw TAB/LF/CR and would break the TSV grid"
    else
        pass "K5 the escaped form carries no raw TAB/LF/CR"
    fi
    assert_eq "K5 the decoder recovers the original payload" "$K5_RAW" "$(tdg_unescape_field "$K5_ESC")"
fi

# ── A1-A6 tdg_scan_corpus canonical-category allowlist (#2396) ───────────────
# A1: canonical category (bin/) IS included in corpus.
# A2: _archive/ is NOT in corpus (not a canonical category).
# A3: rel field is tests/<canonical-category>/<name>.sh form.
# A4: 4-component paths are NOT in corpus (too deep).
# A5: tests/lib/ is NOT in corpus (lib/ is shared infra, not a category).
# A6: non-canonical split dir (fix-1532-node-guard) is NOT in corpus.
if ! declare -F tdg_scan_corpus >/dev/null 2>&1; then
    for _akid in A1 A2 A3 A4 A5 A6; do
        case_ran "$_akid"
        fail "$_akid tdg_scan_corpus is not defined — corpus-glob cases cannot run"
    done
else
    A1R="$(make_repo)"
    add_test_file "$A1R" "bin/foo.sh" "src/a.js" "scope:common" 20
    A1_OUT="$(tdg_scan_corpus "$A1R")"

    case_ran A1
    if printf '%s\n' "$A1_OUT" | grep -q 'tests/bin/foo.sh'; then
        pass "A1 canonical-category test (tests/bin/) appears in corpus"
    else
        fail "A1 tests/bin/foo.sh not found in corpus — canonical-category scan not applied"
    fi

    A2R="$(make_repo)"
    add_test_file "$A2R" "_archive/foo.sh" "src/a.js" "scope:common" 20
    add_test_file "$A2R" "bin/keep.sh" "src/a.js" "scope:common" 20
    A2_OUT="$(tdg_scan_corpus "$A2R")"

    case_ran A2
    if printf '%s\n' "$A2_OUT" | grep -q 'tests/_archive/foo.sh'; then
        fail "A2 tests/_archive/foo.sh appeared in corpus — not a canonical category"
    else
        pass "A2 tests/_archive/foo.sh is NOT in corpus"
    fi
    if printf '%s\n' "$A2_OUT" | grep -q 'tests/bin/keep.sh'; then
        pass "A2 tests/bin/keep.sh IS in corpus (canonical category bin/)"
    else
        fail "A2 tests/bin/keep.sh not found — canonical-category sibling should be in corpus"
    fi

    A3R="$(make_repo)"
    add_test_file "$A3R" "bin/bar.sh" "src/b.js" "scope:common" 20
    A3_OUT="$(tdg_scan_corpus "$A3R")"

    case_ran A3
    if printf '%s\n' "$A3_OUT" | grep -q 'tests/bin/bar.sh'; then
        pass "A3 rel field is in tests/<canonical-category>/<name>.sh form"
    else
        fail "A3 rel field wrong — expected tests/bin/bar.sh, got: $(printf '%q' "$A3_OUT")"
    fi

    # ── A4 4-component paths are NOT in corpus (canonical dirs contain only .sh) ─
    A4R="$(make_repo)"
    add_test_file "$A4R" "bin/name.sh" "src/a.js" "scope:common" 20
    add_test_file "$A4R" "bin/name/frag.sh" "src/a.js" "scope:common" 20
    A4_OUT="$(tdg_scan_corpus "$A4R")"

    case_ran A4
    if printf '%s\n' "$A4_OUT" | grep -q 'tests/bin/name.sh'; then
        pass "A4 tests/bin/name.sh (3-component canonical) IS in corpus"
    else
        fail "A4 tests/bin/name.sh not found — expected it in corpus"
    fi
    if printf '%s\n' "$A4_OUT" | grep -q 'tests/bin/name/frag.sh'; then
        fail "A4 tests/bin/name/frag.sh (4-component) appeared in corpus — too deep"
    else
        pass "A4 tests/bin/name/frag.sh (4-component) is NOT in corpus"
    fi

    # ── A5 tests/lib/foo.sh is NOT in corpus (lib/ is not a canonical category) ─
    A5R="$(make_repo)"
    add_test_file "$A5R" "lib/foo.sh" "src/a.js" "scope:common" 20
    A5_OUT="$(tdg_scan_corpus "$A5R")"

    case_ran A5
    if printf '%s\n' "$A5_OUT" | grep -q 'tests/lib/foo.sh'; then
        fail "A5 tests/lib/foo.sh appeared in corpus — lib/ is shared infra (#1834)"
    else
        pass "A5 tests/lib/foo.sh is NOT in corpus (lib/ not a canonical category)"
    fi

    # ── A6 non-canonical dir (split fragment) NOT in corpus ──────────────────
    A6R="$(make_repo)"
    add_test_file "$A6R" "fix-1532-node-guard/foo.sh" "src/a.js" "scope:common" 20
    add_test_file "$A6R" "bin/bar.sh" "src/a.js" "scope:common" 20
    A6_OUT="$(tdg_scan_corpus "$A6R")"

    case_ran A6
    if printf '%s\n' "$A6_OUT" | grep -q 'tests/fix-1532-node-guard/foo.sh'; then
        fail "A6 tests/fix-1532-node-guard/ appeared in corpus — non-canonical dir"
    else
        pass "A6 tests/fix-1532-node-guard/ is NOT in corpus (non-canonical category)"
    fi
    if printf '%s\n' "$A6_OUT" | grep -q 'tests/bin/bar.sh'; then
        pass "A6 canonical sibling tests/bin/bar.sh IS in corpus"
    else
        fail "A6 tests/bin/bar.sh not found — canonical category should still be scanned"
    fi
fi

grp_done "codec-cases.sh"
