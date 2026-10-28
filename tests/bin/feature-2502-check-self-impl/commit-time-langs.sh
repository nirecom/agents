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
# The per-file read re-reads a baseline by its oid (#2812): git cat-file blob <oid>.
HB_DEBT_OID="$(git -C "$REPO_FML" rev-parse HEAD:tests/bin/fm-debt.sh)"
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

# hb_run <shim-path> — fm_run over HB_RELS through <shim-path>; HB_LINES the sorted output lines.
hb_run() {
  rm -f "$HB_LOG"
  FM_PATH="$1"
  fm_run "$REPO_FML" "${HB_RELS[@]}"
  FM_PATH=""
  HB_LINES="$(printf '%s\n%s\n' "$FM_OUT" "$FM_ERR" | grep -v '^$' | LC_ALL=C sort)"
  HB_CALLS="$(cat "$HB_LOG" 2>/dev/null)"
}

case_begin "fm-head-load-boundaries" "bin/check-test-frontmatter.sh"
hb_run "$(hb_git_shim log-only ':')"
HB_BASE_RC="$FM_RC"
HB_BASE_LINES="$HB_LINES"
expect_rc "batch lookup" 1 "$FM_RC" "$FM_OUT $FM_ERR"
has "path absent at HEAD is new" "$FM_ERR" "HIGH: tests/bin/fm-hb-new.sh line 5: self-implemented harness (counter-init PASS=0)"
has "zero-size HEAD blob grown a counter" "$FM_ERR" "HIGH: tests/bin/fm-empty.sh line 5: self-implemented harness (counter-init PASS=0)"
lacks "HEAD counter after a missing entry" "$FM_ERR" "tests/bin/fm-debt.sh line"
lacks "js HEAD counter after a zero-size entry" "$FM_ERR" "tests/bin/fm-debt.js line"
has "js counter HEAD lacks" "$FM_ERR" "HIGH: tests/bin/fm-clean.js line 5: self-implemented harness (counter-init FAIL=0)"
has "batch lookup: one cat-file --batch" "$HB_CALLS" "cat-file --batch"
lacks "batch lookup: no per-file fallback" "$HB_CALLS" "cat-file blob"
case_end

# A broken git cat-file --batch answer falls back to the per-file lookup with the same verdict.
case_begin "fm-head-load-broken-batch-falls-back" "bin/check-test-frontmatter.sh"
while IFS='|' read -r _name _body; do
  [[ -z "$_name" || "$_name" =~ ^[[:space:]]*# ]] && continue
  _name="${_name//[[:space:]]/}"
  _body="${_body#"${_body%%[![:space:]]*}"}"
  hb_run "$(hb_git_shim "$_name" "$_body")"
  expect_rc "$_name" "$HB_BASE_RC" "$FM_RC" "$FM_OUT $FM_ERR"
  assert_eq "$_name: lines=[$HB_LINES]" "$_name: lines=[$HB_BASE_LINES]"
  has "$_name: falls back" "$HB_CALLS" "cat-file blob $HB_DEBT_OID"
done <<'TABLE'
garbage-header | "$REAL" "$@" >/dev/null; echo garbage; exit 0
truncated-blob | "$REAL" "$@" | head -c 160; exit 0
git-fails      | exit 128
TABLE
case_end

# ctf_self_impl_run leaves no state: a second load and run in the same shell sees no stale temp dir.
case_begin "fm-head-load-second-run-same-shell" "bin/check-test-frontmatter.sh"
_hb_res="$(
  cd "$REPO_FML" || exit 99
  SCRIPT_DIR="$SCRIPT_CHECKOUT_ROOT/bin"
  . "$SCRIPT_DIR/check-test-frontmatter/self-impl.sh"
  for _run in 1 2; do
    ctf_parents_load "" "${HB_RELS[@]}"
    _d="$CTF_SI_DIR"
    for _r in "${HB_RELS[@]}"; do ctf_self_impl_add "$_r" "$(git show ":$_r")"; done
    _rc=0
    ctf_self_impl_run 2>"$TMPBASE/hb-run$_run.err" || _rc=$?
    _left=no
    if [ -z "$_d" ] || [ -e "$_d" ]; then _left=yes; fi
    echo "run$_run rc=$_rc dir-left=$_left state=[$CTF_SI_DIR|$CTF_SI_N|${#CTF_PAR_RELS[@]}]"
  done
)"
assert_eq "$_hb_res" "run1 rc=1 dir-left=no state=[|0|0]"$'\n'"run2 rc=1 dir-left=no state=[|0|0]"
_hb_err1="$(LC_ALL=C sort "$TMPBASE/hb-run1.err")"
assert_eq "run2 lines=[$(LC_ALL=C sort "$TMPBASE/hb-run2.err")]" "run2 lines=[$_hb_err1]"
assert_eq "run1 lines=[$_hb_err1]" "run1 lines=[$(printf '%s\n' "$HB_BASE_LINES" | grep -F SELF_IMPL)]"
case_end

for _r in "${HB_RELS[@]}"; do git -C "$REPO_FML" reset -q -- "$_r" >/dev/null 2>&1; done

# hr_git_shim <name> <cat-file --batch body> — as hb_git_shim, and the per-file git cat-file blob
# <oid> fails too, while the parent lookup still answers: a parent has the path but its content
# cannot be read.
hr_git_shim() {
  local d="$TMPBASE/shim-git-hr-$1"
  mkdir -p "$d"
  printf '#!%s\nREAL=%q\necho "$*" >>%q\nif [ "$1 $2" = "cat-file --batch" ]; then %s; fi\ncase "$1 $2" in "cat-file blob") exit 128 ;; esac\nexec "$REAL" "$@"\n' \
    "$_hb_bash" "$_hb_git" "$HB_LOG" "$2" > "$d/git"
  chmod +x "$d/git"
  printf '%s' "$d:$PATH"
}

# An unrelated edit to an existing counter: blocks nothing while HEAD is readable; when the HEAD
# content read fails the empty HEAD copy judges the counter as new, with no HEAD-read diagnostic.
case_begin "fm-head-content-unreadable-judged-as-new" "bin/check-test-frontmatter.sh"
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
  FM_PATH="$(hr_git_shim "$_name" "$_body")"
  fm_run "$REPO_FML" tests/bin/fm-debt.sh
  FM_PATH=""
  HB_CALLS="$(cat "$HB_LOG" 2>/dev/null)"
  expect_rc "$_name: HEAD content unreadable" 1 "$FM_RC" "$FM_OUT $FM_ERR"
  assert_eq "$_name: stdout=[$FM_OUT]" "$_name: stdout=[]"
  assert_eq "$_name: stderr=[$FM_ERR]" "$_name: stderr=[HIGH: tests/bin/fm-debt.sh line 5: self-implemented harness (counter-init PASS=0) code=SELF_IMPLEMENTED_HARNESS]"
  has "$_name: batch read tried" "$HB_CALLS" "cat-file --batch"
  has "$_name: per-file read by oid tried" "$HB_CALLS" "cat-file blob $HB_DEBT_OID"
done <<'TABLE'
batch-fails     | exit 128
batch-truncated | "$REAL" "$@" | head -c 60; exit 0
TABLE
git -C "$REPO_FML" reset -q -- tests/bin/fm-debt.sh >/dev/null 2>&1
case_end
