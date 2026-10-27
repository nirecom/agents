# Tests: bin/check-self-impl.sh, bin/check-test-language-match.sh
# Tags: TL2, bin, self-impl, test-language-match, scope:issue-specific
# CLI argument contracts: check-self-impl.sh takes --head up to twice and --base only with two heads,
# reads 3- and 5-column manifests (D5); check-test-language-match.sh takes the same --head/--base pair
# and --declaration-only alone (D6c). The single --head form keeps its #2761 output.
# Sourced by tests/bin/feat-2812-tests-gates-merge.sh after self-impl.sh and language-match.sh.
# shellcheck shell=bash

echo ""
echo "=== checker CLI arguments ==="

CA="$TMPBASE/ca"
mkdir -p "$CA"
for b in c0-b c1-h c1-m c2-hm c3-hm ll-head ll-up ll-staged ll-extra lr-base lr-head lr-up lr-staged lm-bad; do
  cp "$BODIES/$b" "$CA/$b"
done
SR=tests/bin/s.sh
LR=tests/bin/l.sh
TAB=$'\t'

case_begin "self-impl-rejects-bad-head-base-combinations" "bin/check-self-impl.sh"
cli "$CA" "$SI_CLI" --rel "$SR" --head c1-h --base c0-b c2-hm
expect_rc "--base with one --head" 2 "$CLI_RC" "$CLI_ERR"
cli "$CA" "$SI_CLI" --rel "$SR" --head c1-h --head c1-m --head c0-b c2-hm
expect_rc "--head three times" 2 "$CLI_RC" "$CLI_ERR"
case_end

case_begin "self-impl-two-heads-and-base-judge-3-way" "bin/check-self-impl.sh"
cli "$CA" "$SI_CLI" --rel "$SR" --head c1-h --head c1-m --base c0-b c2-hm
expect_rc "(e) via CLI: H1 M1 B0 staged 2" 0 "$CLI_RC" "$CLI_OUT $CLI_ERR"
cli "$CA" "$SI_CLI" --rel "$SR" --head c1-h --head c1-m --base c0-b c3-hm
expect_rc "(f) via CLI: staged 3" 1 "$CLI_RC" "$CLI_OUT $CLI_ERR"
expect_codes "(f) via CLI" "$CLI_OUT" SELF_IMPLEMENTED_HARNESS 1
case_end

case_begin "self-impl-single-head-output-unchanged" "bin/check-self-impl.sh"
cli "$CA" "$SI_CLI" --rel "$SR" --head c1-h c2-hm
expect_rc "single --head" 1 "$CLI_RC" "$CLI_ERR"
expect_codes "single --head" "$CLI_OUT" SELF_IMPLEMENTED_HARNESS 1
SINGLE_OUT="$CLI_OUT"
printf '%s\n' "$SR${TAB}c2-hm${TAB}c1-h" > "$CA/m3"
cli "$CA" "$SI_CLI" --manifest m3
expect_rc "3-column manifest" 1 "$CLI_RC" "$CLI_ERR"
assert_eq "$CLI_OUT" "$SINGLE_OUT"
case_end

case_begin "self-impl-5-column-manifest-judges-3-way" "bin/check-self-impl.sh"
printf '%s\n' "$SR${TAB}c2-hm${TAB}c1-h${TAB}c1-m${TAB}c0-b" "tests/bin/t.sh${TAB}c3-hm${TAB}c1-h${TAB}c1-m${TAB}c0-b" > "$CA/m5"
cli "$CA" "$SI_CLI" --manifest m5
expect_rc "5-column manifest: (e) passes, (f) blocks" 1 "$CLI_RC" "$CLI_OUT $CLI_ERR"
expect_codes "5-column manifest" "$CLI_OUT" SELF_IMPLEMENTED_HARNESS 1
has "5-column manifest names the (f) file" "$CLI_OUT" "tests/bin/t.sh"
case_end

case_begin "language-match-rejects-bad-argument-combinations" "bin/check-test-language-match.sh"
cli "$CA" "$LM_CLI" --rel "$LR" --head ll-head --base lr-base ll-staged
expect_rc "--base with one --head" 2 "$CLI_RC" "$CLI_ERR"
cli "$CA" "$LM_CLI" --rel "$LR" --head ll-head --head ll-up --head lr-base ll-staged
expect_rc "--head three times" 2 "$CLI_RC" "$CLI_ERR"
cli "$CA" "$LM_CLI" --declaration-only --rel "$LR" --head ll-head ll-staged
expect_rc "--declaration-only with --head" 2 "$CLI_RC" "$CLI_ERR"
case_end

case_begin "language-match-two-heads-judge-3-way" "bin/check-test-language-match.sh"
cli "$CA" "$LM_CLI" --rel "$LR" --head ll-head --head ll-up ll-staged
expect_rc "(l) via CLI: two heads, no base" 0 "$CLI_RC" "$CLI_OUT $CLI_ERR"
cli "$CA" "$LM_CLI" --rel "$LR" --head lr-head --head lr-up --base lr-base lr-staged
expect_rc "rename via CLI: two heads and a base" 0 "$CLI_RC" "$CLI_OUT $CLI_ERR"
case_end

case_begin "language-match-declaration-only-validates-only-the-exception" "bin/check-test-language-match.sh"
cli "$CA" "$LM_CLI" --declaration-only --rel "$LR" ll-extra
expect_rc "--declaration-only on a mismatching file" 0 "$CLI_RC" "$CLI_OUT $CLI_ERR"
expect_codes "--declaration-only on a mismatching file" "$CLI_OUT" TEST_LANGUAGE_MISMATCH 0
cli "$CA" "$LM_CLI" --declaration-only --rel "$LR" lm-bad
expect_rc "--declaration-only with an invalid exception" 1 "$CLI_RC" "$CLI_OUT $CLI_ERR"
expect_codes "--declaration-only with an invalid exception" "$CLI_OUT" INVALID_TEST_LANG_EXCEPTION 1
case_end

case_begin "language-match-single-head-output-unchanged" "bin/check-test-language-match.sh"
cli "$CA" "$LM_CLI" --rel "$LR" --head ll-up ll-extra
expect_rc "single --head" 1 "$CLI_RC" "$CLI_ERR"
expect_codes "single --head: h1 and x1 beyond one .js case" "$CLI_OUT" TEST_LANGUAGE_MISMATCH 1
has "single --head names the target" "$CLI_OUT" "bin/foo.js"
case_end
