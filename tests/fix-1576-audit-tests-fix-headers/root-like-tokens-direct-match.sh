# Tests: bin/audit-tests.sh, bin/audit-tests-common.sh, bin/lib/test-frontmatter-fix.sh, bin/lib/test-frontmatter-constants.sh
# Tags: TL2, scope:issue-specific, fix-1576-test-frontmatter, fix-1782-normalize-token-glob
# tests/fix-1576-audit-tests-fix-headers/root-like-tokens-direct-match.sh
# Sourced fragment of tests/fix-1576-audit-tests-fix-headers.sh — NOT a
# standalone test file (no shebang execution; not discovered by
# tests/run-all.sh's `tests/*.sh` glob, which is non-recursive).
#
# TC13-TC17 (#1782): standalone-CSV-token root-equivalent coverage through
# classify_tests_header()/_rebuild_tests_value()'s direct-match branch
# (format-OK tokens per FRONTMATTER_TOKEN_VALID_RE bypass normalize_token()
# entirely), plus the no-over-exclusion regression guard (TC13).
#
# Depends on the caller (tests/fix-1576-audit-tests-fix-headers.sh) having
# already defined: $AUDIT, PASS/FAIL, pass(), fail(), make_fixture(),
# write_dispatcher(), run_in().

# TC13 (no-over-exclusion / normal-case regression guard): "./" appearing
# before the real path token must be skipped as root-equivalent WITHOUT
# breaking recognition of the following legitimate "bin/foo.sh" token.
R13="$(make_fixture)"
write_dispatcher "$R13" "feature-13-dotslash.sh" '# Tests: cd ./ then run bin/foo.sh (see notes)'
run_in "$R13" "$AUDIT" --fix-headers --offline
good_line=0
if printf '%s\n' "$OUT" "$ERR" | grep -qxF "FIX_A: tests/feature-13-dotslash.sh: bin/foo.sh"; then
  good_line=1
fi
bad_dotslash=0
if printf '%s\n' "$OUT" "$ERR" | grep -qxF "FIX_A: tests/feature-13-dotslash.sh: ./"; then
  bad_dotslash=1
fi
if [[ "$good_line" -eq 1 && "$bad_dotslash" -eq 0 ]]; then
  pass "TC13 ./ is skipped as root-equivalent without losing the real bin/foo.sh token"
else
  fail "TC13 ./ is skipped as root-equivalent without losing the real bin/foo.sh token" "rc=$RC out=<<$OUT>> err=<<$ERR>> good_line=$good_line bad_dotslash=$bad_dotslash"
fi
rm -rf "$R13"

# TC14-TC17 (#1782 root-equivalent coverage, table-driven per
# skills/_shared/test-design/parser-regex-tests.md): each row is a standalone
# CSV token from _is_root_like_token()'s five-token case list (all but "./",
# covered separately by TC22), combined with the real "bin/foo.sh" token, and
# run through the classify_tests_header()/_rebuild_tests_value() direct-match
# branch (format-OK per FRONTMATTER_TOKEN_VALID_RE, bypassing
# normalize_token() entirely). Each token always exists per `[[ -e ]]`, so the
# bug (pre-#1782) is that it is silently bucketed as CHR_TOKENS_OK — never
# printed by the report, i.e. the file produces zero diagnostic output.
# Fixed behavior routes it to MANUAL_REVIEW_REQUIRED. Positive assertion (gap
# #3 fix, applies to all four rows): require the exact MRR line for the token
# to be present — a weaker "filename appears somewhere" check would pass even
# if the token were silently accepted, since OK-bucket tokens are never
# printed at all.
while IFS='|' read -r tc fname token desc; do
  [[ -z "$tc" || "$tc" =~ ^[[:space:]]*# ]] && continue
  tc="${tc//[[:space:]]/}"
  fname="${fname//[[:space:]]/}"
  token="$(printf '%s' "$token" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  desc="$(printf '%s' "$desc" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  root="$(make_fixture)"
  write_dispatcher "$root" "$fname" "# Tests: bin/foo.sh, $token"
  run_in "$root" "$AUDIT" --fix-headers --offline
  mrr_found=0
  if printf '%s\n' "$OUT" "$ERR" | grep -qxF "MANUAL_REVIEW_REQUIRED: tests/$fname: $token"; then
    mrr_found=1
  fi
  if [[ "$mrr_found" -eq 1 ]]; then
    pass "$desc"
  else
    fail "$desc" "rc=$RC out=<<$OUT>> err=<<$ERR>> mrr_found=$mrr_found"
  fi
  rm -rf "$root"
done <<'TABLE'
TC14 | feature-14-bareroot.sh | / | TC14 standalone / CSV token is flagged via MANUAL_REVIEW_REQUIRED, not silently accepted as valid
TC15 | feature-15-dot.sh | . | TC15 standalone . CSV token is flagged via MANUAL_REVIEW_REQUIRED, not silently accepted as valid
TC16 | feature-16-dotdot.sh | .. | TC16 standalone .. CSV token is flagged via MANUAL_REVIEW_REQUIRED, not silently accepted as valid
TC17 | feature-17-dotdotslash.sh | ../ | TC17 standalone ../ CSV token is flagged via MANUAL_REVIEW_REQUIRED, not silently accepted as valid
TABLE
