# shellcheck shell=bash
# Tests: tests/bin-concern-ledger-harness-namespace-guard/scenarios.sh
# Tags: concern-ledger, test-harness, namespace-guard, parser, table-driven, TL2, scope:common
# G14 — the grader itself. nsg_has_collision decides nearly every expect_report in
# this suite, so a permissive one false-greens all of them at once: a substring
# reader accepts the report's own `FAIL:` prefix, a neighbouring context, or a
# longer name that merely starts with the expected one. The rows below are
# hand-built text, so they grade the parser with no implementation in the picture.

echo ""
echo "=== G14: the nsg_has_collision grader itself ==="

# nsg_grade <input> <name> <context> -> match | nomatch
nsg_grade() {
    if nsg_has_collision "$1" "$2" "$3"; then printf 'match'; else printf 'nomatch'; fi
}

while IFS='|' read -r _p_name _p_in _p_want_name _p_want_ctx _p_want; do
    [[ -z "$_p_name" || "$_p_name" =~ ^[[:space:]]*# ]] && continue
    _p_name="${_p_name//[[:space:]]/}"
    _p_want="${_p_want//[[:space:]]/}"
    _p_got="$(nsg_grade "$(tbl_input_at "$_p_in")" "$(tbl_input_at "$_p_want_name")" "$(tbl_input_at "$_p_want_ctx")")"
    if [[ "$_p_got" == "$_p_want" ]]; then
        pass "G14/$_p_name"
    else
        fail "G14/$_p_name: want $_p_want, got $_p_got — the grader every expect_report above depends on reads this input wrongly"
    fi
done <<'TABLE'
exact-match       | FAIL:~namespace~collision~at~ctx-G1:~hx_probe~(harness~function)~was~redefined | hx_probe | ctx-G1 | match
wrong-name        | FAIL:~namespace~collision~at~ctx-G1:~hx_probe~(harness~function)~was~redefined | hx_other | ctx-G1 | nomatch
wrong-context     | FAIL:~namespace~collision~at~ctx-G1:~hx_probe~(harness~function)~was~redefined | hx_probe | ctx-G2 | nomatch
name-is-prefix    | FAIL:~namespace~collision~at~ctx-G1:~hx_probe_extra~(harness~function)~changed | hx_probe | ctx-G1 | nomatch
context-is-prefix | FAIL:~namespace~collision~at~ctx-G10:~hx_probe~(harness~function)~changed      | hx_probe | ctx-G1 | nomatch
name-in-context   | FAIL:~namespace~collision~at~ctx-hx_probe:~other_name~(harness~function)~went  | hx_probe | ctx-hx_probe | nomatch
name-field-wins   | FAIL:~namespace~collision~at~ctx-hx_probe:~other_name~(harness~function)~went  | other_name | ctx-hx_probe | match
truncated-no-what | FAIL:~namespace~collision~at~ctx-G1:~hx_probe                                  | hx_probe | ctx-G1 | nomatch
missing-at        | FAIL:~namespace~collision~ctx-G1:~hx_probe~(harness~function)~changed          | hx_probe | ctx-G1 | nomatch
not-line-anchored | note:~FAIL:~namespace~collision~at~ctx-G1:~hx_probe~(harness~function)~changed | hx_probe | ctx-G1 | nomatch
lowercase-prefix  | fail:~namespace~collision~at~ctx-G1:~hx_probe~(harness~function)~changed       | hx_probe | ctx-G1 | nomatch
empty-input       |                                                                                | hx_probe | ctx-G1 | nomatch
other-names-only  | FAIL:~namespace~collision~at~ctx-G1:~pass~(f)~went@FAIL:~namespace~collision~at~ctx-G1:~fail~(f)~went | hx_probe | ctx-G1 | nomatch
one-of-three      | FAIL:~namespace~collision~at~ctx-G1:~pass~(f)~went@FAIL:~namespace~collision~at~post-cases:~PASS~(v)~decreased@FAIL:~namespace~collision~at~ctx-G1:~fail~(f)~went | PASS | post-cases | match
blank-padded      | @FAIL:~namespace~collision~at~ctx-G1:~hx_probe~(harness~function)~changed@     | hx_probe | ctx-G1 | match
underscore-name   | FAIL:~namespace~collision~at~ctx-G3p:~_cl_norm~(library~function)~was~redefined | _cl_norm | ctx-G3p | match
TABLE
