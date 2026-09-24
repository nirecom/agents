# shellcheck shell=bash
# Tests: hooks/workflow-gate.js, hooks/enforce-system-ops.js, rules/ops.md, rules/branch.md, rules/worktree.md
# Tags: rules-injection, on-demand-rules, skill-ownership, hook-wiring, observed-behavior, TL2, scope:common

# WHY (CPR-WPH): the ownership map in hooks/lib/rules-injection-policy.js records which
# SKILL.md Reads each de-injected rule. Two rules are not owned by a skill at all — they are
# owned by a HOOK, which tells the agent to Read them at the moment the rule becomes
# relevant. rules/ops.md arrives that way from enforce-system-ops.js when a destructive
# command is blocked, and rules/branch.md + rules/worktree.md arrive from workflow-gate.js
# when branching_complete is the step standing between the session and its commit.

# Those two instructions are the entire delivery path for those rules once auto-injection
# is off. If the hook stops emitting them, nothing else in the suite notices: the notation
# checks still pass, and the ownership map still lists an owner that no longer speaks.

# METHOD: both hooks are INVOKED for real over stdin and graded on what they emit, not
# grepped. A grep matches a string sitting in dead code, in a branch this input never
# reaches, or in a comment; and it misses an instruction assembled from parts. Each hook is
# driven twice — once through the branch that should carry the instruction and once through
# a branch that should not — so a constant footer cannot satisfy the assertion.
# Assumes AGENTS_DIR, BASE, node_path(), pass(), fail() from the entry file.

echo ""
echo "=== HW: the two rules delivered by a hook rather than by a SKILL.md Read ==="

HW_SYSOPS="$AGENTS_DIR/hooks/enforce-system-ops.js"
HW_GATE="$AGENTS_DIR/hooks/workflow-gate.js"

if [ ! -f "$HW_SYSOPS" ] || [ ! -f "$HW_GATE" ]; then
    fail "HW: IMPLEMENTATION MISSING: hooks/enforce-system-ops.js or hooks/workflow-gate.js"
else
    HW_ROOT="$BASE/hook-wiring"
    HW_WF="$HW_ROOT/wf"
    HW_PLANS="$HW_ROOT/plans"
    HW_REPO="$HW_ROOT/repo"
    mkdir -p "$HW_WF" "$HW_PLANS" "$HW_REPO/src"
    unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
    git -C "$HW_REPO" init -q >/dev/null 2>&1
    git -C "$HW_REPO" config core.hooksPath /dev/null
    git -C "$HW_REPO" config user.email fixture@example.com
    git -C "$HW_REPO" config user.name fixture
    printf 'const x = 1;\n' > "$HW_REPO/src/a.js"
    git -C "$HW_REPO" add src/a.js >/dev/null 2>&1

    # hw_sysops <command> — the hook's stderr for that command, with the ambient
    # SYSTEM_OPS_APPROVED stripped: the developer running this suite may well have the
    # bypass exported, and inheriting it would silence the hook and make every
    # absence-assertion below pass for a reason that has nothing to do with the code.
    # The hook's output goes to a FILE and only the exit code is printed: an exit code set
    # inside a command substitution dies with that subshell, which would report every run
    # as exit 0 no matter what the hook did.
    hw_sysops() {
        local cmd="$1" rc=0
        printf '{"tool_name":"Bash","tool_input":{"command":%s},"session_id":"hwsid2037"}' \
            "$(node -e 'process.stdout.write(JSON.stringify(String(process.argv[1])))' -- "$cmd")" \
            | env -u SYSTEM_OPS_APPROVED node "$(node_path "$HW_SYSOPS")" \
            > "$HW_ROOT/sysops-out.txt" 2>&1 || rc=$?
        printf '%s' "$rc"
    }

    HW_BLOCKED_RC="$(hw_sysops 'sudo apt-get install nginx')"
    HW_BLOCKED="$(cat "$HW_ROOT/sysops-out.txt")"
    HW_ALLOWED_RC="$(hw_sysops 'ls -la')"
    HW_ALLOWED="$(cat "$HW_ROOT/sysops-out.txt")"

    if [ "$HW_BLOCKED_RC" != "2" ]; then
        fail "HW1-live: the category-A command was not blocked (exit $HW_BLOCKED_RC, want 2) — the branch that delivers rules/ops.md never ran, so HW1 below would grade an empty string; output: $(printf '%s' "$HW_BLOCKED" | tr '\n' ' ' | cut -c1-200)"
    else
        pass "HW1-live: a category-A command is blocked (exit 2) — the delivery branch really ran"
    fi

    if printf '%s' "$HW_BLOCKED" | grep -q 'rules/ops\.md' \
       && printf '%s' "$HW_BLOCKED" | grep -q 'Read ' \
       && printf '%s' "$HW_BLOCKED" | grep -q 'on-demand-only'; then
        pass "HW1: the block tells the agent to Read rules/ops.md and says it is on-demand-only — the rule's only delivery path is intact"
    else
        fail "HW1: the block does not instruct a Read of rules/ops.md as an on-demand-only rule — the rule is de-injected AND unannounced, so the destructive-op decision path never reaches the agent; stderr: $(printf '%s' "$HW_BLOCKED" | tr '\n' ' ' | cut -c1-300)"
    fi

    # HW1-ctl: the negative control. HW1 asserts a substring is PRESENT; a hook that printed
    # the same banner on every input would satisfy it while saying nothing about the block
    # branch. A command in no category must answer differently on BOTH counts.
    if [ "$HW_ALLOWED_RC" = "0" ] && ! printf '%s' "$HW_ALLOWED" | grep -q 'rules/ops\.md'; then
        pass "HW1-ctl: a non-category command exits 0 and names no rule — HW1 measures the block branch, not a constant banner"
    else
        fail "HW1-ctl: an ordinary command answered exit $HW_ALLOWED_RC with output [$(printf '%s' "$HW_ALLOWED" | tr '\n' ' ' | cut -c1-200)] — HW1 cannot distinguish the block branch from unconditional output"
    fi

    # hw_state <status> — a workflow state whose only non-complete gated step is
    # branching_complete, so the gate's reason isolates that one instruction.
    hw_state() {
        local st="$1" f
        f='{"status":"complete","updated_at":"2026-04-11T10:01:00.000Z"}'
        cat > "$HW_WF/hwsid2037.json" <<HW_STATE_EOF
{"version":1,"session_id":"hwsid2037","created_at":"2026-04-11T10:00:00.000Z","closes_issues":[2037],
 "steps":{"workflow_init":$f,"clarify_intent":$f,"research":$f,"outline":$f,"detail":$f,
 "branching_complete":{"status":"$st","updated_at":null},
 "write_tests":$f,"review_tests":$f,"run_tests":$f,"review_security":$f,"docs":$f,
 "user_verification":$f,"cleanup":$f,"pre_final_report_gate":$f}}
HW_STATE_EOF
    }

    # AGENTS_CONFIG_DIR points at the fixture repo on purpose: the gate self-limits to the
    # agents session repo (isAgentsSessionRepo), so a fixture that is a different repo would
    # be waved through and every assertion below would pass without the gate ever deciding.
    hw_gate() {
        printf '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"},"cwd":"%s","session_id":"hwsid2037"}' \
            "$(node_path "$HW_REPO")" \
            | ( cd "$HW_REPO" && env \
                "CLAUDE_WORKFLOW_DIR=$HW_WF" "WORKFLOW_PLANS_DIR=$HW_PLANS" \
                "AGENTS_CONFIG_DIR=$HW_REPO" "CLAUDE_PROJECT_DIR=$HW_REPO" \
                node "$(node_path "$HW_GATE")" 2>/dev/null )
    }

    hw_state pending
    HW_GATE_BLOCK="$(hw_gate)"
    hw_state complete
    HW_GATE_OK="$(hw_gate)"

    if printf '%s' "$HW_GATE_BLOCK" | grep -q '"decision":"block"' \
       && printf '%s' "$HW_GATE_BLOCK" | grep -q 'branching_complete'; then
        pass "HW2-live: a pending branching_complete blocks the commit — the branch that delivers rules/branch.md + rules/worktree.md really ran"
    else
        fail "HW2-live: the gate did not block on a pending branching_complete — HW2 below would grade output from a branch that never fired; decision: $(printf '%s' "$HW_GATE_BLOCK" | tr '\n' ' ' | cut -c1-260)"
    fi

    if printf '%s' "$HW_GATE_BLOCK" | grep -q 'Read rules/branch\.md' \
       && printf '%s' "$HW_GATE_BLOCK" | grep -q 'rules/worktree\.md' \
       && printf '%s' "$HW_GATE_BLOCK" | grep -q 'on-demand-only'; then
        pass "HW2: the block tells the agent to Read rules/branch.md + rules/worktree.md and marks them on-demand-only — both rules reach the session at the step that needs them"
    else
        fail "HW2: the branching_complete instruction no longer names both de-injected rules as an on-demand-only Read — the agent is asked to record a branching decision without the rules that define it; reason: $(printf '%s' "$HW_GATE_BLOCK" | tr '\n' ' ' | cut -c1-400)"
    fi

    if printf '%s' "$HW_GATE_OK" | grep -q 'Read rules/branch\.md'; then
        fail "HW2-ctl: the same instruction appears when branching_complete is already complete — HW2 measures a constant string, not the step-specific hint"
    elif printf '%s' "$HW_GATE_OK" | grep -q '"decision":"approve"'; then
        pass "HW2-ctl: with the step complete the gate approves and emits no Read instruction — HW2 measures the branching_complete branch"
    else
        fail "HW2-ctl: the all-complete state neither approved nor stayed silent, so it cannot serve as the control; decision: $(printf '%s' "$HW_GATE_OK" | tr '\n' ' ' | cut -c1-260)"
    fi

    # HW3: the instructions must RESOLVE. Naming a path is not delivery — a hook that points
    # at a rule deleted or renamed by a later change sends the agent to a dead address, and
    # the string assertions above would still be green.
    HW3_MISSING=""
    for hw_rule in rules/ops.md rules/branch.md rules/worktree.md; do
        [ -f "$AGENTS_DIR/$hw_rule" ] || HW3_MISSING="$HW3_MISSING $hw_rule"
    done
    if [ -n "$HW3_MISSING" ]; then
        fail "HW3: the hooks name rule file(s) that do not exist in the tree:$HW3_MISSING — the Read instruction cannot be carried out"
    else
        pass "HW3: every rule path the two hooks name exists in the tree"
    fi
fi
