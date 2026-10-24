# Group: two non-adjacent orphans, a shared end line, a file changed after the verdict or during the syntax-check
# Tests: bin/lib/test-retire-predicate.sh, bin/lib/test-retire-predicate/orphan-removal.sh
# Tags: TL2, bin, case-markers, audit-tests, js, pytest, pester, scope:issue-specific
# Sourced by tests/bin/feature-2502-retire-per-case.sh (BASE, fresh, retire, survivors_kept and
# the parse helpers come from there).

# TWO: BASE with five-case samples alpha, gone, beta, lost, gamma — gone and lost target
# bin/gone.sh, so the two orphan cases are separated by beta. Each sample keeps BASE's prologue.
TWO="$TMPBASE/two-base"
rm -rf "$TWO"
cp -R "$BASE" "$TWO"
{
  printf '%s\n' '#!/usr/bin/env bash' "$FX_TESTS" "$FX_TAGS" 'set -u' 'source "$(dirname "$0")/../lib/harness.sh"'
  for c in alpha:a gone:gone beta:b lost:gone gamma:a; do sh_case "${c%%:*}" "${c#*:}"; done
} >"$TWO/$SH_REL"
{
  sed -n '1,/^    return 1$/p' "$BASE/$PY_REL"
  for c in alpha:a gone:gone beta:b lost:gone gamma:a; do
    printf '\n\n%s("bin/%s.sh")\ndef test_%s():\n    assert helper_alpha() == 1\n' '@pytest.mark.target' "${c#*:}" "${c%%:*}"
  done
} >"$TWO/$PY_REL"
{
  sed -n '1,/^}$/p' "$BASE/$PS_REL"
  for c in alpha:a gone:gone beta:b lost:gone gamma:a; do
    printf "\nDescribe '%s' -Tag 'target:bin/%s.sh' {\n    It 'uses alpha' { Get-Alpha | Should -Be 1 }\n}\n" "${c%%:*}" "${c#*:}"
  done
} >"$TWO/$PS_REL"
{
  sed -n '1,/^}$/p' "$BASE/$JS_REL"
  for c in alpha:a gone:gone beta:b lost:gone gamma:a; do
    printf '\ncaseBegin("%s", "bin/%s.sh");\ntest("%s", () => {\n  assert.strictEqual(helperAlpha(), 1);\n});\ncaseEnd();\n' "${c%%:*}" "${c#*:}" "${c%%:*}"
  done
} >"$TWO/$JS_REL"
git -C "$TWO" add -A >/dev/null
git -C "$TWO" commit -q -m two-orphans

# check_two_orphans <label> <rel> <parse-fn> <case-line-regex> <name-prefix> — both
# non-adjacent orphans are cut and named, the three survivors stay, the file parses and is staged.
check_two_orphans() {
  local label="$1" rel="$2" parse="$3" case_re="$4" pfx="$5" co out
  co="$TMPBASE/two-$label"
  rm -rf "$co"
  cp -R "$TWO" "$co"
  out="$(retire "$co" "$rel" -)"
  has_line "$label: two orphans found in case mode" "$out" "VERDICT=partial-orphan MODE=case ORPHANS=1 3"
  has_line "$label: removal rc 0" "$out" "RC=0"
  has_line "$label: removal names ${pfx}gone" "$out" "${pfx}gone"
  has_line "$label: removal names ${pfx}lost" "$out" "${pfx}lost"
  if "$parse" "$co/$rel"; then pass "$label: the rewritten file parses"; else fail "$label: the rewritten file parses" "$parse failed / $(head -c 200 "$TMPBASE/retire.err")"; fi
  assert_eq "$label case lines: $(grep -E "$case_re" "$co/$rel" | grep -oE "(alpha|gone|beta|lost|gamma)" | tr '\n' ' ')" \
    "$label case lines: alpha beta gamma "
  survivors_kept "$label" "$TWO/$rel" "$co/$rel"
  assert_eq "$label staged: $(git -C "$co" diff --cached --name-only)" "$label staged: $rel"
}

case_begin "two-non-adjacent-orphans-removed" "bin/lib/test-retire-predicate/orphan-removal.sh"
check_two_orphans bash "$SH_REL" bash_parses "^$MB " ""
check_two_orphans js "$JS_REL" js_parses '^caseBegin\(' ""
if command -v uv >/dev/null 2>&1; then check_two_orphans pytest "$PY_REL" py_parses '^def test_' test_; else skip "pytest two orphans: uv not available"; fi
if command -v pwsh >/dev/null 2>&1; then check_two_orphans pester "$PS_REL" ps_parses "^Describe '" ""; else skip "pester two orphans: pwsh not available"; fi
case_end

# check_shared_kept <label> <checkout> <rel> — the orphan case's end line also holds a live
# statement, so the reader reads the file malformed: file mode, no orphan, the removal fails
# closed, and the file bytes and the index stay as they were.
check_shared_kept() {
  local label="$1" co="$2" rel="$3" out idx
  git -C "$co" add -A >/dev/null
  git -C "$co" commit -q -m shared-line
  cp "$co/$rel" "$TMPBASE/shared-$label.snap"
  idx="$(git -C "$co" ls-files -s -- "$rel")"
  out="$(retire "$co" "$rel" -)"
  has_line "$label: the shared end line reads malformed, so file mode with no orphan" "$out" "VERDICT=alive MODE=file ORPHANS="
  has_line "$label: the removal fails closed" "$out" "RC=1"
  if cmp -s "$TMPBASE/shared-$label.snap" "$co/$rel"; then pass "$label: file bytes unchanged"; else fail "$label: file bytes unchanged" "$(diff "$TMPBASE/shared-$label.snap" "$co/$rel" | head -c 300)"; fi
  assert_eq "$label index entry: $(git -C "$co" ls-files -s -- "$rel")" "$label index entry: $idx"
  assert_eq "$label live statement left: $(grep -c 'shared = 1\|SHARED=1\|touch survivor' "$co/$rel"), staged [$(git -C "$co" diff --cached --name-only)]" \
    "$label live statement left: 1, staged []"
}

case_begin "shared-end-line-not-cut" "bin/lib/test-retire-predicate/orphan-removal.sh"
CO="$(fresh sh-shared)"
{
  printf '%s\n' '#!/usr/bin/env bash' "$FX_TESTS" "$FX_TAGS" 'set -u' 'source "$(dirname "$0")/../lib/harness.sh"'
  sh_case alpha a
  printf '\n%s "gone" "bin/gone.sh"\npass "gone"\n%s ; SHARED=1\n' "$MB" "$ME"
  sh_case beta b
} >"$CO/$SH_REL"
check_shared_kept bash "$CO" "$SH_REL"
# An or-list after the end marker runs a side effect too: only `|| true` belongs to the marker.
CO="$(fresh sh-or-list)"
{
  printf '%s\n' '#!/usr/bin/env bash' "$FX_TESTS" "$FX_TAGS" 'set -u' 'source "$(dirname "$0")/../lib/harness.sh"'
  sh_case alpha a
  printf '\n%s "gone" "bin/gone.sh"\npass "gone"\n%s || touch survivor\n' "$MB" "$ME"
  sh_case beta b
} >"$CO/$SH_REL"
check_shared_kept bash-or-list "$CO" "$SH_REL"
if command -v pwsh >/dev/null 2>&1; then
  CO="$(fresh ps-shared)"
  {
    sed -n '1,/^}$/p' "$BASE/$PS_REL"
    printf "\nDescribe 'alpha' -Tag 'target:bin/a.sh' {\n    It 'uses alpha' { Get-Alpha | Should -Be 1 }\n}\n"
    printf "\nDescribe 'gone' -Tag 'target:bin/gone.sh' {\n    It 'is gone' { 1 | Should -Be 1 }\n}; \$shared = 1\n"
    printf "\nDescribe 'beta' -Tag 'target:bin/b.sh' {\n    It 'uses alpha' { Get-Alpha | Should -Be 1 }\n}\n"
  } >"$CO/$PS_REL"
  check_shared_kept pester "$CO" "$PS_REL"
else
  skip "pester shared end line: pwsh not available"
fi
case_end

# The file is edited between the verdict and the cut (appended line; same-line-count rewrite): the
# recorded ranges no longer describe it, so nothing is cut. Unchanged-file control: *-partial-orphan-* cases.
case_begin "file-changed-after-verdict-not-cut" "bin/lib/test-retire-predicate/orphan-removal.sh"
while IFS='|' read -r label rel expr <&3; do
  CO="$(fresh "edit-$label")"; OUT="$(retire "$CO" "$rel" - "$expr")"; sed "$expr" "$BASE/$rel" >"$TMPBASE/edit.want"
  has_line "$label: the verdict is taken before the edit" "$OUT" "VERDICT=partial-orphan MODE=case ORPHANS=1"
  has_line "$label: the removal refuses the changed file" "$OUT" "RC=1"
  if cmp -s "$TMPBASE/edit.want" "$CO/$rel"; then pass "$label: the file keeps the edited bytes, nothing cut"; else fail "$label: the file keeps the edited bytes, nothing cut" "$(diff "$TMPBASE/edit.want" "$CO/$rel" | head -c 300)"; fi
  if grep -q '^WARNING: trp_remove_orphan_cases: .*changed' "$TMPBASE/retire.err"; then pass "$label: a WARNING names the change"; else fail "$label: a WARNING names the change" "$(head -c 200 "$TMPBASE/retire.err")"; fi
  assert_eq "$label names printed: $(printf '%s\n' "$OUT" | grep -cx 'gone'), temp dirs: $(compgen -G "$CO/tests/bin/.trp-orphan.*" | wc -l), staged [$(git -C "$CO" diff --cached --name-only)]" "$label names printed: 0, temp dirs: 0, staged []"
done 3<<'TABLE'
bash-appended|tests/bin/feature-9999-sample.sh|$a # edited
bash-same-line-count|tests/bin/feature-9999-sample.sh|s/^pass "alpha"$/pass "ALPHA"/
js-appended|tests/bin/feature-9999-sample.js|$a // edited
TABLE
case_end

# hook_syntax_check <checkout> <id> <ran-flag> <edit-target|-> <line> — wrap the entry's
# caseEmbedRules function so its syntax-check op records <ran-flag>, appends <line> to
# <edit-target> (the ORIGINAL file, i.e. an edit landing while the rewrite is checked; "-" edits
# nothing), then delegates to the real op.
hook_syntax_check() {
  local f="$1/bin/lib/test-language-parts/$2-case-embed.sh" fn="$2_case_embed"
  printf '%s\n' "" \
    "eval \"_stub_real_\$(declare -f $fn)\"" \
    "$fn() {" \
    "  if [ \"\${1:-}\" = syntax-check ]; then echo ran >>'$3'; [ '$4' = - ] || printf '%s\\n' '$5' >>'$4'; fi" \
    "  _stub_real_$fn \"\$@\"" \
    "}" >>"$f"
}

# The original is edited after the private copy was hashed, while the rewrite is syntax-checked:
# mv would overwrite the edit, so the removal must re-hash the original and refuse.
case_begin "file-changed-during-syntax-check-not-moved" "bin/lib/test-retire-predicate/orphan-removal.sh"
while IFS='|' read -r label rel id line <&3; do
  CO="$(fresh "midcheck-$label")"; FLAG="$TMPBASE/midcheck-$label.ran"; rm -f "$FLAG"
  hook_syntax_check "$CO" "$id" "$FLAG" "$CO/$rel" "$line"
  { cat "$BASE/$rel"; printf '%s\n' "$line"; } >"$TMPBASE/midcheck.want"
  OUT="$(retire "$CO" "$rel" -)"
  has_line "$label: the verdict is taken before the edit" "$OUT" "VERDICT=partial-orphan MODE=case ORPHANS=1"
  if [ -s "$FLAG" ]; then pass "$label: the edit ran during the syntax-check"; else fail "$label: the edit ran during the syntax-check" "hook never called"; fi
  has_line "$label: the removal refuses the file changed during the check" "$OUT" "RC=1"
  if cmp -s "$TMPBASE/midcheck.want" "$CO/$rel"; then pass "$label: the original keeps the mid-check edit, nothing cut"; else fail "$label: the original keeps the mid-check edit, nothing cut" "$(diff "$TMPBASE/midcheck.want" "$CO/$rel" | head -c 300)"; fi
  if grep -q "^WARNING: trp_remove_orphan_cases: $rel changed since the verdict — skipping $rel\$" "$TMPBASE/retire.err"; then pass "$label: a WARNING names the change"; else fail "$label: a WARNING names the change" "$(head -c 200 "$TMPBASE/retire.err")"; fi
  assert_eq "$label names printed: $(printf '%s\n' "$OUT" | grep -cx 'gone'), temp dirs: $(compgen -G "$CO/tests/bin/.trp-orphan.*" | wc -l), staged [$(git -C "$CO" diff --cached --name-only)]" "$label names printed: 0, temp dirs: 0, staged []"
done 3<<'TABLE'
bash|tests/bin/feature-9999-sample.sh|bash|# edited mid-check
js|tests/bin/feature-9999-sample.js|js|// edited mid-check
TABLE
case_end

# Control: the same hook with no edit leaves the normal cut intact.
case_begin "syntax-check-hook-without-edit-still-cuts" "bin/lib/test-retire-predicate/orphan-removal.sh"
while IFS='|' read -r label rel id <&3; do
  CO="$(fresh "hookonly-$label")"; FLAG="$TMPBASE/hookonly-$label.ran"; rm -f "$FLAG"
  hook_syntax_check "$CO" "$id" "$FLAG" - ""
  OUT="$(retire "$CO" "$rel" -)"
  if [ -s "$FLAG" ]; then pass "$label control: the hook ran during the syntax-check"; else fail "$label control: the hook ran during the syntax-check" "hook never called"; fi
  has_line "$label control: removal rc 0" "$OUT" "RC=0"
  has_line "$label control: removal names gone" "$OUT" "gone"
  survivors_kept "$label control" "$BASE/$rel" "$CO/$rel"
  assert_eq "$label control temp dirs: $(compgen -G "$CO/tests/bin/.trp-orphan.*" | wc -l), staged [$(git -C "$CO" diff --cached --name-only)]" "$label control temp dirs: 0, staged [$rel]"
done 3<<'TABLE'
bash|tests/bin/feature-9999-sample.sh|bash
js|tests/bin/feature-9999-sample.js|js
TABLE
case_end
