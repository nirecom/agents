# bin/check-test-frontmatter.sh --staged: a new PowerShell, Python or JavaScript test must
# load its helper library (#2411). Sourced by tests/bin/feature-2411-gate-three-languages.sh.
# shellcheck shell=bash

echo ""
echo "=== gate: helper library load proof, three languages ==="

REPO_LOAD="$TMPBASE/repo-load"
mkrepo "$REPO_LOAD"
for _lang in "${LANGS[@]}"; do
  lang_set "$_lang" old
  stage "$REPO_LOAD" "tests/bin/$LF" "$_lang-noload"
done
git -C "$REPO_LOAD" commit -q -m "tests that predate the rule" >/dev/null 2>&1
MISSING_LOAD="MISSING_HARNESS_SOURCE: "

case_begin "gate-load-proof-new-file-with-canonical-load-passes" "bin/check-test-frontmatter.sh"
for _lang in "${LANGS[@]}"; do
  lang_set "$_lang" loads
  stage "$REPO_LOAD" "tests/bin/$LF" "$_lang-conforming"
  fm_run "$REPO_LOAD" "tests/bin/$LF"
  assert_eq "$_lang rc=$FM_RC err=$FM_ERR" "$_lang rc=0 err="
done
case_end

case_begin "gate-load-proof-new-file-without-load-is-flagged" "bin/check-test-frontmatter.sh"
for _lang in "${LANGS[@]}"; do
  for _kind in noload commentload; do
    lang_set "$_lang" "$_kind"
    stage "$REPO_LOAD" "tests/bin/$LF" "$_lang-$_kind"
    fm_run "$REPO_LOAD" "tests/bin/$LF"
    assert_eq "$_lang $_kind rc=$FM_RC" "$_lang $_kind rc=1"
    has "$_lang $_kind" "$FM_ERR" "${MISSING_LOAD}tests/bin/$LF"
  done
done
case_end

case_begin "gate-load-proof-file-in-head-is-exempt" "bin/check-test-frontmatter.sh"
for _lang in "${LANGS[@]}"; do
  lang_set "$_lang" old
  printf '\n' >> "$REPO_LOAD/tests/bin/$LF"
  git -C "$REPO_LOAD" add -- "tests/bin/$LF" >/dev/null 2>&1
  fm_run "$REPO_LOAD" "tests/bin/$LF"
  assert_eq "$_lang rc=$FM_RC err=$FM_ERR" "$_lang rc=0 err="
done
case_end
# The same exemption over every tracked non-bash test of this checkout is in
# tests/hooks/feature-2411-gate-integration.sh (one long check run, kept out of this file).

case_begin "gate-load-proof-js-boundary" "bin/check-test-frontmatter.sh"
stage "$REPO_LOAD" tests/hooks/direct.js js-noload
fm_run "$REPO_LOAD" tests/hooks/direct.js
has "a new .js directly under a category" "$FM_ERR" "${MISSING_LOAD}tests/hooks/direct.js"
for _rel in tests/hooks/suite/part.js tests/lib/extra.js; do
  stage "$REPO_LOAD" "$_rel" js-noload
  fm_run "$REPO_LOAD" "$_rel"
  assert_eq "$_rel rc=$FM_RC" "$_rel rc=0"
  lacks "$_rel" "$FM_ERR" "$MISSING_LOAD"
done
case_end
