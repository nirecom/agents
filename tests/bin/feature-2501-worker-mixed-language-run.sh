#!/usr/bin/env bash
# tests/bin/feature-2501-worker-mixed-language-run.sh
# Tests: bin/worker-dispatch/workers/test-runner.js, bin/lib/test-wrappers/node.js, tests/run-all.sh
# Tags: worker-dispatch, test-runner, test-language-registry, node-test, mixed-language, integration, TL2, scope:issue-specific
#
# #2501 D7 main path in the default run (no RUN_TL3 gate): the real dispatcher drives the real
# tests/run-all.sh over one bash + one node:test file in a fixture repo whose language table
# holds only the runtimes this host is sure to have. Pester joins only in the TL3 sibling,
# tests/bin/TL3-worker-dispatch-mixed-language-run.sh.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH"; exit 77; }

DISPATCH_JS="$SCRIPT_CHECKOUT_ROOT/bin/worker-dispatch.js"
TMPD="$(make_tmp)"
readonly TMPD
trap 'rm -rf "$TMPD"' EXIT
harness_isolate "$TMPD/isolate"
unset CLAUDE_CODE_SESSION_ID

# --- fixture repo: the branch's runner + libraries, a bash/js-only language table -------
FIX="$TMPD/fixrepo"
mkdir -p "$FIX/tests/bin"
harness_git_init "$FIX"
cp -r "$SCRIPT_CHECKOUT_ROOT/bin" "$FIX/bin"
cp -r "$SCRIPT_CHECKOUT_ROOT/hooks" "$FIX/hooks"
cp -r "$SCRIPT_CHECKOUT_ROOT/tests/lib" "$FIX/tests/lib"
# The runner's root decoy reads the retired names from this file; it is not run here.
cp "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2561-root-names-residue.sh" "$FIX/tests/bin/"
cp "$SCRIPT_CHECKOUT_ROOT/tests/run-all.sh" "$FIX/tests/.real-run-all.sh"
# Host lanes and the duration ledger key on the real HOME; the fixture runs without them.
rm -f "$FIX/bin/lib/test-host-lanes.sh" "$FIX/bin/lib/run-all-durations.sh"
node -e '
const fs = require("fs");
const f = process.argv[1];
const t = JSON.parse(fs.readFileSync(f, "utf8"));
t.entries = t.entries.filter((e) => e.id !== "pester" && e.id !== "pytest");
fs.writeFileSync(f, JSON.stringify(t, null, 2));
' "$(np "$FIX/hooks/lib/test-language-registry.json")"
# A wrapper keeps the real runner's full stdout: log_tail drops PASS case lines by contract.
RUNNER_LOG="$TMPD/runner.out"
printf '#!/usr/bin/env bash\nbash "%s" "$@" >"%s" 2>&1\nrc=$?\ncat "%s"\nexit "$rc"\n' \
  "$FIX/tests/.real-run-all.sh" "$RUNNER_LOG" "$RUNNER_LOG" >"$FIX/tests/run-all.sh"

# The fixture's own frontmatter is printed, not spelled at line start (one header per file).
printf '#!/usr/bin/env bash\n# %s: tests/lib/harness.sh\n# %s: fixture, scope:issue-specific\n' Tests Tags >"$FIX/tests/bin/mixed-bash.sh"
cat >>"$FIX/tests/bin/mixed-bash.sh" <<'BASHFIX'
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
case_begin "mixed-bash-case" "tests/lib/harness.sh"
assert_eq "$(printf 'a%s' b)" "ab"
case_end
exit $((FAIL > 0 ? 1 : 0))
BASHFIX
cat >"$FIX/tests/bin/mixed.test.js" <<'JSFIX'
const test = require("node:test");
const assert = require("node:assert");
test("mixed js adds", () => { assert.strictEqual(1 + 1, 2); });
JSFIX
cat >"$FIX/tests/bin/broken.test.js" <<'JSFIX'
const test = require("node:test");
const assert = require("node:assert");
test("mixed js breaks", () => { assert.strictEqual(1 + 1, 3); });
JSFIX
git -C "$FIX" add -A >/dev/null 2>&1
git -C "$FIX" -c user.name=t -c user.email=t@example.com commit -q --no-verify -m fixture >/dev/null 2>&1
FIXN="$(np "$FIX")"

DOUT=""
DRC=0
# dispatch <name> <selection-json-items> — one worker call over the fixture, 180 s budget.
dispatch() {
  local pfile="$WORKFLOW_PLANS_DIR/$1.json"
  printf '{"cwd":"%s","test_args":[%s],"timeout_seconds":180,"jobs":1}' "$FIXN" "$2" >"$pfile"
  : >"$RUNNER_LOG"
  DRC=0
  DOUT="$(run_with_timeout 200 node "$(np "$DISPATCH_JS")" test-runner "$FIXN" "$(np "$pfile")" 2>&1)" || DRC=$?
}
yaml_field() { printf '%s\n' "$DOUT" | sed -n "s/^$1: //p" | head -1; }
# Only the value is read back: a raw contract line in this file's stdout would be read by run-all.
contract_value() { printf '%s\n' "$DOUT" | sed -n 's/^RUN_CONTRACT: //p' | head -1; }
has_line() { grep -qE "$2" "$1" 2>/dev/null && echo 1 || echo 0; }
show_out() { printf '%s\n' "$1" | tail -n 30 | sed 's/^/    | /'; }

dispatch green '"tests/bin/mixed-bash.sh","tests/bin/mixed.test.js"'

case_begin "mixed-bash-and-node-pass-through-worker" "bin/worker-dispatch/workers/test-runner.js"
assert_eq "status=$(yaml_field status) rc=$DRC" "status=pass rc=0"
assert_eq "contract=$(contract_value)" "contract=PASS=2 FAIL=0 SKIP=0 EXECUTED=2 UNRUNNABLE=0 TIMEOUT=0"
[ "$(yaml_field status)" = "pass" ] || show_out "$DOUT"
case_end

case_begin "node-file-runs-through-its-wrapper" "bin/lib/test-wrappers/node.js"
assert_eq "js-case-line=$(has_line "$RUNNER_LOG" '^PASS [^ ]*mixed\.test\.js::.*mixed js adds')" "js-case-line=1"
case_end

case_begin "runner-emits-both-languages-case-lines" "tests/run-all.sh"
assert_eq "bash-case-line=$(has_line "$RUNNER_LOG" '^PASS [^ ]*mixed-bash\.sh::mixed-bash-case target=tests/lib/harness\.sh$')" "bash-case-line=1"
assert_eq "bash-file-line=$(has_line "$RUNNER_LOG" '^PASS: .*mixed-bash\.sh$')" "bash-file-line=1"
assert_eq "js-file-line=$(has_line "$RUNNER_LOG" '^PASS: .*mixed\.test\.js$')" "js-file-line=1"
case_end

dispatch red '"tests/bin/mixed-bash.sh","tests/bin/broken.test.js"'

case_begin "failing-node-file-fails-the-mixed-run" "bin/worker-dispatch/workers/test-runner.js"
assert_eq "red status=$(yaml_field status) exit_code=$(yaml_field exit_code)" "red status=fail exit_code=1"
assert_eq "red contract=$(contract_value)" "red contract=PASS=1 FAIL=1 SKIP=0 EXECUTED=2 UNRUNNABLE=0 TIMEOUT=0"
FT=0
printf '%s\n' "$DOUT" | grep -qE '^  - .*broken\.test\.js' && FT=1
assert_eq "red failing_tests names broken.test.js=$FT" "red failing_tests names broken.test.js=1"
[ "$FT" = "1" ] || show_out "$DOUT"
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $((FAIL > 0 ? 1 : 0))
