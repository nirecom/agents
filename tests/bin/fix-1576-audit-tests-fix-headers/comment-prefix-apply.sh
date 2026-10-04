# Tests: bin/audit-tests.sh, bin/audit-tests-common.sh, bin/lib/test-frontmatter-fix.sh, bin/lib/test-frontmatter-constants.sh
# Tags: TL2, scope:issue-specific, fix-1576-test-frontmatter
# Sourced fragment — TC27-TC28 (#2500): --fix-headers reads and rewrites the header of
# each file's own registry commentPrefix. A fixture checkout whose table adds
# slash-lang (*.slt, "//"); the other language's prefix is a decoy that must stay put.
# Depends on caller for $REPO_ROOT, PASS/FAIL, pass(), fail(), run_in().

# shellcheck source=../test-language-registry/slash-header-fixture.sh
. "$REPO_ROOT/tests/bin/test-language-registry/slash-header-fixture.sh"

# slash_fix_fixture -> echoes a fixture checkout with bin/foo.sh, bin/bar.sh and two
# dispatchers whose real header is malformed (annotation) and whose decoy is not.
slash_fix_fixture() {
  local d co
  d="$(mktemp -d)"
  co="$d/co"
  slash_fx_checkout "$co" "$REPO_ROOT" bin/audit-tests.sh
  slash_write "$co/bin/foo.sh" '#!/usr/bin/env bash'
  slash_write "$co/bin/bar.sh" '#!/usr/bin/env bash'
  slash_write "$co/tests/bin/feature-1-slash.slt" '// Tests: bin/foo.sh (annotation)' \
    '# Tests: bin/bar.sh (decoy)' '// Tags: TL2, scope:issue-specific' 'echo hi'
  slash_write "$co/tests/bin/feature-2-hash.sh" '#!/usr/bin/env bash' '// Tests: bin/foo.sh (decoy)' \
    '# Tests: bin/bar.sh (annotation)' '# Tags: TL2, scope:issue-specific' 'echo hi'
  git -C "$co" add -A >/dev/null 2>&1
  git -C "$co" commit -q --no-verify -m init >/dev/null 2>&1
  echo "$co"
}

# TC27: the report classifies the prefix-matched header only.
C27="$(slash_fix_fixture)"
run_in "$C27" "$C27/bin/audit-tests.sh" --fix-headers --dry-run --offline
got27="$(printf '%s\n' "$OUT" | grep -E '^(FIX_|C:|MANUAL_REVIEW_REQUIRED)' | LC_ALL=C sort || true)"
want27="$(printf '%s\n' 'FIX_A: tests/bin/feature-1-slash.slt: bin/foo.sh' 'FIX_A: tests/bin/feature-2-hash.sh: bin/bar.sh' | LC_ALL=C sort)"
if [[ "$RC" -eq 0 && "$got27" == "$want27" ]]; then
  pass "TC27 --fix-headers reports // for .slt and # for .sh, never the decoy prefix"
else
  fail "TC27 --fix-headers reports // for .slt and # for .sh, never the decoy prefix" "rc=$RC got=<<$got27>> out=<<$OUT>> err=<<$ERR>>"
fi
rm -rf "$(dirname "$C27")"

# TC28: --apply rewrites that header in its own prefix; the decoy line is byte-identical.
C28="$(slash_fix_fixture)"
run_in "$C28" "$C28/bin/audit-tests.sh" --fix-headers --apply --offline
slt28="$(cat "$C28/tests/bin/feature-1-slash.slt")"
sh28="$(cat "$C28/tests/bin/feature-2-hash.sh")"
want_slt28="$(printf '%s\n' '// Tests: bin/foo.sh' '# Tests: bin/bar.sh (decoy)' '// Tags: TL2, scope:issue-specific' 'echo hi')"
want_sh28="$(printf '%s\n' '#!/usr/bin/env bash' '// Tests: bin/foo.sh (decoy)' '# Tests: bin/bar.sh' '# Tags: TL2, scope:issue-specific' 'echo hi')"
applied28="$(printf '%s\n' "$OUT" | grep '^APPLIED:' | LC_ALL=C sort || true)"
want_applied28="$(printf '%s\n' 'APPLIED: tests/bin/feature-1-slash.slt: // Tests: bin/foo.sh' 'APPLIED: tests/bin/feature-2-hash.sh: # Tests: bin/bar.sh' | LC_ALL=C sort)"
if [[ "$RC" -eq 0 && "$slt28" == "$want_slt28" && "$sh28" == "$want_sh28" && "$applied28" == "$want_applied28" ]]; then
  pass "TC28 --apply rewrites the // header of .slt and the # header of .sh; decoys untouched"
else
  fail "TC28 --apply rewrites the // header of .slt and the # header of .sh; decoys untouched" "rc=$RC slt=<<$slt28>> sh=<<$sh28>> applied=<<$applied28>> err=<<$ERR>>"
fi
rm -rf "$(dirname "$C28")"
