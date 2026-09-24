# Tests: bin/audit-tests.sh, bin/audit-tests-common.sh, bin/lib/test-frontmatter-fix.sh, bin/lib/test-frontmatter-constants.sh
# Tags: TL2, scope:issue-specific, fix-1576-test-frontmatter, fix-1782-normalize-token-glob
# Sourced fragment — TC11, TC12, TC22-TC26: glob-expansion and root-equivalent
# report-mode coverage (#1782). TC22/TC24-TC26 table-driven (round-4 gap C1).
# Depends on caller for $AUDIT, $AUDIT_COMMON, PASS/FAIL, pass(), fail(),
# make_fixture(), write_dispatcher(), run_in().

# TC11: "bin/*.sh" glob token must not silently expand to a real file.
R11="$(make_fixture)"
write_dispatcher "$R11" "feature-11-glob.sh" '# Tests: bin/*.sh (see all)'
run_in "$R11" "$AUDIT" --fix-headers --offline
if [[ "$OUT$ERR" == *"MANUAL_REVIEW_REQUIRED"* \
   && "$OUT$ERR" != *"FIX_A:"*"bin/foo.sh"* \
   && "$OUT$ERR" != *"FIX_A:"*"bin/bar.sh"* ]]; then
  pass "TC11 glob token bin/*.sh is not silently glob-expanded to a real file"
else
  fail "TC11 glob token bin/*.sh is not silently glob-expanded to a real file" "rc=$RC out=<<$OUT>> err=<<$ERR>>"
fi
rm -rf "$R11"

# TC12: bare "/" embedded in prose must not be accepted as a valid path.
R12="$(make_fixture)"
write_dispatcher "$R12" "feature-12-slash.sh" '# Tests: bin/foo.sh, clarify-intent CI-4 / workflow-init Path A1'
run_in "$R12" "$AUDIT" --fix-headers --offline
bad_line=0
if printf '%s\n' "$OUT" "$ERR" | grep -qxF "FIX_A: tests/bin/feature-12-slash.sh: /"; then
  bad_line=1
fi
if [[ "$bad_line" -eq 0 && "$OUT$ERR" == *"MANUAL_REVIEW_REQUIRED"* && "$OUT$ERR" == *"clarify-intent"* ]]; then
  pass "TC12 bare / embedded in prose is not accepted as a valid path"
else
  fail "TC12 bare / embedded in prose is not accepted as a valid path" "rc=$RC out=<<$OUT>> err=<<$ERR>> bad_line=$bad_line"
fi
rm -rf "$R12"

# TC23: same standalone "/" regression via audit-tests-common.sh (CPR-ORTH).
if [[ -f "$AUDIT_COMMON" ]]; then
  R23="$(make_fixture)"
  write_dispatcher "$R23" "check-bareroot.sh" '# Tests: bin/foo.sh, /'
  run_in "$R23" "$AUDIT_COMMON" --fix-headers
  if printf '%s\n' "$OUT" "$ERR" | grep -qxF "MANUAL_REVIEW_REQUIRED: tests/bin/check-bareroot.sh: /"; then
    pass "TC23 audit-tests-common.sh --fix-headers flags standalone / CSV token via MANUAL_REVIEW_REQUIRED (CPR-ORTH symmetry)"
  else
    fail "TC23 audit-tests-common.sh --fix-headers flags standalone / CSV token via MANUAL_REVIEW_REQUIRED (CPR-ORTH symmetry)" "rc=$RC out=<<$OUT>> err=<<$ERR>>"
  fi
  rm -rf "$R23"
fi

# TC24-TC26 (#1782 round-3 gap C1): boundary/negative-control regressions.
# Literal 5-member denylist in _is_root_like_token() — no path resolution.
# TC24 ("bin/."): non-root; TC25 ("tests/.."): multi-segment traversal;
# TC26 (absolute sandbox root): documented non-goals, not literal-denylist.
# TC22 ("./"): the fifth case-list member, positive control.
# RC==0 also asserted (gap C3) to catch crashes masking false-green "absent".
#
# __ROOT__ is substituted with the fixture root (TC26 needs the absolute path).
while IFS='|' read -r tc fname header token expect desc; do
  [[ -z "$tc" || "$tc" =~ ^[[:space:]]*# ]] && continue
  tc="${tc//[[:space:]]/}"
  fname="${fname//[[:space:]]/}"
  header="$(printf '%s' "$header" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  token="$(printf '%s' "$token" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  expect="${expect//[[:space:]]/}"
  desc="$(printf '%s' "$desc" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  root="$(make_fixture)"
  header="${header//__ROOT__/$root}"
  token="${token//__ROOT__/$root}"
  write_dispatcher "$root" "$fname" "# Tests: $header"
  run_in "$root" "$AUDIT" --fix-headers --offline
  rc_ok=0; [[ "$RC" -eq 0 ]] && rc_ok=1
  mrr_found=0
  if printf '%s\n' "$OUT" "$ERR" | grep -qxF "MANUAL_REVIEW_REQUIRED: tests/bin/$fname: $token"; then
    mrr_found=1
  fi
  ok=0
  if [[ "$rc_ok" -eq 1 ]]; then
    [[ "$expect" == "present" && "$mrr_found" -eq 1 ]] && ok=1
    [[ "$expect" == "absent" && "$mrr_found" -eq 0 ]] && ok=1
  fi
  if [[ "$ok" -eq 1 ]]; then
    pass "$desc"
  else
    fail "$desc" "rc=$RC rc_ok=$rc_ok mrr_found=$mrr_found expect=$expect out=<<$OUT>> err=<<$ERR>>"
  fi
  rm -rf "$root"
done <<'TABLE'
TC22 | feature-22-dotslash-standalone.sh | bin/foo.sh, ./ | ./ | present | TC22 standalone ./ CSV token is flagged via MANUAL_REVIEW_REQUIRED, not silently accepted as valid
TC24 | feature-24-bindot.sh | bin/., bin/foo.sh | bin/. | absent | TC24 bin/. (existing non-root directory) is accepted as a valid path, not flagged MANUAL_REVIEW_REQUIRED
TC25 | feature-25-testsdotdot.sh | tests/.., bin/foo.sh | tests/.. | absent | TC25 tests/.. (multi-segment traversal resolving to repo root) is accepted as a valid path — documented non-goal, not literal-denylist match
TC26 | feature-26-absroot.sh | __ROOT__, bin/foo.sh | __ROOT__ | absent | TC26 absolute path to the fixture's own sandbox root is accepted as a valid path — documented non-goal, not literal-denylist match
TABLE
