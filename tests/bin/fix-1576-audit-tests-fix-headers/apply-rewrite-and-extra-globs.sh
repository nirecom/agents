# Tests: bin/audit-tests.sh, bin/audit-tests-common.sh, bin/lib/test-frontmatter-fix.sh, bin/lib/test-frontmatter-constants.sh
# Tags: TL2, scope:issue-specific, fix-1576-test-frontmatter, fix-1782-normalize-token-glob
# Sourced fragment — TC18-TC21: --apply rewrite corruption checks (#1782).
# TC18: "/" root-equiv → SKIP_APPLY_HAS_AC. TC19: "bin/*.sh" glob → SKIP_APPLY_HAS_AC.
# TC20-TC21: table-driven "?" and bracket-expression glob guard.
# Depends on caller for $AUDIT, PASS/FAIL, pass(), fail(), make_fixture(),
# write_dispatcher(), run_in().

# TC18 (#1782): root-equivalent token "/" forces SKIP_APPLY_HAS_AC (no rewrite).
R18="$(make_fixture)"
write_dispatcher "$R18" "feature-18-apply-root.sh" '# Tests: bin/foo.sh (annotation), /'
before="$(cat "$R18/tests/bin/feature-18-apply-root.sh")"
run_in "$R18" "$AUDIT" --fix-headers --apply --offline
after="$(cat "$R18/tests/bin/feature-18-apply-root.sh")"
rc_ok=0; [[ "$RC" -eq 0 ]] && rc_ok=1
unchanged=0; [[ "$before" == "$after" ]] && unchanged=1
skip_diag_ok18=0
if printf '%s\n' "$OUT" "$ERR" | grep -qxF "SKIP_APPLY_HAS_AC: tests/bin/feature-18-apply-root.sh"; then
  skip_diag_ok18=1
fi
if [[ "$rc_ok" -eq 1 && "$unchanged" -eq 1 && "$skip_diag_ok18" -eq 1 ]]; then
  pass "TC18 --apply is blocked by SKIP_APPLY_HAS_AC (root-equivalent / present) and leaves the file byte-identical"
else
  fail "TC18 --apply is blocked by SKIP_APPLY_HAS_AC (root-equivalent / present) and leaves the file byte-identical" "rc=$RC rc_ok=$rc_ok unchanged=$unchanged skip_diag_ok18=$skip_diag_ok18 out=<<$OUT>> err=<<$ERR>>"
fi
rm -rf "$R18"

# TC19 (#1782): glob token "bin/*.sh" forces SKIP_APPLY_HAS_AC (no rewrite).
R19="$(make_fixture)"
write_dispatcher "$R19" "feature-19-apply-glob.sh" '# Tests: bin/foo.sh (annotation), bin/*.sh'
before="$(cat "$R19/tests/bin/feature-19-apply-glob.sh")"
run_in "$R19" "$AUDIT" --fix-headers --apply --offline
after="$(cat "$R19/tests/bin/feature-19-apply-glob.sh")"
rc_ok=0; [[ "$RC" -eq 0 ]] && rc_ok=1
unchanged=0; [[ "$before" == "$after" ]] && unchanged=1
skip_diag_ok19=0
if printf '%s\n' "$OUT" "$ERR" | grep -qxF "SKIP_APPLY_HAS_AC: tests/bin/feature-19-apply-glob.sh"; then
  skip_diag_ok19=1
fi
if [[ "$rc_ok" -eq 1 && "$unchanged" -eq 1 && "$skip_diag_ok19" -eq 1 ]]; then
  pass "TC19 --apply is blocked by SKIP_APPLY_HAS_AC (literal bin/*.sh glob token present) and leaves the file byte-identical"
else
  fail "TC19 --apply is blocked by SKIP_APPLY_HAS_AC (literal bin/*.sh glob token present) and leaves the file byte-identical" "rc=$RC rc_ok=$rc_ok unchanged=$unchanged skip_diag_ok19=$skip_diag_ok19 out=<<$OUT>> err=<<$ERR>>"
fi
rm -rf "$R19"

# TC20-TC21 (#1782): table-driven glob-guard coverage ("?" and bracket-expression).
while IFS='|' read -r tc fname token neg desc; do
  [[ -z "$tc" || "$tc" =~ ^[[:space:]]*# ]] && continue
  tc="${tc//[[:space:]]/}"
  fname="${fname//[[:space:]]/}"
  token="$(printf '%s' "$token" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  neg="${neg//[[:space:]]/}"
  desc="$(printf '%s' "$desc" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  root="$(make_fixture)"
  write_dispatcher "$root" "$fname" "# Tests: $token (see all)"
  run_in "$root" "$AUDIT" --fix-headers --offline
  if [[ "$OUT$ERR" == *"MANUAL_REVIEW_REQUIRED"* && "$OUT$ERR" != *"FIX_A:"*"$neg"* ]]; then
    pass "$desc"
  else
    fail "$desc" "rc=$RC out=<<$OUT>> err=<<$ERR>>"
  fi
  rm -rf "$root"
done <<'TABLE'
TC20 | feature-20-glob-question.sh | bin/fo?.sh | bin/foo.sh | TC20 ? glob token bin/fo?.sh is not silently glob-expanded to a real file
TC21 | feature-21-glob-bracket.sh | bin/[bf]ar.sh | bin/bar.sh | TC21 bracket-expression glob token bin/[bf]ar.sh (no */?) is not silently glob-expanded to a real file
TABLE
