#!/usr/bin/env bash
# tests/bin/feature-2561-issue-to-history-target-root.sh
# Tests: bin/github-issues/issue-to-history.sh
# Tags: github-issues, history, root-names, target-root, security, scope:issue-specific, TL2
# TL3 gap (what this test does NOT catch):
# - the real doc-append and the real gh: both are PATH stubs that record the call
# - the entry text written to docs/history.md (owned by the doc-append tests)
# Closest-to-action mitigation: tests/mutation/root-names.sh rewrites the root and runs this file.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RWT="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP_ROOT="$(np "$(make_tmp)")"
[[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]] || { echo "cannot create a temp root" >&2; exit 1; }
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT/iso"
unset CLAUDE_CODE_SESSION_ID DRY_RUN ISSUE_NUMBER GH_REPO GH_TOKEN GITHUB_TOKEN
mkdir -p "$TMP_ROOT/home" "$TMP_ROOT/cwd" "$TMP_ROOT/stubs"
export HOME="$TMP_ROOT/home" USERPROFILE="$TMP_ROOT/home"

readonly TOOL="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/issue-to-history.sh"
readonly CALLS="$TMP_ROOT/calls.log"
readonly BODY_FILE="$TMP_ROOT/body.md"
export HISTORY_STUB_CALLS="$CALLS"
printf 'Background: why\nChanges: what\n' >"$BODY_FILE"

# The stubs record who was called and from where; doc-append also marks the file it was given.
cat >"$TMP_ROOT/stubs/doc-append" <<'STUB'
#!/usr/bin/env bash
printf 'doc-append %s\n' "$(pwd)" >>"$HISTORY_STUB_CALLS"
printf 'appended\n' >>"$1"
STUB
cat >"$TMP_ROOT/stubs/gh" <<'STUB'
#!/usr/bin/env bash
printf 'gh %s\n' "$(pwd)" >>"$HISTORY_STUB_CALLS"
exit 1
STUB
chmod +x "$TMP_ROOT/stubs/doc-append" "$TMP_ROOT/stubs/gh"
# A drive-letter path would split at its colon inside PATH, leaving the real commands in reach.
STUB_DIR="$TMP_ROOT/stubs"
if command -v cygpath >/dev/null 2>&1; then STUB_DIR="$(cygpath -u "$STUB_DIR")"; fi
readonly STUB_DIR
export PATH="$STUB_DIR:$PATH"
for stub in doc-append gh; do
  [[ "$(command -v "$stub")" == "$STUB_DIR/$stub" ]] || { echo "FAIL: setup: $stub does not resolve to its stub"; exit 1; }
done

expect_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want=$3 got=$2"; fi; }
expect_has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "missing: $3 in: $2" ;; esac; }
# fresh_roots — two empty checkouts, "target" and "main", and an empty call log.
fresh_roots() {
  rm -rf "$TMP_ROOT/target" "$TMP_ROOT/main"
  mkdir -p "$TMP_ROOT/target/docs" "$TMP_ROOT/main/docs"
  : >"$TMP_ROOT/target/docs/history.md"
  : >"$TMP_ROOT/main/docs/history.md"
  : >"$CALLS"
}
# run_tool <target-checkout dir|-> <agents-main dir|-> [args...] — sets OUT and RC.
# The target checkout root travels as the trailing flag pair; the issue number stays first.
run_tool() {
  local envs=() flag=()
  [[ "$1" == - ]] || flag=(--target-checkout-root "$TMP_ROOT/$1")
  [[ "$2" == - ]] || envs+=("AGENTS_MAIN_ROOT=$TMP_ROOT/$2")
  shift 2
  OUT="$(cd "$TMP_ROOT/cwd" && env -u AGENTS_MAIN_ROOT ${envs[@]+"${envs[@]}"} bash "$RWT" 60 bash "$TOOL" "$@" ${flag[@]+"${flag[@]}"} 2>&1)"
  RC=$?
}
# called <command> — the directories that stub was called from, one per line.
called() { sed -n "s/^$1 //p" "$CALLS"; }
marks() { grep -c '^appended$' "$TMP_ROOT/$1/docs/history.md"; }

# Columns: case | target checkout root | agents main root | root written to (- = none) | exit code.
readonly WRITE_ROWS='target-checkout-root-wins-over-the-agents-main-root|target|main|target|0
target-checkout-root-alone-is-enough|target|-|target|0
agents-main-root-is-the-fallback|-|main|main|0
neither-root-is-an-error|-|-|-|1'

case_begin "the-entry-is-written-under-the-target-checkout-root" "bin/github-issues/issue-to-history.sh"
while IFS='|' read -r name tcr amr written rc; do
  fresh_roots
  run_tool "$tcr" "$amr" 4242 --non-github-mode --title "fixture entry" --body-file "$BODY_FILE" --closed-date 2026-01-02
  expect_eq "$name: exit code" "$RC" "$rc"
  for root in target main; do
    want=0
    [[ "$root" == "$written" ]] && want=1
    expect_eq "$name: entries written under $root" "$(marks "$root")" "$want"
  done
  if [[ "$written" == - ]]; then
    expect_eq "$name: doc-append is not called" "$(called doc-append)" ""
    expect_has "$name: the error names both roots" "$OUT" "neither --target-checkout-root nor AGENTS_MAIN_ROOT is given"
  else
    expect_eq "$name: doc-append runs inside that root" "$(np "$(called doc-append)")" "$TMP_ROOT/$written"
    expect_has "$name: the append is reported" "$OUT" "Appended issue #4242 to docs/history.md"
  fi
  expect_eq "$name: gh is not called" "$(called gh)" ""
done <<<"$WRITE_ROWS"
case_end

# The flag with no usable value is refused; the agents main root is set and must not be used.
case_begin "a-target-checkout-root-flag-without-a-directory-is-refused" "bin/github-issues/issue-to-history.sh"
for kind in no-value empty-value; do
  tail=(--target-checkout-root)
  [[ "$kind" == no-value ]] || tail+=("")
  fresh_roots
  run_tool - main 4242 --non-github-mode --title "fixture entry" --body-file "$BODY_FILE" --closed-date 2026-01-02 "${tail[@]}"
  if [[ "$RC" -eq 124 ]]; then fail "$kind: the run ends by itself" "timed out"; else pass "$kind: the run ends by itself"; fi
  expect_eq "$kind: exit code" "$RC" "1"
  expect_has "$kind: the refusal names the flag" "$OUT" "Error: --target-checkout-root needs a directory"
  expect_eq "$kind: nothing is written or called" "$(called doc-append)$(called gh)$(marks target)$(marks main)" "00"
done
case_end

# Columns: case | root holding the entry | exit code | gh calls. Both roots are set in every row.
readonly READ_ROWS='an-entry-under-the-target-checkout-root-ends-the-run|target|0|0
an-entry-under-the-agents-main-root-is-not-seen|main|1|1'

case_begin "the-existing-entry-is-looked-up-under-the-target-checkout-root" "bin/github-issues/issue-to-history.sh"
while IFS='|' read -r name holder rc gh_calls; do
  fresh_roots
  printf '### #4242: fixture entry (2026-01-02)\n' >"$TMP_ROOT/$holder/docs/history.md"
  run_tool target main 4242
  expect_eq "$name: exit code" "$RC" "$rc"
  expect_eq "$name: gh calls" "$(called gh | grep -c .)" "$gh_calls"
  expect_eq "$name: nothing is appended" "$(called doc-append)$(marks target)$(marks main)" "00"
  if [[ "$rc" == 0 ]]; then
    expect_has "$name: the skip is reported" "$OUT" "Already in history (entry for #4242 exists)"
  else
    expect_eq "$name: gh is asked from the target checkout root" "$(np "$(called gh)")" "$TMP_ROOT/target"
  fi
done <<<"$READ_ROWS"
case_end

echo ""
echo "Results: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
[[ "$FAIL" -eq 0 ]]
