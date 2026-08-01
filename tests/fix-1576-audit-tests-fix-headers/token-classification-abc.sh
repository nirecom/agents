# Tests: bin/audit-tests.sh, bin/audit-tests-common.sh, bin/lib/test-frontmatter-fix.sh, bin/lib/test-frontmatter-constants.sh
# Tags: TL2, scope:issue-specific, fix-1576-test-frontmatter, fix-1782-normalize-token-glob
# tests/fix-1576-audit-tests-fix-headers/token-classification-abc.sh
# Sourced fragment of tests/fix-1576-audit-tests-fix-headers.sh — NOT a
# standalone test file (no shebang execution; not discovered by
# tests/run-all.sh's `tests/*.sh` glob, which is non-recursive).
#
# TC1-TC10: original #1576 A/B/C token classification coverage —
# format-invalid (A), renamed (B), and deleted (C) tokens, multi-paren
# handling, and audit-tests-common.sh --fix-headers symmetry (CPR-5).
#
# Depends on the caller (tests/fix-1576-audit-tests-fix-headers.sh) having
# already defined: $AUDIT, $AUDIT_COMMON, PASS/FAIL, pass(), fail(),
# make_fixture(), write_dispatcher(), run_in().

# TC1: A-token (bracket annotation — format-invalid) report mode => FIX_A:, file unchanged
R1="$(make_fixture)"
write_dispatcher "$R1" "feature-1-a.sh" '# Tests: bin/foo.sh (annotation)'
before="$(cat "$R1/tests/feature-1-a.sh")"
run_in "$R1" "$AUDIT" --dry-run --fix-headers --offline
after="$(cat "$R1/tests/feature-1-a.sh")"
if [[ "$OUT$ERR" == *"FIX_A:"* && "$before" == "$after" ]]; then
  pass "TC1 A-token report mode emits FIX_A and leaves file unchanged"
else
  fail "TC1 A-token report mode emits FIX_A and leaves file unchanged" "rc=$RC out=<<$OUT>> err=<<$ERR>> changed=$([[ "$before" != "$after" ]] && echo yes || echo no)"
fi
rm -rf "$R1"

# TC2: A-token --fix-headers --apply => header normalized, exec bit preserved
R2="$(make_fixture)"
write_dispatcher "$R2" "feature-2-a.sh" '# Tests: bin/foo.sh (annotation)'
run_in "$R2" "$AUDIT" --fix-headers --apply --offline
new_hdr="$(grep -m1 -E '^# Tests:' "$R2/tests/feature-2-a.sh" || true)"
is_exec=0; [[ -x "$R2/tests/feature-2-a.sh" ]] && is_exec=1
if [[ "$new_hdr" == '# Tests: bin/foo.sh' && "$is_exec" -eq 1 ]]; then
  pass "TC2 A-token --apply normalizes header and preserves exec bit"
else
  fail "TC2 A-token --apply normalizes header and preserves exec bit" "rc=$RC hdr=<<$new_hdr>> exec=$is_exec out=<<$OUT>> err=<<$ERR>>"
fi
rm -rf "$R2"

# TC3: B-token (renamed path) --fix-headers => FIX_B: <old> -> <new>
# Create bin/old.sh, reference it, then git-rename to bin/new.sh so rename
# tracking can resolve old -> new.
R3="$(make_fixture)"
echo '#!/usr/bin/env bash' > "$R3/bin/old.sh"
git -C "$R3" add -A >/dev/null 2>&1
git -C "$R3" commit -q --no-verify -m addold >/dev/null 2>&1
git -C "$R3" mv bin/old.sh bin/new.sh >/dev/null 2>&1
git -C "$R3" commit -q --no-verify -m rename >/dev/null 2>&1
write_dispatcher "$R3" "feature-3-b.sh" '# Tests: bin/old.sh'
run_in "$R3" "$AUDIT" --dry-run --fix-headers --offline
if [[ "$OUT$ERR" == *"FIX_B:"* && "$OUT$ERR" == *"bin/old.sh"* && "$OUT$ERR" == *"bin/new.sh"* ]]; then
  pass "TC3 B-token report emits FIX_B old -> new"
else
  fail "TC3 B-token report emits FIX_B old -> new" "rc=$RC out=<<$OUT>> err=<<$ERR>>"
fi
rm -rf "$R3"

# TC4: A-flag mixed with C-token --fix-headers --apply => SKIP_APPLY_HAS_A, file unchanged
# Token is format-invalid (A, bracket) AND path-deleted (C). --apply must not rewrite.
R4="$(make_fixture)"
write_dispatcher "$R4" "feature-4-ac.sh" '# Tests: bin/deleted.sh (gone)'
before="$(cat "$R4/tests/feature-4-ac.sh")"
run_in "$R4" "$AUDIT" --fix-headers --apply --offline
after="$(cat "$R4/tests/feature-4-ac.sh")"
if [[ "$OUT$ERR" == *"SKIP_APPLY_HAS_A"* && "$before" == "$after" ]]; then
  pass "TC4 A-flag present blocks --apply rewrite (SKIP_APPLY_HAS_A)"
else
  fail "TC4 A-flag present blocks --apply rewrite (SKIP_APPLY_HAS_A)" "rc=$RC out=<<$OUT>> err=<<$ERR>> changed=$([[ "$before" != "$after" ]] && echo yes || echo no)"
fi
rm -rf "$R4"

# TC5: prose words only (0 path-like tokens) => MANUAL_REVIEW_REQUIRED
R5="$(make_fixture)"
write_dispatcher "$R5" "feature-5-prose.sh" '# Tests: some prose words here'
run_in "$R5" "$AUDIT" --dry-run --fix-headers --offline
if [[ "$OUT$ERR" == *"MANUAL_REVIEW_REQUIRED"* ]]; then
  pass "TC5 zero path-like tokens yields MANUAL_REVIEW_REQUIRED"
else
  fail "TC5 zero path-like tokens yields MANUAL_REVIEW_REQUIRED" "rc=$RC out=<<$OUT>> err=<<$ERR>>"
fi
rm -rf "$R5"

# TC6: multi-paren => only first token survives normalize (report shows a.js only)
R6="$(make_fixture)"
echo '// a' > "$R6/bin/a.js"
echo '// b' > "$R6/bin/b.js"
git -C "$R6" add -A >/dev/null 2>&1
git -C "$R6" commit -q --no-verify -m addjs >/dev/null 2>&1
write_dispatcher "$R6" "feature-6-multiparen.sh" '# Tests: bin/a.js (note) bin/b.js (note2)'
run_in "$R6" "$AUDIT" --dry-run --fix-headers --offline
if [[ "$OUT$ERR" == *"bin/a.js"* && "$OUT$ERR" != *"bin/b.js"* ]]; then
  pass "TC6 multi-paren normalize keeps only first token (a.js), drops b.js"
else
  fail "TC6 multi-paren normalize keeps only first token (a.js), drops b.js" "rc=$RC out=<<$OUT>> err=<<$ERR>>"
fi
rm -rf "$R6"

# TC7: multi-paren --fix-headers --apply => SKIP_APPLY_MULTI_PAREN, file unchanged
R7="$(make_fixture)"
write_dispatcher "$R7" "feature-7-multiparen.sh" '# Tests: bin/a.js (note) bin/b.js (note2)'
before="$(cat "$R7/tests/feature-7-multiparen.sh")"
run_in "$R7" "$AUDIT" --fix-headers --apply --offline
after="$(cat "$R7/tests/feature-7-multiparen.sh")"
if [[ "$OUT$ERR" == *"SKIP_APPLY_MULTI_PAREN"* && "$before" == "$after" ]]; then
  pass "TC7 multi-paren --apply is skipped (SKIP_APPLY_MULTI_PAREN)"
else
  fail "TC7 multi-paren --apply is skipped (SKIP_APPLY_MULTI_PAREN)" "rc=$RC out=<<$OUT>> err=<<$ERR>> changed=$([[ "$before" != "$after" ]] && echo yes || echo no)"
fi
rm -rf "$R7"

# TC8: audit-tests-common.sh --fix-headers A-report (CPR-5 symmetry)
if [[ ! -f "$AUDIT_COMMON" ]]; then
  fail "TC8 audit-tests-common.sh --fix-headers symmetry" "script not found: $AUDIT_COMMON"
else
  R8="$(make_fixture)"
  # common script targets non-feature-NNN files.
  write_dispatcher "$R8" "check-something.sh" '# Tests: bin/foo.sh (annotation)'
  before="$(cat "$R8/tests/check-something.sh")"
  run_in "$R8" "$AUDIT_COMMON" --fix-headers
  after="$(cat "$R8/tests/check-something.sh")"
  if [[ "$OUT$ERR" == *"FIX_A:"* && "$before" == "$after" ]]; then
    pass "TC8 audit-tests-common.sh --fix-headers reports FIX_A without rewriting"
  else
    fail "TC8 audit-tests-common.sh --fix-headers reports FIX_A without rewriting" "rc=$RC out=<<$OUT>> err=<<$ERR>>"
  fi
  rm -rf "$R8"
fi

# TC9: audit-tests-common.sh --fix-headers B-token (CPR-5 symmetry)
if [[ -f "$AUDIT_COMMON" ]]; then
  R9="$(make_fixture)"
  echo '#!/usr/bin/env bash' > "$R9/bin/old.sh"
  git -C "$R9" add -A >/dev/null 2>&1
  git -C "$R9" commit -q --no-verify -m addold >/dev/null 2>&1
  git -C "$R9" mv bin/old.sh bin/new.sh >/dev/null 2>&1
  git -C "$R9" commit -q --no-verify -m rename >/dev/null 2>&1
  write_dispatcher "$R9" "check-renamed.sh" '# Tests: bin/old.sh'
  run_in "$R9" "$AUDIT_COMMON" --fix-headers
  if [[ "$OUT$ERR" == *"FIX_B:"* ]]; then
    pass "TC9 audit-tests-common.sh --fix-headers reports FIX_B for renamed path"
  else
    fail "TC9 audit-tests-common.sh --fix-headers reports FIX_B for renamed path" "rc=$RC out=<<$OUT>> err=<<$ERR>>"
  fi
  rm -rf "$R9"
fi

# TC10: audit-tests-common.sh --fix-headers C-token (path deleted, no rename) (CPR-5 symmetry)
if [[ -f "$AUDIT_COMMON" ]]; then
  R10="$(make_fixture)"
  write_dispatcher "$R10" "check-orphan.sh" '# Tests: bin/deleted.sh'
  run_in "$R10" "$AUDIT_COMMON" --fix-headers
  # C-class: path missing, no rename => should report as orphan/missing
  if [[ "$OUT$ERR" == *"MISSING"* || "$OUT$ERR" == *"C:"* || "$OUT$ERR" == *"orphan"* || $RC -ne 0 ]]; then
    pass "TC10 audit-tests-common.sh --fix-headers identifies C-token (deleted path)"
  else
    fail "TC10 audit-tests-common.sh --fix-headers identifies C-token (deleted path)" "rc=$RC out=<<$OUT>> err=<<$ERR>>"
  fi
  rm -rf "$R10"
fi
