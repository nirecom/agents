#!/usr/bin/env bash
# tests/bin/TL3-worker-dispatch-mixed-language-run.sh
# Tests: bin/worker-dispatch/workers/test-runner.js, bin/worker-dispatch/emit.js, bin/worker-dispatch/registry.js, tests/run-all.sh
# Tags: worker-dispatch, test-runner, test-language-registry, pester, node-test, unrunnable, real-environment, TL3, scope:common
#
# TL3: the real dispatcher drives the real tests/run-all.sh over one bash + Pester +
# node:test selection through real bash/pwsh/node under the allowlisted child env —
# the seam TL1/TL2 (launcher, wrappers, renderer in isolation) cannot exercise.
# TL3 gap: hosts without pwsh/Pester 5/node skip (77); the PATH-stripped arm skips
# where pwsh shares a directory with bash/node/git (e.g. /usr/bin on Linux).

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ -x "$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" ] || exit 77
"$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" --is-off RUN_TL3 off && exit 77
command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH"; exit 77; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not on PATH"; exit 77; }
command -v pwsh >/dev/null 2>&1 || { echo "SKIP: pwsh not on PATH"; exit 77; }

# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

# Pester 5 is probed directly (never through the dispatcher), so a broken
# dispatcher cannot masquerade as "Pester missing" and skip instead of fail.
PESTER_RC=0
run_with_timeout 60 pwsh -NoProfile -NonInteractive -Command \
  'if (Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version.Major -ge 5 }) { exit 0 } else { exit 1 }' \
  >/dev/null 2>&1 || PESTER_RC=$?
[ "$PESTER_RC" -eq 0 ] || { echo "SKIP: Pester 5 not available to pwsh (rc=$PESTER_RC)"; exit 77; }

# #2473: the dispatcher is the fixture's own copy (set below), so the fixture is the agents
# repo itself (runAllSelf) and its tests/run-all.sh wrapper is the runner that starts.
TMPD="$(make_tmp)"
trap 'rm -rf "$TMPD"' EXIT
harness_isolate "$TMPD/isolate"
PLANS="$(np "$WORKFLOW_PLANS_DIR")"

# --- fixture repo: the branch's runner + libraries, three one-test files ----------
# The selection is relative to cwd (rel-path-arg[]), so the fixture IS the family
# main worktree. tests/run-all.sh is a wrapper that keeps the real runner's full
# stdout: the worker's log_tail drops PASS case lines by contract, so the
# case-level lines can only be asserted from the runner's own stream.
FIX="$TMPD/fixrepo"
mkdir -p "$FIX/tests/bin"
harness_git_init "$FIX"
cp -r "$SCRIPT_CHECKOUT_ROOT/bin" "$FIX/bin"
cp -r "$SCRIPT_CHECKOUT_ROOT/hooks" "$FIX/hooks"; DISPATCH_JS="$FIX/bin/worker-dispatch.js"
cp -r "$SCRIPT_CHECKOUT_ROOT/tests/lib" "$FIX/tests/lib"
# The runner's root decoy reads the retired names from this file; it is not run here.
cp "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2561-root-names-residue.sh" "$FIX/tests/bin/"
cp "$SCRIPT_CHECKOUT_ROOT/tests/run-all.sh" "$FIX/tests/.real-run-all.sh"
# Host lanes and the duration ledger are optional runner libs keyed on the real HOME
# (the child env cannot redirect them): without them the fixture neither waits on
# lanes this test's own run already holds nor writes the developer's ledger.
rm -f "$FIX/bin/lib/test-host-lanes.sh" "$FIX/bin/lib/run-all-durations.sh"
RUNNER_LOG="$TMPD/runner.out"
{
  printf '#!/usr/bin/env bash\n'
  printf 'bash %s "$@" > %s 2>&1\n' "\"$FIX/tests/.real-run-all.sh\"" "\"$RUNNER_LOG\""
  printf 'rc=$?\ncat %s\nexit "$rc"\n' "\"$RUNNER_LOG\""
} > "$FIX/tests/run-all.sh"

# The fixture's own frontmatter is printed, not spelled at line start: a second literal
# header line in this file would make its own `# Tests:` header unparsable.
printf '#!/usr/bin/env bash\n# %s: tests/lib/harness.sh\n# %s: fixture, scope:issue-specific\n' Tests Tags > "$FIX/tests/bin/mixed-bash.sh"
cat >> "$FIX/tests/bin/mixed-bash.sh" <<'BASHFIX'
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
case_begin "mixed-bash-case" "tests/lib/harness.sh"
assert_eq "$(printf 'a%s' b)" "ab"
case_end
exit $((FAIL > 0 ? 1 : 0))
BASHFIX
cat > "$FIX/tests/bin/mixed.Tests.ps1" <<'PSFIX'
Describe "mixed pester" {
    It "adds" { (1 + 1) | Should -Be 2 }
}
PSFIX
cat > "$FIX/tests/bin/mixed.test.js" <<'JSFIX'
const test = require("node:test");
const assert = require("node:assert");
test("mixed js adds", () => { assert.strictEqual(1 + 1, 2); });
JSFIX
# #2473: the worker refuses a target without a tests section, so the fixture commits one.
printf '%s\n' '{"tests":{"dir":"tests","categorization":"by-target","categories":[{"dir":"bin","covers":["bin"]}],"supportDirs":["_archive","lib"],"testHarness":"on","caseMarker":"on"}}' >"$FIX/.agents.json"
git -C "$FIX" add -A >/dev/null 2>&1
git -C "$FIX" -c user.name=t -c user.email=t@example.com commit -q --no-verify -m fixture >/dev/null 2>&1
FIXN="$(np "$FIX")"

SELECTION='"tests/bin/mixed-bash.sh","tests/bin/mixed.Tests.ps1","tests/bin/mixed.test.js"'
DOUT=""
DRC=0
# dispatch <name> [env-assignment...] — one worker call, 180 s budget.
dispatch() {
  local name="$1" pfile; shift
  pfile="$WORKFLOW_PLANS_DIR/$name.json"
  printf '{"cwd":"%s","test_args":[%s],"timeout_seconds":180,"jobs":1}' "$FIXN" "$SELECTION" > "$pfile"
  : > "$RUNNER_LOG"
  DRC=0
  DOUT="$(run_with_timeout 200 env "$@" "WORKFLOW_PLANS_DIR=$PLANS" \
    node "$(np "$DISPATCH_JS")" test-runner "$FIXN" "$(np "$pfile")" 2>&1)" || DRC=$?
}
yaml_field() { printf '%s\n' "$DOUT" | sed -n "s/^$1: //p" | head -1; }
contract_line() { printf '%s\n' "$DOUT" | grep -E '^RUN_CONTRACT: ' | head -1; }
# Indented: a raw contract/case line in this file's stdout would be read by run-all.
show_out() { printf '%s\n' "$1" | tail -n 30 | sed 's/^/    | /'; }
has_line() { grep -qE "$2" "$1" 2>/dev/null && echo 1 || echo 0; }

dispatch full PATH="$PATH"

case_begin "mixed-run-passes-through-worker" "bin/worker-dispatch/workers/test-runner.js"
assert_eq "status=$(yaml_field status) rc=$DRC" "status=pass rc=0"
[ "$(yaml_field status)" = "pass" ] || show_out "$DOUT"
case_end

case_begin "mixed-run-renders-six-field-contract" "bin/worker-dispatch/emit.js"
CL="$(contract_line)"
assert_eq "contract=${CL#RUN_CONTRACT: }" "contract=PASS=3 FAIL=0 SKIP=0 EXECUTED=3 UNRUNNABLE=0 TIMEOUT=0"
case_end

case_begin "mixed-run-emits-case-level-lines" "tests/run-all.sh"
assert_eq "bash-case-line=$(has_line "$RUNNER_LOG" '^PASS [^ ]*mixed-bash\.sh::mixed-bash-case target=tests/lib/harness\.sh$')" "bash-case-line=1"
assert_eq "pester-case-line=$(has_line "$RUNNER_LOG" '^PASS [^ ]*mixed\.Tests\.ps1::')" "pester-case-line=1"
assert_eq "js-case-line=$(has_line "$RUNNER_LOG" '^PASS [^ ]*mixed\.test\.js::')" "js-case-line=1"
case_end

case_begin "mixed-run-log-tail-drops-pass-case-lines" "bin/worker-dispatch/workers/test-runner.js"
if [ "$(has_line "$RUNNER_LOG" '^PASS [^ ]+::')" = "1" ]; then
  TAIL_HAS=0
  printf '%s\n' "$DOUT" | grep -qE '^  PASS [^ ]+::' && TAIL_HAS=1
  assert_eq "log-tail-pass-case-lines=$TAIL_HAS" "log-tail-pass-case-lines=0"
else
  fail "mixed/log-tail-drop-premise" "the runner emitted no PASS case lines to drop"
fi
case_end

# --- PATH-stripped arm: pwsh unreachable for the worker's child env ---------------
STRIPPED=""
IFS=':' read -r -a PATH_PARTS <<< "$PATH"
for d in "${PATH_PARTS[@]}"; do
  if [ -x "$d/pwsh" ] || [ -x "$d/pwsh.exe" ]; then continue; fi
  STRIPPED="${STRIPPED:+$STRIPPED:}$d"
done
STRIP_OK=1
( PATH="$STRIPPED"; command -v pwsh >/dev/null 2>&1 ) && STRIP_OK=0
for b in node bash git; do
  ( PATH="$STRIPPED"; command -v "$b" >/dev/null 2>&1 ) || STRIP_OK=0
done

case_begin "missing-pwsh-reports-unrunnable" "bin/worker-dispatch/workers/test-runner.js"
if [ "$STRIP_OK" = "1" ]; then
  dispatch nopwsh PATH="$STRIPPED"
  assert_eq "nopwsh-status=$(yaml_field status)" "nopwsh-status=unrunnable"
  CL="$(contract_line)"
  assert_eq "nopwsh-contract=${CL#RUN_CONTRACT: }" "nopwsh-contract=PASS=2 FAIL=0 SKIP=0 EXECUTED=2 UNRUNNABLE=1 TIMEOUT=0"
  MR=0
  printf '%s\n' "$DOUT" | grep -qE 'Missing runtimes: .*pwsh' && MR=1
  assert_eq "nopwsh-missing-runtimes-line=$MR" "nopwsh-missing-runtimes-line=1"
  [ "$MR" = "1" ] || show_out "$DOUT"
else
  skip "missing-pwsh-reports-unrunnable — pwsh cannot be removed from PATH without losing node/bash/git"
fi
case_end

# --- #2473: a target repo that holds no copy of the runner --------------------------
# The worker serves a repo other than the agents checkout with this checkout's own
# tests/run-all.sh (`runAllShared`), pointed at the target through `RUN_ALL_TARGET_ROOT`;
# no spy here: the real dispatcher starts the real bash child. HOME is redirected for
# these calls because the shared runner keeps its host lanes and duration ledger under
# HOME, which the allowlisted child env takes from the dispatcher's own env.
# The cases name tests/run-all.sh as target: the language gate pairs a bash file with bash code.
# TL3 gap: a target on another host or drive, and a target whose own tests need pwsh/node.
TGT_HOME="$TMPD/target-home"
mkdir -p "$TGT_HOME"
TGT_MARK="$(np "$TMPD")/target-only.ran"
TGT_SETTINGS='{"tests":{"dir":"tests","categorization":"flat","testHarness":"off","caseMarker":"off"}}'
# tgt_repo <name> <settings json|-> — a committed repo whose one plain bash test drops TGT_MARK.
tgt_repo() {
  local d="$TMPD/$1"
  mkdir -p "$d/tests"
  harness_git_init "$d"
  printf '#!/usr/bin/env bash\n# %s: README\n# %s: fixture, scope:issue-specific\nprintf ran > "%s"\nexit 0\n' Tests Tags "$TGT_MARK" > "$d/tests/target-only.sh"
  printf 'fixture\n' > "$d/README"
  [ "$2" = "-" ] || printf '%s\n' "$2" > "$d/.agents.json"
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" -c user.name=t -c user.email=t@example.com commit -q --no-verify -m fixture >/dev/null 2>&1
  np "$d"
}
# dispatch_at <name> <cwd> — one worker call against <cwd> with no selection (the --all path).
dispatch_at() {
  local name="$1" cwd="$2" pfile
  pfile="$WORKFLOW_PLANS_DIR/$name.json"
  printf '{"cwd":"%s","test_args":[],"timeout_seconds":180,"jobs":1}' "$cwd" > "$pfile"
  rm -f "$TGT_MARK"
  DRC=0
  DOUT="$(run_with_timeout 200 env "PATH=$PATH" "HOME=$TGT_HOME" "USERPROFILE=$TGT_HOME" "WORKFLOW_PLANS_DIR=$PLANS" \
    node "$(np "$DISPATCH_JS")" test-runner "$cwd" "$(np "$pfile")" 2>&1)" || DRC=$?
}
marker_seen() { [ -f "$TGT_MARK" ] && echo 1 || echo 0; }
TGT_OK="$(tgt_repo target-no-runner "$TGT_SETTINGS")"
TGT_NONE="$(tgt_repo target-no-settings -)"

case_begin "target-without-runner-copy-runs-its-own-tests" "tests/run-all.sh"
if [ -e "$TGT_OK/tests/run-all.sh" ]; then
  fail "target-without-runner-copy/premise" "the fixture target holds a runner copy"
else
  dispatch_at target-ok "$TGT_OK"
  assert_eq "target-status=$(yaml_field status) rc=$DRC" "target-status=pass rc=0"
  assert_eq "target-test-ran=$(marker_seen)" "target-test-ran=1"
  # Exactly the target's one file: the agents suite itself running here would show more.
  CL="$(contract_line)"
  OK_CL=0
  printf '%s\n' "$CL" | grep -qE ' FAIL=0 .*EXECUTED=1 ' && OK_CL=1
  assert_eq "target-contract-one-file=$OK_CL ($CL)" "target-contract-one-file=1 ($CL)"
  [ "$(yaml_field status)" = "pass" ] || show_out "$DOUT"
fi
case_end

case_begin "target-without-tests-section-is-runner-error" "tests/run-all.sh"
dispatch_at target-none "$TGT_NONE"
assert_eq "nosettings-status=$(yaml_field status)" "nosettings-status=runner-error"
MG=0
printf '%s\n' "$(yaml_field summary)" | grep -q '/migrate' && MG=1
assert_eq "nosettings-summary-names-migrate=$MG" "nosettings-summary-names-migrate=1"
assert_eq "nosettings-test-ran=$(marker_seen)" "nosettings-test-ran=0"
[ "$MG" = "1" ] || show_out "$DOUT"
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $((FAIL > 0 ? 1 : 0))
