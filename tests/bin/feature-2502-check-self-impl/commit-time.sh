# bin/check-test-frontmatter.sh --staged runs bin/check-self-impl.sh on new files only (#2502 S3-3).
# Sourced by tests/bin/feature-2502-check-self-impl.sh.
# shellcheck shell=bash

echo ""
echo "=== commit time: check-test-frontmatter.sh --staged ==="

REPO_FM="$TMPBASE/repo-fm"
mkrepo "$REPO_FM"
put "$REPO_FM" tests/bin/existing.sh sh-clean
git -C "$REPO_FM" add -A >/dev/null 2>&1
git -C "$REPO_FM" commit -q -m existing >/dev/null 2>&1

case_begin "fm-new-self-impl-file-blocks" "bin/check-test-frontmatter.sh"
stage "$REPO_FM" tests/bin/newbad.sh sh-bad
fm_run "$REPO_FM" tests/bin/newbad.sh
expect_rc "new self-impl file" 1 "$FM_RC" "$FM_OUT $FM_ERR"
has "new self-impl file" "$FM_OUT$FM_ERR" "code=SELF_IMPLEMENTED_HARNESS"
has "new self-impl file names it" "$FM_OUT$FM_ERR" "tests/bin/newbad.sh"
git -C "$REPO_FM" rm -q --cached -- tests/bin/newbad.sh >/dev/null 2>&1
case_end

case_begin "fm-existing-file-not-checked" "bin/check-test-frontmatter.sh"
stage "$REPO_FM" tests/bin/existing.sh sh-bad-edit
fm_run "$REPO_FM" tests/bin/existing.sh
expect_rc "existing file gains a counter" 0 "$FM_RC" "$FM_OUT $FM_ERR"
lacks "existing file gains a counter" "$FM_OUT$FM_ERR" "SELF_IMPLEMENTED_HARNESS"
git -C "$REPO_FM" reset -q -- tests/bin/existing.sh >/dev/null 2>&1
case_end

case_begin "fm-new-clean-file-passes" "bin/check-test-frontmatter.sh"
stage "$REPO_FM" tests/bin/newclean.sh sh-clean
fm_run "$REPO_FM" tests/bin/newclean.sh
expect_rc "new clean file" 0 "$FM_RC" "$FM_OUT $FM_ERR"
lacks "new clean file" "$FM_OUT$FM_ERR" "SELF_IMPLEMENTED_HARNESS"
git -C "$REPO_FM" rm -q --cached -- tests/bin/newclean.sh >/dev/null 2>&1
case_end

case_begin "fm-self-impl-warn-does-not-block" "bin/check-test-frontmatter.sh"
FM_PATH="$(no_runtime_path pwsh)"
if [ -z "$FM_PATH" ]; then
  skip "warn at commit time: could not build a PATH without pwsh"
else
  stage "$REPO_FM" tests/bin/newbad.Tests.ps1 pester-bad
  fm_run "$REPO_FM" tests/bin/newbad.Tests.ps1
  expect_rc "self-impl unchecked (no pwsh)" 0 "$FM_RC" "$FM_OUT $FM_ERR"
  has "self-impl unchecked (no pwsh)" "$FM_OUT$FM_ERR" "code=SELF_IMPL_CHECK_RUNTIME_UNAVAILABLE"
  lacks "self-impl unchecked (no pwsh)" "$FM_OUT$FM_ERR" "code=SELF_IMPLEMENTED_HARNESS"
  git -C "$REPO_FM" rm -q --cached -- tests/bin/newbad.Tests.ps1 >/dev/null 2>&1
fi
FM_PATH=""
case_end
