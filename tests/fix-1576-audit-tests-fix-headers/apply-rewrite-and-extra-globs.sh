# Tests: bin/audit-tests.sh, bin/audit-tests-common.sh, bin/lib/test-frontmatter-fix.sh, bin/lib/test-frontmatter-constants.sh
# Tags: TL2, scope:issue-specific, fix-1576-test-frontmatter, fix-1782-normalize-token-glob
# tests/fix-1576-audit-tests-fix-headers/apply-rewrite-and-extra-globs.sh
# Sourced fragment of tests/fix-1576-audit-tests-fix-headers.sh — NOT a
# standalone test file (no shebang execution; not discovered by
# tests/run-all.sh's `tests/*.sh` glob, which is non-recursive).
#
# TC18-TC21 (#1782): --apply rewrite corruption checks (_rebuild_tests_value
# must not let a root-equivalent or glob token survive/silently-substitute
# into the rewritten header) plus additional glob-guard coverage beyond
# TC11's "*" ("?" and a pure bracket expression).
#
# Round-3 Codex test-coverage review (gap C2, addressed in this revision):
# TC18/TC19 each traced to a single actual outcome (unchanged +
# SKIP_APPLY_HAS_AC) and now assert only that outcome — the prior either/or
# assertion (rewrite-without-corruption OR unchanged-with-diagnostic) is
# removed. TC20/TC21 are refactored into a table-driven loop (gap C1); TC18/
# TC19 stay bespoke (byte-level before/after diffing of a real --apply run).
#
# Depends on the caller (tests/fix-1576-audit-tests-fix-headers.sh) having
# already defined: $AUDIT, PASS/FAIL, pass(), fail(), make_fixture(),
# write_dispatcher(), run_in().

# TC18 (#1782 apply-path corruption check): --apply must not let a
# root-equivalent token ("/") survive as a standalone CSV entry into the
# rewritten `# Tests:` header. The "(annotation)" suffix makes "bin/foo.sh"
# format-bad (-> FIX_A); the header also carries a bare "/" token via the
# direct-match branch. Traced through classify_tests_header()/
# _fix_headers_apply(): "/" is root-like, so normalize_token("/") returns ""
# (its skip-guard drops the only word), which routes "/" into CHR_TOKENS_MRR.
# _fix_headers_apply() checks `${#CHR_TOKENS_MRR[@]} -gt 0` BEFORE calling
# _rebuild_tests_value() and, when true, prints SKIP_APPLY_HAS_AC and returns
# without touching the file — so for this fixture the ONE actual outcome is
# always "unchanged + SKIP_APPLY_HAS_AC", never a rewrite. Round-3 Codex gap
# C2 fix: assert that single outcome only (no OR-branch). Sandboxed synthetic
# fixture only (never the real repo), same isolation pattern as TC2/TC4/TC7's
# --apply calls.
R18="$(make_fixture)"
write_dispatcher "$R18" "feature-18-apply-root.sh" '# Tests: bin/foo.sh (annotation), /'
before="$(cat "$R18/tests/feature-18-apply-root.sh")"
run_in "$R18" "$AUDIT" --fix-headers --apply --offline
after="$(cat "$R18/tests/feature-18-apply-root.sh")"
rc_ok=0; [[ "$RC" -eq 0 ]] && rc_ok=1
unchanged=0; [[ "$before" == "$after" ]] && unchanged=1
skip_diag_ok18=0
if printf '%s\n' "$OUT" "$ERR" | grep -qxF "SKIP_APPLY_HAS_AC: tests/feature-18-apply-root.sh"; then
  skip_diag_ok18=1
fi
if [[ "$rc_ok" -eq 1 && "$unchanged" -eq 1 && "$skip_diag_ok18" -eq 1 ]]; then
  pass "TC18 --apply is blocked by SKIP_APPLY_HAS_AC (root-equivalent / present) and leaves the file byte-identical"
else
  fail "TC18 --apply is blocked by SKIP_APPLY_HAS_AC (root-equivalent / present) and leaves the file byte-identical" "rc=$RC rc_ok=$rc_ok unchanged=$unchanged skip_diag_ok18=$skip_diag_ok18 out=<<$OUT>> err=<<$ERR>>"
fi
rm -rf "$R18"

# TC19 (#1782 apply-path corruption check): --apply must not silently
# substitute a real matching filename for a literal glob token ("bin/*.sh")
# during _rebuild_tests_value's rewrite. The "(annotation)" suffix again makes
# "bin/foo.sh" format-bad; "bin/*.sh" is the second CSV token. Traced through
# classify_tests_header()/_fix_headers_apply(): "bin/*.sh" is format-bad (the
# glob chars fail FRONTMATTER_TOKEN_VALID_RE), so normalize_token("bin/*.sh")
# hits its `*`/`?` skip-guard and returns "" — routing it into CHR_TOKENS_MRR
# exactly like TC18's "/". _fix_headers_apply()'s `${#CHR_TOKENS_MRR[@]} -gt 0`
# check fires first and prints SKIP_APPLY_HAS_AC without ever reaching
# _rebuild_tests_value() — so for this fixture the ONE actual outcome is
# always "unchanged + SKIP_APPLY_HAS_AC", never a rewrite (let alone a
# glob-corrupted one). Round-3 Codex gap C2 fix: assert that single outcome
# only (no OR-branch). Sandboxed synthetic fixture only.
R19="$(make_fixture)"
write_dispatcher "$R19" "feature-19-apply-glob.sh" '# Tests: bin/foo.sh (annotation), bin/*.sh'
before="$(cat "$R19/tests/feature-19-apply-glob.sh")"
run_in "$R19" "$AUDIT" --fix-headers --apply --offline
after="$(cat "$R19/tests/feature-19-apply-glob.sh")"
rc_ok=0; [[ "$RC" -eq 0 ]] && rc_ok=1
unchanged=0; [[ "$before" == "$after" ]] && unchanged=1
skip_diag_ok19=0
if printf '%s\n' "$OUT" "$ERR" | grep -qxF "SKIP_APPLY_HAS_AC: tests/feature-19-apply-glob.sh"; then
  skip_diag_ok19=1
fi
if [[ "$rc_ok" -eq 1 && "$unchanged" -eq 1 && "$skip_diag_ok19" -eq 1 ]]; then
  pass "TC19 --apply is blocked by SKIP_APPLY_HAS_AC (literal bin/*.sh glob token present) and leaves the file byte-identical"
else
  fail "TC19 --apply is blocked by SKIP_APPLY_HAS_AC (literal bin/*.sh glob token present) and leaves the file byte-identical" "rc=$RC rc_ok=$rc_ok unchanged=$unchanged skip_diag_ok19=$skip_diag_ok19 out=<<$OUT>> err=<<$ERR>>"
fi
rm -rf "$R19"

# TC20-TC21 (#1782 glob coverage, table-driven per
# skills/_shared/test-design/parser-regex-tests.md): normalize_token()'s
# skip-guard checks for both "*" and "?"
# (`[[ "$word" == *"*"* || "$word" == *"?"* ]]`); TC11 (root-like-tokens-report.sh)
# only covers "*". TC20 covers "?" ("bin/fo?.sh" glob-matches the fixture's
# real bin/foo.sh). TC21 covers a pure bracket-expression glob containing
# NEITHER "*" NOR "?" ("bin/[bf]ar.sh"), to genuinely isolate unguarded
# bracket-expansion — the skip-guard only special-cases literal "*"/"?"
# characters, so a token built only from "[...]" bypasses the guard entirely
# and is caught solely by whatever the actual #1782 fix does to stop unquoted
# `for word in $pre` from invoking pathname expansion ("bin/[bf]ar.sh"
# glob-matches only the fixture's real bin/bar.sh; bin/far.sh does not
# exist). Without the fix, both silently glob-expand and resolve to their
# respective real file instead of being flagged for manual review.
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
