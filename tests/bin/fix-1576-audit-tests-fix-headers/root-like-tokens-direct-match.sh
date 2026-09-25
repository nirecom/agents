# Tests: bin/audit-tests.sh, bin/audit-tests-common.sh, bin/lib/test-frontmatter-fix.sh, bin/lib/test-frontmatter-constants.sh
# Tags: TL2, scope:issue-specific, fix-1576-test-frontmatter, fix-1782-normalize-token-glob
# Sourced fragment — TC13-TC17: standalone-CSV root-equivalent coverage (#1782).
# Direct-match branch (format-OK tokens bypass normalize_token()).
# Depends on caller for $AUDIT, PASS/FAIL, pass(), fail(), make_fixture(),
# write_dispatcher(), run_in().

# TC13: "./" skipped as root-equivalent without losing the real bin/foo.sh token.
R13="$(make_fixture)"
write_dispatcher "$R13" "feature-13-dotslash.sh" '# Tests: cd ./ then run bin/foo.sh (see notes)'
run_in "$R13" "$AUDIT" --fix-headers --offline
good_line=0
if printf '%s\n' "$OUT" "$ERR" | grep -qxF "FIX_A: tests/bin/feature-13-dotslash.sh: bin/foo.sh"; then
  good_line=1
fi
bad_dotslash=0
if printf '%s\n' "$OUT" "$ERR" | grep -qxF "FIX_A: tests/bin/feature-13-dotslash.sh: ./"; then
  bad_dotslash=1
fi
if [[ "$good_line" -eq 1 && "$bad_dotslash" -eq 0 ]]; then
  pass "TC13 ./ is skipped as root-equivalent without losing the real bin/foo.sh token"
else
  fail "TC13 ./ is skipped as root-equivalent without losing the real bin/foo.sh token" "rc=$RC out=<<$OUT>> err=<<$ERR>> good_line=$good_line bad_dotslash=$bad_dotslash"
fi
rm -rf "$R13"

# TC14-TC17: table-driven — each of the 4 remaining _is_root_like_token() members
# ("/", ".", "..", "../") is flagged MANUAL_REVIEW_REQUIRED via direct-match branch.
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
  if printf '%s\n' "$OUT" "$ERR" | grep -qxF "MANUAL_REVIEW_REQUIRED: tests/bin/$fname: $token"; then
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
