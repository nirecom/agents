# Tests: bin/audit-tests.sh, bin/audit-tests-common.sh, bin/lib/test-frontmatter-fix.sh, bin/lib/test-frontmatter-constants.sh
# Tags: TL2, scope:issue-specific, fix-1576-test-frontmatter
# Sourced fragment — TC29-TC32 (#2372): `_fix_headers_apply <file> [<dst>]`. With
# <dst> the header is classified on <file> (PWD = repo root) but written to <dst>;
# <file> stays byte-identical and the output wording is unchanged. The 1-arg form
# still rewrites in place. Stage 1 hands <dst> as a pre-made copy of <file>.
# Depends on caller for $REPO_ROOT, PASS/FAIL, pass(), fail(), make_fixture(), write_dispatcher().

# fha_call <root> <args...> — runs _fix_headers_apply in <root>; sets OUT and RC.
fha_call() {
  local root="$1"
  shift
  set +e
  OUT="$(cd "$root" && . "$REPO_ROOT/bin/lib/test-frontmatter-fix.sh" && _fix_headers_apply "$@" 2>&1)"
  RC=$?
  set -e
}

# TC29: a fixable header is written to <dst>; <file> is untouched.
case_begin "tc29-apply-dst-writes-dst-only" "bin/lib/test-frontmatter-fix.sh"
D29="$(make_fixture)"
write_dispatcher "$D29" feature-1-dst.sh '# Tests: bin/foo.sh (annotation)'
git -C "$D29" add -A >/dev/null 2>&1
git -C "$D29" commit -q --no-verify -m fixture >/dev/null 2>&1
src29_before="$(cat "$D29/tests/bin/feature-1-dst.sh")"
mkdir -p "$D29/.work"
cp "$D29/tests/bin/feature-1-dst.sh" "$D29/.work/feature-1-dst.sh"
fha_call "$D29" tests/bin/feature-1-dst.sh "$D29/.work/feature-1-dst.sh"
want_dst29="$(printf '%s\n' '#!/usr/bin/env bash' '# Tests: bin/foo.sh' '# Tags: TL2, scope:issue-specific' 'echo hi')"
if [[ "$RC" -eq 0 && "$OUT" == "APPLIED: tests/bin/feature-1-dst.sh: # Tests: bin/foo.sh" \
  && "$(cat "$D29/.work/feature-1-dst.sh")" == "$want_dst29" \
  && "$(cat "$D29/tests/bin/feature-1-dst.sh")" == "$src29_before" ]]; then
  pass "TC29 _fix_headers_apply <file> <dst> writes the fixed header to dst only, same APPLIED line"
else
  fail "TC29 _fix_headers_apply <file> <dst> writes the fixed header to dst only, same APPLIED line" "rc=$RC out=<<$OUT>> dst=<<$(cat "$D29/.work/feature-1-dst.sh")>> src=<<$(cat "$D29/tests/bin/feature-1-dst.sh")>>"
fi
rm -rf "$D29"
case_end

# TC30: a multi-paren header still prints SKIP_APPLY_MULTI_PAREN; neither file changes.
case_begin "tc30-apply-dst-multi-paren-skip" "bin/lib/test-frontmatter-fix.sh"
D30="$(make_fixture)"
write_dispatcher "$D30" feature-1-mp.sh '# Tests: bin/foo.sh (a) (b)'
src30_before="$(cat "$D30/tests/bin/feature-1-mp.sh")"
mkdir -p "$D30/.work"
cp "$D30/tests/bin/feature-1-mp.sh" "$D30/.work/feature-1-mp.sh"
fha_call "$D30" tests/bin/feature-1-mp.sh "$D30/.work/feature-1-mp.sh"
if [[ "$RC" -eq 0 && "$OUT" == "SKIP_APPLY_MULTI_PAREN: tests/bin/feature-1-mp.sh" \
  && "$(cat "$D30/.work/feature-1-mp.sh")" == "$src30_before" \
  && "$(cat "$D30/tests/bin/feature-1-mp.sh")" == "$src30_before" ]]; then
  pass "TC30 a multi-paren header with <dst> is skipped with the same wording; file and dst unchanged"
else
  fail "TC30 a multi-paren header with <dst> is skipped with the same wording; file and dst unchanged" "rc=$RC out=<<$OUT>>"
fi
rm -rf "$D30"
case_end

# TC31: a clean header prints nothing and leaves the dst copy as it was.
case_begin "tc31-apply-dst-clean-header" "bin/lib/test-frontmatter-fix.sh"
D31="$(make_fixture)"
write_dispatcher "$D31" feature-1-clean.sh '# Tests: bin/foo.sh'
src31_before="$(cat "$D31/tests/bin/feature-1-clean.sh")"
mkdir -p "$D31/.work"
cp "$D31/tests/bin/feature-1-clean.sh" "$D31/.work/feature-1-clean.sh"
fha_call "$D31" tests/bin/feature-1-clean.sh "$D31/.work/feature-1-clean.sh"
if [[ "$RC" -eq 0 && -z "$OUT" && "$(cat "$D31/.work/feature-1-clean.sh")" == "$src31_before" ]]; then
  pass "TC31 a clean header with <dst> prints nothing and leaves dst as copied"
else
  fail "TC31 a clean header with <dst> prints nothing and leaves dst as copied" "rc=$RC out=<<$OUT>>"
fi
rm -rf "$D31"
case_end

# TC32: the 1-arg form still rewrites <file> in place, keeping the exec bit.
case_begin "tc32-apply-one-arg-in-place" "bin/lib/test-frontmatter-fix.sh"
D32="$(make_fixture)"
write_dispatcher "$D32" feature-1-inplace.sh '# Tests: bin/foo.sh (annotation)'
fha_call "$D32" tests/bin/feature-1-inplace.sh
want32="$(printf '%s\n' '#!/usr/bin/env bash' '# Tests: bin/foo.sh' '# Tags: TL2, scope:issue-specific' 'echo hi')"
if [[ "$RC" -eq 0 && "$OUT" == "APPLIED: tests/bin/feature-1-inplace.sh: # Tests: bin/foo.sh" \
  && "$(cat "$D32/tests/bin/feature-1-inplace.sh")" == "$want32" && -x "$D32/tests/bin/feature-1-inplace.sh" ]]; then
  pass "TC32 _fix_headers_apply <file> (1-arg) still rewrites in place"
else
  fail "TC32 _fix_headers_apply <file> (1-arg) still rewrites in place" "rc=$RC out=<<$OUT>> file=<<$(cat "$D32/tests/bin/feature-1-inplace.sh")>>"
fi
rm -rf "$D32"
case_end
