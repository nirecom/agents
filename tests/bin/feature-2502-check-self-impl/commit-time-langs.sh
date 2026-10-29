# check-test-frontmatter.sh --staged on an existing pytest, pester or js test file: a counter HEAD
# lacks blocks, a counter HEAD already has does not (#2502 S3-3; commit-time.sh covers bash).
# Sourced by tests/bin/feature-2502-check-self-impl.sh; the bodies are in bodies-head.sh. A language
# whose runtime is not installed answers the SELF_IMPL_CHECK_RUNTIME_UNAVAILABLE WARN, which never
# blocks, so its blocking row expects that WARN instead.
# shellcheck shell=bash

echo ""
echo "=== commit time: existing pytest / pester / js files ==="

REPO_FML="$TMPBASE/repo-fm-langs"
mkrepo "$REPO_FML"
FML_LANGS=(pytest pester js)

# fml_lang <id> — FL_B body prefix, FL_CLEAN / FL_DEBT the HEAD-clean and HEAD-counter paths,
# FL_RT the runtime (empty: always there).
fml_lang() {
  case "$1" in
    pytest) FL_B=py; FL_CLEAN=tests/bin/test_fm_clean.py; FL_DEBT=tests/bin/test_fm_debt.py; FL_RT=uv ;;
    pester) FL_B=ps1; FL_CLEAN=tests/bin/fm-clean.Tests.ps1; FL_DEBT=tests/bin/fm-debt.Tests.ps1; FL_RT=pwsh ;;
    js) FL_B=js; FL_CLEAN=tests/bin/fm-clean.js; FL_DEBT=tests/bin/fm-debt.js; FL_RT="" ;;
  esac
}

for _lang in "${FML_LANGS[@]}"; do
  fml_lang "$_lang"
  put "$REPO_FML" "$FL_CLEAN" "$FL_B-h-clean"
  put "$REPO_FML" "$FL_DEBT" "$FL_B-h-ctr"
done
git -C "$REPO_FML" add -A >/dev/null 2>&1
git -C "$REPO_FML" commit -q -m existing >/dev/null 2>&1

case_begin "fm-existing-file-gains-counter-blocks-langs" "bin/check-test-frontmatter.sh"
for _lang in "${FML_LANGS[@]}"; do
  fml_lang "$_lang"
  stage "$REPO_FML" "$FL_CLEAN" "$FL_B-h-ctr"
  fm_run "$REPO_FML" "$FL_CLEAN"
  if [ -n "$FL_RT" ] && ! command -v "$FL_RT" >/dev/null 2>&1; then
    expect_rc "$_lang existing file gains a counter (no $FL_RT)" 0 "$FM_RC" "$FM_OUT $FM_ERR"
    has "$_lang existing file gains a counter (no $FL_RT)" "$FM_OUT$FM_ERR" "code=SELF_IMPL_CHECK_RUNTIME_UNAVAILABLE"
  else
    expect_rc "$_lang existing file gains a counter" 1 "$FM_RC" "$FM_OUT $FM_ERR"
    has "$_lang existing file gains a counter" "$FM_OUT$FM_ERR" "HIGH: $FL_CLEAN line"
    has "$_lang existing file gains a counter" "$FM_OUT$FM_ERR" "code=SELF_IMPLEMENTED_HARNESS"
  fi
  git -C "$REPO_FML" reset -q -- "$FL_CLEAN" >/dev/null 2>&1
  put "$REPO_FML" "$FL_CLEAN" "$FL_B-h-clean"
done
case_end

case_begin "fm-existing-debt-unrelated-edit-passes-langs" "bin/check-test-frontmatter.sh"
for _lang in "${FML_LANGS[@]}"; do
  fml_lang "$_lang"
  stage "$REPO_FML" "$FL_DEBT" "$FL_B-h-ctr2"
  fm_run "$REPO_FML" "$FL_DEBT"
  expect_rc "$_lang HEAD already has the counter" 0 "$FM_RC" "$FM_OUT $FM_ERR"
  lacks "$_lang HEAD already has the counter" "$FM_OUT$FM_ERR" "SELF_IMPLEMENTED_HARNESS"
  git -C "$REPO_FML" reset -q -- "$FL_DEBT" >/dev/null 2>&1
  put "$REPO_FML" "$FL_DEBT" "$FL_B-h-ctr"
done
case_end

echo ""
echo "=== commit time: the HEAD blob batch lookup ==="

# HEAD gains a zero-size test and a bash file with a counter; the set mixes a path HEAD lacks, the
# zero-size blob, and entries after them whose HEAD counter must still be subtracted.
: > "$REPO_FML/tests/bin/fm-empty.sh"
put "$REPO_FML" tests/bin/fm-debt.sh sh-h-ctr
git -C "$REPO_FML" add -A >/dev/null 2>&1
git -C "$REPO_FML" commit -q -m boundaries >/dev/null 2>&1
HB_RELS=(tests/bin/fm-hb-new.sh tests/bin/fm-empty.sh tests/bin/fm-debt.sh tests/bin/fm-debt.js tests/bin/fm-clean.js)
stage "$REPO_FML" tests/bin/fm-hb-new.sh sh-h-ctr
stage "$REPO_FML" tests/bin/fm-empty.sh sh-h-ctr
stage "$REPO_FML" tests/bin/fm-debt.sh sh-h-ctr2
stage "$REPO_FML" tests/bin/fm-debt.js js-h-ctr2
stage "$REPO_FML" tests/bin/fm-clean.js js-h-fail

# hb_git_shim <name> <cat-file --batch body> — a git wrapper dir that logs every call to
# HB_LOG and runs <body> (REAL is the real git) in place of git cat-file --batch; printed.
HB_LOG="$TMPBASE/hb-git.log"
_hb_bash="$(command -v bash)"
_hb_git="$(command -v git)"
hb_git_shim() {
  local d="$TMPBASE/shim-git-$1"
  mkdir -p "$d"
  printf '#!%s\nREAL=%q\necho "$*" >>%q\nif [ "$1 $2" = "cat-file --batch" ]; then %s; fi\nexec "$REAL" "$@"\n' \
    "$_hb_bash" "$_hb_git" "$HB_LOG" "$2" > "$d/git"
  chmod +x "$d/git"
  printf '%s' "$d:$PATH"
}

# The git calls are counted by the Node preload of tests/lib/node-spawn-log.sh, which a PATH shim
# cannot replace: Node's spawnSync never runs a bash git shim on Windows.
# shellcheck source=../../lib/node-spawn-log.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/node-spawn-log.sh"
HB_SPAWN_LOG="$TMPBASE/hb-spawns.log"
HB_GIT='^(.*/)?git(\.exe)?( -C [^ ]+)? '

case_begin "fm-head-load-boundaries" "bin/check-test-frontmatter.sh"
nsl_on "$HB_SPAWN_LOG"
fm_run "$REPO_FML" "${HB_RELS[@]}"
nsl_off
expect_rc "batch lookup" 1 "$FM_RC" "$FM_OUT $FM_ERR"
has "path absent at HEAD is new" "$FM_ERR" "HIGH: tests/bin/fm-hb-new.sh line 5: self-implemented harness (counter-init PASS=0)"
has "zero-size HEAD blob grown a counter" "$FM_ERR" "HIGH: tests/bin/fm-empty.sh line 5: self-implemented harness (counter-init PASS=0)"
lacks "HEAD counter after a missing entry" "$FM_ERR" "tests/bin/fm-debt.sh line"
lacks "js HEAD counter after a zero-size entry" "$FM_ERR" "tests/bin/fm-debt.js line"
has "js counter HEAD lacks" "$FM_ERR" "HIGH: tests/bin/fm-clean.js line 5: self-implemented harness (counter-init FAIL=0)"
_hb_main="$(nsl_count "$HB_SPAWN_LOG" main '[/]check-test-frontmatter/cli\.js( |$)')"
if [ "$_hb_main" -lt 1 ]; then
  fail "batch lookup call log" "the Node preload recorded no check-test-frontmatter start: $(cat "$HB_SPAWN_LOG" 2>/dev/null)"
else
  _hb_batch="$(nsl_count "$HB_SPAWN_LOG" spawn "${HB_GIT}cat-file --batch\$")"
  _hb_reads="$(nsl_count "$HB_SPAWN_LOG" spawn "${HB_GIT}(cat-file|show)( |\$)")"
  assert_eq "batch lookup: cat-file --batch calls=$_hb_batch" "batch lookup: cat-file --batch calls=1"
  assert_eq "batch lookup: per-file blob reads=$((_hb_reads - _hb_batch))" "batch lookup: per-file blob reads=0"
fi
case_end

# #2507 retired fm-head-load-broken-batch-falls-back and fm-head-load-second-run-same-shell: the
# Node check has no per-file fallback (a broken batch stops the run, as the case below pins) and
# keeps no shell state (the sourced self-impl.sh is gone).

for _r in "${HB_RELS[@]}"; do git -C "$REPO_FML" reset -q -- "$_r" >/dev/null 2>&1; done

# An unrelated edit to an existing counter: blocks nothing while HEAD is readable; when the HEAD
# batch read fails the CLI stops with rc 2 and a cat-file diagnostic (fail-closed, #2507 D7).
case_begin "fm-head-content-unreadable-fails-closed" "bin/check-test-frontmatter.sh"
stage "$REPO_FML" tests/bin/fm-debt.sh sh-h-ctr2
rm -f "$HB_LOG"
FM_PATH="$(hb_git_shim log-only ':')"
fm_run "$REPO_FML" tests/bin/fm-debt.sh
FM_PATH=""
expect_rc "control: HEAD readable" 0 "$FM_RC" "$FM_OUT $FM_ERR"
assert_eq "control: output=[$FM_OUT$FM_ERR]" "control: output=[]"
while IFS='|' read -r _name _body; do
  [[ -z "$_name" ]] && continue
  _name="${_name//[[:space:]]/}"
  _body="${_body#"${_body%%[![:space:]]*}"}"
  rm -f "$HB_LOG"
  FM_PATH="$(hb_git_shim "$_name" "$_body")"
  fm_run "$REPO_FML" tests/bin/fm-debt.sh
  FM_PATH=""
  if [ ! -f "$HB_LOG" ]; then
    skip "$_name: the git shim is not reached by Node here"
    continue
  fi
  expect_rc "$_name: HEAD content unreadable" 2 "$FM_RC" "$FM_OUT $FM_ERR"
  assert_eq "$_name: stdout=[$FM_OUT]" "$_name: stdout=[]"
  has "$_name: HEAD read diagnostic" "$FM_ERR" "cat-file"
  lacks "$_name: not judged as new" "$FM_ERR" "SELF_IMPLEMENTED_HARNESS"
done <<'TABLE'
batch-fails     | exit 128
batch-truncated | "$REAL" "$@" | head -c 60; exit 0
TABLE
git -C "$REPO_FML" reset -q -- tests/bin/fm-debt.sh >/dev/null 2>&1
case_end
