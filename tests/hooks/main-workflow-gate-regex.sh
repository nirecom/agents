#!/usr/bin/env bash
# Tests: hooks/workflow-gate.js
# Tags: workflow, gate, hook, regex, table-driven, scope:common, merge-gate
# Tests for workflow-gate.js commit detection regex
# Tests the FIXED regex: /^git\s+(?:-C\s+\S+\s+)?commit\s/

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# #1787 merge-gate cases below spawn the hook: pin state/plans dirs before any exec.
GATE_TMP_ROOT="$(mktemp -d)"
readonly GATE_TMP_ROOT
trap 'rm -rf "$GATE_TMP_ROOT"' EXIT
mkdir -p "$GATE_TMP_ROOT/state" "$GATE_TMP_ROOT/plans" "$GATE_TMP_ROOT/neutral"
export WORKFLOW_STATE_DIR="$GATE_TMP_ROOT/state" WORKFLOW_PLANS_DIR="$GATE_TMP_ROOT/plans"
unset CLAUDE_CODE_SESSION_ID

PASS=0
FAIL=0

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then echo "PASS: $name"; PASS=$((PASS + 1))
    else echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1)); fi
}

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm '"$secs"'; exec @ARGV' -- "$@"; fi
}

eval_regex() {
    local input="$1"
    TEST_CMD="$input" run_with_timeout 30 node -e "
const regex = /^git\s+(?:-C\s+\S+\s+)?commit\s/;
process.stdout.write(regex.test(process.env.TEST_CMD) ? 'match' : 'no-match');
"
}

echo "=== workflow-gate.js commit regex tests ==="
echo "Testing fixed regex: /^git\\s+(?:-C\\s+\\S+\\s+)?commit\\s/"
echo ""

while IFS='|' read -r name input want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    input="${input# }"
    input="${input%"${input##*[! ]}"}"
    want="${want//[[:space:]]/}"
    got=$(eval_regex "$input")
    assert_eq "$name" "$want" "$got"
done <<'TABLE'
normal-simple-commit                | git commit -m "msg"                                           | match
normal-dash-C-path                  | git -C /path/repo commit -m "msg"                             | match
normal-dash-C-windows-path          | git -C c:\git\dotfiles commit -m "msg"                        | match
no-match-git-status                 | git status                                                     | no-match
no-match-leading-spaces             |  git commit -m "msg"                                          | no-match
fp-uv-run-with-git-commit-in-arg    | uv run bin/doc-append.py --background "git commit blocked"    | no-match
fp-echo-git-commit-message          | echo "git commit message"                                     | no-match
TABLE

# #1787: the legacy merge gate must read readState().current.steps (event-stream
# shape), not the v1 top-level `steps`. No supervisor state exists (empty plans dir).
echo ""
echo "=== #1787 merge gate reads the current.steps projection ==="
AGENTS_NODE="$SCRIPT_CHECKOUT_ROOT"
command -v cygpath >/dev/null 2>&1 && AGENTS_NODE="$(cygpath -m "$SCRIPT_CHECKOUT_ROOT")"
GATE_JS="$AGENTS_NODE/hooks/workflow-gate.js"

# merge_state <sid> <uv-status> <shape:v1|stream> — every VALID_STEP complete except user_verification.
merge_state() {
    run_with_timeout 30 node -e '
const fs=require("fs");const [a,sid,uv]=process.argv.slice(1);
const {VALID_STEPS}=require(a+"/hooks/workflow-state");const steps={};
for(const s of VALID_STEPS) steps[s]={status:s==="user_verification"?uv:"complete",updated_at:"2026-06-27T10:00:00.000Z"};
fs.writeFileSync(process.env.WORKFLOW_STATE_DIR+"/"+sid+".json",JSON.stringify({version:1,session_id:sid,created_at:"2026-06-27T10:00:00.000Z",steps}));
' "$AGENTS_NODE" "$1" "$2"
    if [ "$3" = stream ]; then
        # Seeding an event upgrades the file to the event-stream (v4) shape.
        run_with_timeout 30 node "$AGENTS_NODE/tests/lib/workflow-state-tool.js" "$AGENTS_NODE" seed "$1" \
            '[{"kind":"worktree","transition":"entered","cwd":"C:/nonexistent-1787","worktree_path":"C:/nonexistent-1787","git_branch":"fixture","path_source":"tool_input"}]'
        local ver
        ver="$(node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).version))' "$WORKFLOW_STATE_DIR/$1.json")"
        assert_eq "fixture-$1-is-event-stream" "4" "$ver"
    fi
}

# merge_gate <sid> — prints the gate's decision JSON for `gh pr merge 1 --merge`.
merge_gate() {
    local payload
    payload="{\"tool_name\":\"Bash\",\"session_id\":\"$1\",\"tool_input\":{\"command\":\"gh pr merge 1 --merge\"}}"
    (cd "$GATE_TMP_ROOT/neutral" && printf '%s' "$payload" | run_with_timeout 60 node "$GATE_JS" 2>/dev/null)
}

decision_of() { node -e 'try{process.stdout.write(JSON.parse(process.argv[1]).decision||"none")}catch(e){process.stdout.write("unparseable")}' "$1"; }

merge_state mg-stream-ok complete stream
out="$(merge_gate mg-stream-ok)"
assert_eq "merge-gate-stream-uv-complete-approves" "approve" "$(decision_of "$out")"

merge_state mg-stream-pending pending stream
out="$(merge_gate mg-stream-pending)"
assert_eq "merge-gate-stream-uv-pending-blocks" "block" "$(decision_of "$out")"
case "$out" in *'\"pending\"'*|*'"pending"'*) got=yes ;; *) got=no ;; esac
assert_eq "merge-gate-stream-message-names-pending" "yes" "$got"
case "$out" in *missing*) got=yes ;; *) got=no ;; esac
assert_eq "merge-gate-stream-message-not-missing" "no" "$got"

merge_state mg-v1-ok complete v1
out="$(merge_gate mg-v1-ok)"
assert_eq "merge-gate-v1-uv-complete-approves" "approve" "$(decision_of "$out")"

if grep -q '\.current\.steps' "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-gate.js"; then got=yes; else got=no; fi
assert_eq "merge-gate-source-reads-current-steps" "yes" "$got"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
