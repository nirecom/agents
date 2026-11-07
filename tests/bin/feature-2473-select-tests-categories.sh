#!/usr/bin/env bash
# tests/bin/feature-2473-select-tests-categories.sh
# Tests: bin/select-tests.sh, bin/lib/repo-settings.sh
# Tags: TL2, bin, select-tests, repo-settings, scope:issue-specific
# Issue #2473: bin/select-tests.sh, run with cwd = a target repo, lists tests from the target's git
# toplevel and its .agents.json (read through the real bin/lib/repo-settings.sh -> bin/repo-settings
# CLI), never from the selector's own checkout. Fixture categories differ from RSF_LEGACY_CATEGORIES
# both ways, so a silent legacy fallback cannot pass. A missing or malformed .agents.json must stop
# with /migrate guidance on stderr, a non-zero exit and nothing selected.
# TL3 gap: a real /run-tests selection in a non-agents repo; here the selector runs on fixture repos.
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=../lib/repo-settings-fixture.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/repo-settings-fixture.sh"

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

TMPBASE="$(make_tmp)"
readonly TMPBASE
trap 'rm -rf "$TMPBASE"' EXIT
harness_isolate "$TMPBASE/iso"
unset CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR GIT_DIR GIT_WORK_TREE
cd "$TMPBASE" || exit 1

AGENTS_ROOT_N="$(np "$SCRIPT_CHECKOUT_ROOT")"

# mk_target <dir> <agents-json|""|"<empty>"> <test-rel>... — "" writes no file, "<empty>" a 0-byte one.
# Head changes bin/widget-probe.sh and bin/select-tests.sh; the select-tests stem has tests only in
# this checkout (the isolation decoy).
mk_target() {
  local dir="${1:?mk_target: dir}" json="$2" rel
  shift 2
  harness_git_init "$dir"
  git -C "$dir" config core.autocrlf false
  : >"$dir/README.md"
  case "$json" in
    "") ;;
    "<empty>") : >"$dir/.agents.json" ;;
    *) printf '%s\n' "$json" >"$dir/.agents.json" ;;
  esac
  for rel in "$@"; do
    mkdir -p "$dir/${rel%/*}"
    : >"$dir/$rel"
  done
  git -C "$dir" add -A
  git -C "$dir" -c user.email=t@example.com -c user.name=t commit -q -m base
  git -C "$dir" branch -f base HEAD
  mkdir -p "$dir/bin"
  echo change >"$dir/bin/widget-probe.sh"
  echo change >"$dir/bin/select-tests.sh"
  git -C "$dir" add -A
  git -C "$dir" -c user.email=t@example.com -c user.name=t commit -q -m head
}

# tag_line <fix-root> <line> — FIX:<rel> / AGENTS:<rel> / OTHER:<path>; a relative line is fixture-relative.
tag_line() {
  local fix="$1" n
  n="$(np "$2")"
  n="${n//\\//}"
  if [[ "${n#"$fix/"}" != "$n" ]]; then
    printf 'FIX:%s\n' "${n#"$fix/"}"
  elif [[ "${n#"$AGENTS_ROOT_N/"}" != "$n" ]]; then
    printf 'AGENTS:%s\n' "${n#"$AGENTS_ROOT_N/"}"
  elif [[ "${n:0:1}" == "/" || "${n:1:1}" == ":" ]]; then
    printf 'OTHER:%s\n' "$n"
  else
    printf 'FIX:%s\n' "$n"
  fi
}

# tag_file <fix-root> <file> — tag_line for every non-empty line of <file>.
tag_file() {
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && tag_line "$1" "$line"
  done <"$2"
  return 0
}

# sel_in <dir> — this checkout's real selector run from <dir>. Sets SEL_RC (exit code), SEL_ERR
# (stderr) and SEL_OUT (stdout lines tagged by root, sorted, space-joined).
sel_in() {
  local dir="${1:?sel_in: dir}" fix out_f="$TMPBASE/sel.out" err_f="$TMPBASE/sel.err"
  fix="$(np "$(cd "$dir" && pwd -P)")"
  SEL_RC=0
  (cd "$dir" && run_with_timeout 120 bash "$SCRIPT_CHECKOUT_ROOT/bin/select-tests.sh" base) >"$out_f" 2>"$err_f" || SEL_RC=$?
  SEL_ERR="$(cat "$err_f")"
  SEL_OUT="$(tag_file "$fix" "$out_f" | LC_ALL=C sort | tr '\n' ' ')"
}

# yes_no <command...> — prints yes when the command succeeds, no otherwise.
yes_no() { if "$@"; then echo yes; else echo no; fi; }
err_has_migrate() { [[ "$SEL_ERR" == */migrate* ]]; }
out_has_agents_path() { [[ "$SEL_OUT" == *AGENTS:* ]]; }

# assert_selects <dir> <want> — a usable .agents.json: exit 0, no /migrate guidance, exactly <want>.
assert_selects() {
  sel_in "$1"
  assert_eq "exit: $SEL_RC" "exit: 0"
  assert_eq "/migrate guidance: $(yes_no err_has_migrate)" "/migrate guidance: no"
  assert_eq "selection: $SEL_OUT" "selection: $2"
}

# assert_guides_migrate <dir> — no usable .agents.json: non-zero exit, /migrate guidance on stderr,
# nothing on stdout (so no legacy-category fallback and no path from the agents checkout).
assert_guides_migrate() {
  sel_in "$1"
  assert_eq "non-zero exit: $(yes_no test "$SEL_RC" -ne 0) (rc=$SEL_RC)" "non-zero exit: yes (rc=$SEL_RC)"
  assert_eq "/migrate guidance: $(yes_no err_has_migrate)" "/migrate guidance: yes"
  assert_eq "agents checkout path: $(yes_no out_has_agents_path)" "agents checkout path: no"
  assert_eq "selection: $SEL_OUT" "selection: "
}

# alpha is no legacy category; hooks is one the file leaves out.
CUSTOM_JSON='{"tests":{"dir":"tests","categorization":"by-target","categories":[{"dir":"alpha","covers":["src"]},{"dir":"bin","covers":["bin"]}],"supportDirs":["lib"],"testHarness":"off","caseMarker":"off"}}'
SW='"testHarness":"on","caseMarker":"on"'

FAKE="$TMPBASE/fake"
install_repo_settings "$FAKE" "$SCRIPT_CHECKOUT_ROOT" "$CUSTOM_JSON" || fail "fixture" "repo settings install failed"
FREPO="$TMPBASE/frepo"
mk_target "$FREPO" "$CUSTOM_JSON" tests/alpha/widget-probe.sh tests/bin/widget-probe.sh tests/hooks/widget-probe.sh
T_BYTARGET="$TMPBASE/t-by-target"
mk_target "$T_BYTARGET" '{"tests":{"dir":"tests","categorization":"by-target","categories":[{"dir":"tools","covers":["bin"]}],"supportDirs":["lib"],'"$SW"'}}' tests/tools/widget-probe-test.sh tests/lib/widget-probe-helper.sh
T_BYTYPE="$TMPBASE/t-by-type"
mk_target "$T_BYTYPE" '{"tests":{"dir":"tests","categorization":"by-type","categories":[{"dir":"unit"},{"dir":"e2e"}],"supportDirs":["lib"],'"$SW"'}}' tests/unit/widget-probe-test.sh tests/e2e/widget-probe-e2e-test.sh tests/integration/widget-probe-test.sh tests/bin/widget-probe-test.sh tests/lib/widget-probe-helper.sh
T_FLAT="$TMPBASE/t-flat"
mk_target "$T_FLAT" '{"tests":{"dir":"tests","categorization":"flat","supportDirs":["lib"],'"$SW"'}}' tests/widget-probe-test.sh tests/lib/widget-probe-helper.sh
T_CUSTOM="$TMPBASE/t-custom-dir"
mk_target "$T_CUSTOM" '{"tests":{"dir":"spec","categorization":"by-target","categories":[{"dir":"bin","covers":["bin"]}],'"$SW"'}}' spec/bin/widget-probe-test.sh tests/bin/widget-probe-decoy-test.sh

# 10000 by-target categories; only the first and the last exist on disk (no 10000 mkdirs).
BIG_JSON="$(node -e 'const c=[];for(let i=0;i<10000;i++)c.push({dir:"c"+String(i).padStart(5,"0"),covers:["src"+i]});process.stdout.write(JSON.stringify({tests:{dir:"tests",categorization:"by-target",categories:c,supportDirs:["lib"],testHarness:"off",caseMarker:"off"}}))')"
T_BIG="$TMPBASE/t-many-categories"
mk_target "$T_BIG" "$BIG_JSON" tests/c00000/widget-probe-test.sh tests/c09999/widget-probe-test.sh tests/unlisted/widget-probe-test.sh tests/bin/widget-probe-test.sh

# The no-usable-settings fixtures carry a legacy-category test (tests/bin) a fallback would select.
NOUSE_TESTS=(tests/bin/widget-probe-test.sh tests/tools/widget-probe-other-test.sh)
T_UNINIT="$TMPBASE/t-uninitialized"
mk_target "$T_UNINIT" "" "${NOUSE_TESTS[@]}"
T_MALFORMED="$TMPBASE/t-malformed"
mk_target "$T_MALFORMED" '{"tests": not json' "${NOUSE_TESTS[@]}"
T_EMPTYFILE="$TMPBASE/t-empty-file"
mk_target "$T_EMPTYFILE" "<empty>" "${NOUSE_TESTS[@]}"
T_BYTARGET0="$TMPBASE/t-by-target-no-categories"
mk_target "$T_BYTARGET0" '{"tests":{"dir":"tests","categorization":"by-target","categories":[],'"$SW"'}}' "${NOUSE_TESTS[@]}"
T_BYTYPE0="$TMPBASE/t-by-type-no-categories"
mk_target "$T_BYTYPE0" '{"tests":{"dir":"tests","categorization":"by-type","categories":[],'"$SW"'}}' "${NOUSE_TESTS[@]}"
T_NOSWITCH="$TMPBASE/t-missing-required-keys"
mk_target "$T_NOSWITCH" '{"tests":{"dir":"tests","categorization":"by-target","categories":[{"dir":"bin","covers":["bin"]}]}}' "${NOUSE_TESTS[@]}"

case_begin "loader-reads-fixture-categories" "bin/lib/repo-settings.sh"
got="$(run_with_timeout 60 bash -c '. "$1" || exit 97; rsf_categories_into "$2"; printf "%s|" "$RSF_CATS_LEGACY" "${RSF_CATS[@]}"' _ "$FAKE/bin/lib/repo-settings.sh" "$(np "$FAKE")" 2>&1)"
assert_eq "legacy flag and categories: $got" "legacy flag and categories: 0|alpha|bin|"
case_end

case_begin "selection-follows-categories" "bin/select-tests.sh"
assert_selects "$FREPO" "FIX:tests/alpha/widget-probe.sh FIX:tests/bin/widget-probe.sh "
case_end

case_begin "target-repo-by-target" "bin/select-tests.sh"
assert_selects "$T_BYTARGET" "FIX:tests/tools/widget-probe-test.sh "
case_end

case_begin "target-repo-by-type" "bin/select-tests.sh"
assert_selects "$T_BYTYPE" "FIX:tests/e2e/widget-probe-e2e-test.sh FIX:tests/unit/widget-probe-test.sh "
case_end

case_begin "target-repo-flat" "bin/lib/repo-settings.sh"
assert_selects "$T_FLAT" "FIX:tests/widget-probe-test.sh "
case_end

case_begin "target-repo-custom-dir" "bin/select-tests.sh"
assert_selects "$T_CUSTOM" "FIX:spec/bin/widget-probe-test.sh "
case_end

case_begin "target-repo-10000-categories" "bin/select-tests.sh"
started=$SECONDS
assert_selects "$T_BIG" "FIX:tests/c00000/widget-probe-test.sh FIX:tests/c09999/widget-probe-test.sh "
elapsed=$((SECONDS - started))
assert_eq "within 60s: $(yes_no test "$elapsed" -le 60) (${elapsed}s)" "within 60s: yes (${elapsed}s)"
case_end

case_begin "target-repo-uninitialized-guides-migrate" "bin/select-tests.sh"
assert_guides_migrate "$T_UNINIT"
case_end

case_begin "target-repo-malformed-guides-migrate" "bin/select-tests.sh"
assert_guides_migrate "$T_MALFORMED"
case_end

case_begin "target-repo-empty-file-guides-migrate" "bin/select-tests.sh"
assert_guides_migrate "$T_EMPTYFILE"
case_end

case_begin "target-repo-by-target-no-categories-guides-migrate" "bin/select-tests.sh"
assert_guides_migrate "$T_BYTARGET0"
case_end

case_begin "target-repo-by-type-no-categories-guides-migrate" "bin/select-tests.sh"
assert_guides_migrate "$T_BYTYPE0"
case_end

case_begin "target-repo-missing-required-keys-guides-migrate" "bin/select-tests.sh"
assert_guides_migrate "$T_NOSWITCH"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
