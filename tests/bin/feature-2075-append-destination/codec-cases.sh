#!/usr/bin/env bash
# Tests: bin/lib/test-dup-group.sh
# Tags: scope:issue-specific
# Part of tests/bin/feature-2075-append-destination.sh (rules/coding/file-split.md).
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

grp_done "codec-cases.sh"
