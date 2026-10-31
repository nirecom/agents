# bin/check-test-frontmatter.sh --staged runs bin/check-self-impl.sh on new files, and on existing
# files against their HEAD copy so only detections HEAD lacks block (#2502 S3-3).
# Sourced by tests/bin/feature-2502-check-self-impl.sh.
# shellcheck shell=bash

echo ""
echo "=== commit time: check-test-frontmatter.sh --staged ==="

REPO_FM="$TMPBASE/repo-fm"
mkrepo "$REPO_FM"
put "$REPO_FM" tests/bin/existing.sh sh-clean
put "$REPO_FM" tests/bin/debt.sh sh-bad-edit
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

case_begin "fm-existing-file-gains-counter-blocks" "bin/check-test-frontmatter.sh"
stage "$REPO_FM" tests/bin/existing.sh sh-bad-edit
fm_run "$REPO_FM" tests/bin/existing.sh
expect_rc "existing file gains a counter" 1 "$FM_RC" "$FM_OUT $FM_ERR"
has "existing file gains a counter" "$FM_OUT$FM_ERR" "code=SELF_IMPLEMENTED_HARNESS"
has "existing file gains a counter names it" "$FM_OUT$FM_ERR" "tests/bin/existing.sh"
git -C "$REPO_FM" reset -q -- tests/bin/existing.sh >/dev/null 2>&1
put "$REPO_FM" tests/bin/existing.sh sh-clean
case_end

case_begin "fm-existing-debt-unrelated-edit-passes" "bin/check-test-frontmatter.sh"
stage "$REPO_FM" tests/bin/debt.sh sh-bad-edit-unrelated
fm_run "$REPO_FM" tests/bin/debt.sh
expect_rc "HEAD already has the counter" 0 "$FM_RC" "$FM_OUT $FM_ERR"
lacks "HEAD already has the counter" "$FM_OUT$FM_ERR" "SELF_IMPL"
git -C "$REPO_FM" reset -q -- tests/bin/debt.sh >/dev/null 2>&1
put "$REPO_FM" tests/bin/debt.sh sh-bad-edit
case_end

# HEAD's one PASS=0 cancels only one of the two staged ones.
case_begin "fm-existing-file-duplicates-counter-blocks" "bin/check-test-frontmatter.sh"
stage "$REPO_FM" tests/bin/debt.sh sh-bad-edit-dup
fm_run "$REPO_FM" tests/bin/debt.sh
expect_rc "existing counter written twice" 1 "$FM_RC" "$FM_OUT $FM_ERR"
has "existing counter written twice" "$FM_OUT$FM_ERR" "HIGH: tests/bin/debt.sh line"
_n="$(printf '%s\n' "$FM_OUT"$'\n'"$FM_ERR" | grep -c 'code=SELF_IMPLEMENTED_HARNESS')"
assert_eq "existing counter written twice: HIGH lines=$_n" "existing counter written twice: HIGH lines=1"
git -C "$REPO_FM" reset -q -- tests/bin/debt.sh >/dev/null 2>&1
put "$REPO_FM" tests/bin/debt.sh sh-bad-edit
case_end

case_begin "fm-new-clean-file-passes" "bin/check-test-frontmatter.sh"
stage "$REPO_FM" tests/bin/newclean.sh sh-clean
fm_run "$REPO_FM" tests/bin/newclean.sh
expect_rc "new clean file" 0 "$FM_RC" "$FM_OUT $FM_ERR"
lacks "new clean file" "$FM_OUT$FM_ERR" "SELF_IMPLEMENTED_HARNESS"
git -C "$REPO_FM" rm -q --cached -- tests/bin/newclean.sh >/dev/null 2>&1
case_end

# fm_no_pwsh_path — FM_PATH: the pwsh-less wrapper PATH plus the directory of PATH's git, so Node
# can spawn git (a wrapper is a bash script Node cannot run on Windows); empty + FM_NO_PWSH_WHY if not.
fm_no_pwsh_path() {
  local base git_dir
  FM_PATH=""
  FM_NO_PWSH_WHY=""
  base="$(no_runtime_path pwsh)"
  [[ -n "$base" ]] || { FM_NO_PWSH_WHY="could not build a PATH without pwsh"; return 0; }
  git_dir="$(dirname "$(command -v git)")"
  if PATH="$base:$git_dir" command -v pwsh >/dev/null 2>&1; then
    FM_NO_PWSH_WHY="pwsh sits next to git in $git_dir"
  elif ! PATH="$base:$git_dir" node -e 'process.exit(require("child_process").spawnSync("git",["--version"]).status===0?0:1)'; then
    FM_NO_PWSH_WHY="Node cannot spawn git from $git_dir"
  else
    FM_PATH="$base:$git_dir"
  fi
}

case_begin "fm-self-impl-warn-does-not-block" "bin/check-test-frontmatter.sh"
fm_no_pwsh_path
if [ -z "$FM_PATH" ]; then
  skip "warn at commit time: $FM_NO_PWSH_WHY"
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

# check-self-impl starts are counted on two channels: a bash wrapper first on PATH logs each bash
# start of bin/check-self-impl.sh, and the Node preload of tests/lib/node-spawn-log.sh records every
# Node process start and child_process call (a bash or node child, bin/check-self-impl/*.js) on any OS.
FM_SI_LOG="$TMPBASE/si-starts.log"
FM_SI_SPAWN_LOG="$TMPBASE/si-spawns.log"
FM_SI_RE='(^|[/ ])check-self-impl(\.sh|/[^/ ]+\.js)( |$)'
_fm_bash="$(command -v bash)"
mkdir -p "$TMPBASE/shim-count-si"
printf '#!%s\ncase " $* " in *check-self-impl.sh*) echo start >>%q ;; esac\nexec %q "$@"\n' \
  "$_fm_bash" "$FM_SI_LOG" "$_fm_bash" > "$TMPBASE/shim-count-si/bash"
chmod +x "$TMPBASE/shim-count-si/bash"
FM_COUNT_PATH="$TMPBASE/shim-count-si:$PATH"
# shellcheck source=../../lib/node-spawn-log.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/node-spawn-log.sh"

# fm_counted_run <repo> <rel>... — fm_run with both channels armed. FM_SI_STARTS: the starts seen,
# or "unrecorded" when the preload logged no check-test-frontmatter start (never a silent 0).
fm_counted_run() {
  local shim=0 node_si=0
  rm -f "$FM_SI_LOG"
  nsl_on "$FM_SI_SPAWN_LOG"
  FM_PATH="$FM_COUNT_PATH"
  fm_run "$@"
  FM_PATH=""
  nsl_off
  if [ "$(nsl_count "$FM_SI_SPAWN_LOG" main '[/]check-test-frontmatter/cli\.js( |$)')" -lt 1 ]; then
    FM_SI_STARTS="unrecorded"
    return 0
  fi
  [ -f "$FM_SI_LOG" ] && shim="$(wc -l < "$FM_SI_LOG" | tr -d ' ')"
  node_si="$(nsl_count "$FM_SI_SPAWN_LOG" any "$FM_SI_RE")"
  FM_SI_STARTS=$((shim + node_si))
}

# fm_sorted <text> [<fixed-string>] — the non-empty lines of <text> (only those holding the string), sorted.
fm_sorted() {
  printf '%s\n' "$1" | grep -F -- "${2:-}" | grep -v '^$' | LC_ALL=C sort
}

# One --staged run over a mixed set judges each file as a run of its own would, with one CLI start.
case_begin "fm-batch-matches-per-file-runs" "bin/check-test-frontmatter.sh"
_fb_rels=(tests/bin/newbad.sh tests/bin/existing.sh tests/bin/debt.sh tests/bin/newclean.sh tests/bin/newbad.js)
stage "$REPO_FM" tests/bin/newbad.sh sh-bad
stage "$REPO_FM" tests/bin/existing.sh sh-bad-edit
stage "$REPO_FM" tests/bin/debt.sh sh-bad-edit-unrelated
stage "$REPO_FM" tests/bin/newclean.sh sh-clean
stage "$REPO_FM" tests/bin/newbad.js js-bad
if command -v uv >/dev/null 2>&1; then
  stage "$REPO_FM" tests/bin/test_fb_bad.py pytest-bad
  _fb_rels+=(tests/bin/test_fb_bad.py)
else
  skip "batch vs per-file: pytest row (uv not installed)"
fi
if command -v pwsh >/dev/null 2>&1; then
  stage "$REPO_FM" tests/bin/fb-bad.Tests.ps1 pester-bad
  _fb_rels+=(tests/bin/fb-bad.Tests.ps1)
else
  skip "batch vs per-file: pester row (pwsh not installed)"
fi
_fb_want=""
_fb_want_rc=0
for _r in "${_fb_rels[@]}"; do
  fm_run "$REPO_FM" "$_r"
  _fb_want+="$FM_OUT"$'\n'"$FM_ERR"$'\n'
  [ "$FM_RC" -le "$_fb_want_rc" ] || _fb_want_rc="$FM_RC"
done
fm_counted_run "$REPO_FM" "${_fb_rels[@]}"
expect_rc "batch run" "$_fb_want_rc" "$FM_RC" "$FM_OUT $FM_ERR"
expect_rc "batch run blocks" 1 "$FM_RC" "$FM_OUT $FM_ERR"
assert_eq "self-impl lines=[$(fm_sorted "$FM_OUT"$'\n'"$FM_ERR" SELF_IMPL)]" \
  "self-impl lines=[$(fm_sorted "$_fb_want" SELF_IMPL)]"
assert_eq "all lines=[$(fm_sorted "$FM_OUT"$'\n'"$FM_ERR")]" "all lines=[$(fm_sorted "$_fb_want")]"
has "batch run: new file" "$FM_ERR" "HIGH: tests/bin/newbad.sh line 5:"
has "batch run: existing file gains a counter" "$FM_ERR" "HIGH: tests/bin/existing.sh line 5:"
has "batch run: new js file" "$FM_ERR" "HIGH: tests/bin/newbad.js line"
lacks "batch run: HEAD debt" "$FM_ERR" "tests/bin/debt.sh line"
lacks "batch run: clean file" "$FM_ERR" "tests/bin/newclean.sh line"
# #2507: the Node check judges self-impl in-process, so the batch run starts no check-self-impl.
assert_eq "check-self-impl starts=$FM_SI_STARTS" "check-self-impl starts=0"
git -C "$REPO_FM" rm -q --cached -- tests/bin/newbad.sh tests/bin/newclean.sh tests/bin/newbad.js >/dev/null 2>&1
git -C "$REPO_FM" rm -q --cached --ignore-unmatch -- tests/bin/test_fb_bad.py tests/bin/fb-bad.Tests.ps1 >/dev/null 2>&1
git -C "$REPO_FM" reset -q -- tests/bin/existing.sh tests/bin/debt.sh >/dev/null 2>&1
put "$REPO_FM" tests/bin/existing.sh sh-clean
put "$REPO_FM" tests/bin/debt.sh sh-bad-edit
case_end

# Here nothing differs from HEAD: no self-impl line and no check-self-impl.sh start.
case_begin "fm-unchanged-set-starts-no-self-impl-cli" "bin/check-test-frontmatter.sh"
fm_counted_run "$REPO_FM" tests/bin/existing.sh tests/bin/debt.sh
expect_rc "nothing differs from HEAD" 0 "$FM_RC" "$FM_OUT $FM_ERR"
lacks "nothing differs from HEAD" "$FM_OUT$FM_ERR" "SELF_IMPL"
assert_eq "check-self-impl starts=$FM_SI_STARTS" "check-self-impl starts=0"
case_end
