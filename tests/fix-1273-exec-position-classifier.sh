#!/usr/bin/env bash
# tests/fix-1273-exec-position-classifier.sh
# Tests: hooks/workflow-run-tests/exec-model.js, hooks/lib/command-ir.js
# Tags: workflow, tests, runner, hook, classifier, table-driven, TL1, scope:common
#
# Issue #1273 — workflow-run-tests.js demoted run_tests whenever the string
# `tests/` appeared ANYWHERE in a resolved segment, so a command that merely
# mentions a test path in an argument value (a supervisor-report --detail body,
# a gh issue body) was classified as a test run. The replacement is an
# EXECUTION-POSITION model: only three token positions can be executed —
#   P0  the resolved cmd0 itself,
#   P1  the interpreter's script/module operand,
#   P2  the worker name after a known dispatcher script at P1.
# A token that appears only as an argument VALUE is never in an execution
# position, so it cannot demote regardless of what it spells.
#
# This is the TL1 tier: hooks/workflow-run-tests/exec-model.js is required
# directly, so the classifier is exercised without the hook's stdin/state
# machinery. Both directions are covered (test-design protection-fix Pattern 4):
# the must-NOT-demote list is as load-bearing as the must-demote list, because a
# classifier that demotes nothing also passes every must-NOT row.
#
# TL3 gap (what this TL1 test does NOT catch):
#   - Whether the hook actually consults this classifier before its provenance /
#     contract branches (the #1273 early return at workflow-run-tests.js:171).
#     tests/main-workflow-run-tests/detection-matrix.sh and
#     tests/main-workflow-run-tests/quoted-arg-and-provenance.sh are the TL2 tier
#     for that, and tests/TL3-worker-dispatch-run-tests.sh the TL3 tier.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: hook-registration.

set -u

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
EXEC_MODEL_JS="$(nodepath "$AGENTS_DIR")/hooks/workflow-run-tests/exec-model.js"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

# The module is the subject; its absence is a FAIL, never a skip — a skip here
# would let the whole fix land unverified.
if [ ! -f "$AGENTS_DIR/hooks/workflow-run-tests/exec-model.js" ]; then
    fail "0/module-present — implementation missing: hooks/workflow-run-tests/exec-model.js"
fi

# classify <command> → yes | no | ERR
classify() {
    run_with_timeout 30 node -e '
try {
  const m = require(process.argv[1]);
  if (typeof m.isTestCommand !== "function") { process.stdout.write("ERR"); process.exit(0); }
  process.stdout.write(m.isTestCommand(process.argv[2]) ? "yes" : "no");
} catch (e) { process.stdout.write("ERR"); }
' "$EXEC_MODEL_JS" "$1" 2>/dev/null
}

# positions <command> → "P0:<v> P1:<v> P2:<v>" for the first segment
positions() {
    run_with_timeout 30 node -e '
try {
  const m = require(process.argv[1]);
  const { parse, resolveEffectiveSegment } = require(process.argv[3]);
  const ir = parse(process.argv[2]);
  for (const seg of ir.segments) {
    const eff = resolveEffectiveSegment(seg);
    if (eff === null || eff.cmd0 === "") continue;
    const t = m.execTargets(eff);
    process.stdout.write(t.map((x) => x.position + ":" + x.value).join(" "));
    process.exit(0);
  }
  process.stdout.write("(none)");
} catch (e) { process.stdout.write("ERR"); }
' "$EXEC_MODEL_JS" "$1" "$(nodepath "$AGENTS_DIR")/hooks/lib/command-ir.js" 2>/dev/null
}

# ===========================================================================
# Group 1 — must NOT demote (argument-value mentions, non-exec heads, BODY forms)
# ===========================================================================
# Separator is `~` because several commands embed `|`-free but quote-rich text and
# the expected column must stay unambiguous.
while IFS='~' read -r label cmd want; do
    [ -z "$label" ] && continue
    case "$label" in '#'*) continue ;; esac
    assert_eq "N/$label" "$want" "$(classify "$cmd")"
done <<'TABLE'
# --- #1273 seed: the path is an argument VALUE, never an execution position ---
supervisor-report-detail~node bin/supervisor-report --detail "ran tests/feature-x.sh and it passed"~no
gh-issue-body~gh issue create --body "see tests/foo.sh"~no
# --- lookup, not execution (READ_ONLY_CMDS absorbed as "head not in any table") ---
which-pytest~which pytest~no
command-v-pytest~command -v pytest~no
# --- git that executes nothing ---
git-archive~git archive tests/~no
# --- word-boundary false positive ---
contest-dir~node script.js contest/foo.sh~no
# --- BODY forms: the command text is folded into ONE argv token, never recursed
#     into (Risk 3 — recursing would reintroduce the second judgement axis) ---
bash-c-body~bash -c "bash tests/foo.sh"~no
pwsh-command-body~pwsh -Command "Invoke-Pester tests/X.Tests.ps1"~no
git-rebase-exec~git rebase -x "bash tests/foo.sh" main~no
git-filter-branch~git filter-branch --tree-filter 'bash tests/foo.sh' HEAD~no
git-submodule-foreach-body~git submodule foreach 'bash tests/foo.sh'~no
perl-e-body~perl -e 'run tests/x'~no
# --- interpreter option VALUE, not the script operand ---
node-require-value~node --require tests/setup.js app.js~no
# --- #1105 direction: git global-option values must stay out of exec position ---
git-C-tests~git -C tests/ diff~no
git-C-path-diff~git -C /path diff tests/foo.sh~no
git-worktree-inline~git --work-tree=/x diff tests/~no
TABLE

# ===========================================================================
# Group 2 — must demote (a real execution position spells a test target)
# ===========================================================================
while IFS='~' read -r label cmd want; do
    [ -z "$label" ] && continue
    case "$label" in '#'*) continue ;; esac
    assert_eq "Y/$label" "$want" "$(classify "$cmd")"
done <<'TABLE'
bash-script~bash tests/foo.sh~yes
# Quoting is NOT an input to the judgement: a quoted operand is still the operand.
bash-script-quoted~bash "tests/foo.sh"~yes
pytest-p0~pytest tests/~yes
uv-run-pytest~uv run pytest tests/~yes
python-m-pytest~python -m pytest tests/~yes
python-m-unittest~python -m unittest discover tests/~yes
node-script~node tests/bar.js~yes
node-require-then-target~node --require ./setup.js tests/foo.js~yes
invoke-pester~Invoke-Pester tests/X.Tests.ps1~yes
powershell-file~PowerShell.exe -File tests/X.ps1~yes
bare-pester-script~x.Tests.ps1~yes
timeout-bash~timeout 120 bash tests/foo.sh~yes
timeout-k-bash~timeout -k 5 120 bash tests/foo.sh~yes
env-nice-bash~env FOO=1 nice -n 10 bash tests/foo.sh~yes
# `git bisect run` splits the command across SEPARATE argv tokens, so recursion
# is well-defined — the asymmetry with `git rebase -x` above is deliberate.
git-bisect-run-script~git bisect run tests/foo.sh~yes
git-bisect-run-bash~git bisect run bash tests/foo.sh~yes
# WD-3 canonical dispatch form: P1=worker-dispatch.js, P2=test-runner.
worker-dispatch-test-runner~node /r/bin/worker-dispatch.js test-runner /r /p/s-worker-test-runner.json~yes
TABLE

# ===========================================================================
# Group 3 — shared depth budget: one increment per level actually entered
#
# The budget is a single shared counter with a ceiling of 5; overflow truncates
# to "P0 only" (fail-safe = miss, not false demote). These two rows pin the
# boundary from BOTH sides, so a re-count that charges the head-table re-lookup
# as a separate increment (the W-10 self-contradiction) fails here rather than
# silently moving the cut-off.
# ===========================================================================
assert_eq "D/depth-4-prefix-runners-still-detected" "yes" \
    "$(classify 'timeout 120 env FOO=1 nice -n 10 sudo bash tests/foo.sh')"
assert_eq "D/depth-6-prefix-runners-truncate-to-P0" "no" \
    "$(classify 'nohup stdbuf -oL timeout 120 env FOO=1 nice -n 10 sudo bash tests/foo.sh')"

# ===========================================================================
# Group 4 — the position labels themselves
#
# classify() alone cannot distinguish "right answer" from "right answer for the
# wrong reason": a classifier that returned P0 for every token would pass Group 2.
# ===========================================================================
assert_eq "P/dispatch-form-positions" \
    "P0:node P1:/r/bin/worker-dispatch.js P2:test-runner" \
    "$(positions 'node /r/bin/worker-dispatch.js test-runner /r /p/s-worker-test-runner.json')"
assert_eq "P/interpreter-script-is-P1" \
    "P0:bash P1:tests/foo.sh" \
    "$(positions 'bash tests/foo.sh')"
assert_eq "P/argument-value-is-not-a-position" \
    "P0:node P1:bin/supervisor-report" \
    "$(positions 'node bin/supervisor-report --detail "ran tests/feature-x.sh"')"
assert_eq "P/python-dash-m-module-is-P1" \
    "P0:python P1:pytest" \
    "$(positions 'python -m pytest tests/')"

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
