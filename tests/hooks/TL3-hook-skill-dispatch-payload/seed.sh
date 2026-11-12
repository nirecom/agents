#!/usr/bin/env bash
# Part file of TL3-hook-skill-dispatch-payload.sh (sourced; defines p3_seed_state only).
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/glossary-check-record.sh"

# p3_seed_state <sid> — leave the downstream at the point where the hook marks `research`:
# a fixture git repo (the hook's cwd), a plan, a glossary-check record, an approval and
# workflow_init + clarify_intent complete. Sets P3_REPO and P3_REPO_NODE.
p3_seed_state() {
    local sid="${1:?sid required}" root_node
    root_node="$(p3_node_path "$SCRIPT_CHECKOUT_ROOT")"
    P3_REPO="$P3_DIR/repo"
    P3_REPO_NODE="$(p3_node_path "$P3_REPO")"
    mkdir -p "$P3_WF" "$P3_TRANSCRIPTS" "$P3_REPO"
    git init -q "$P3_REPO" >/dev/null 2>&1
    git -C "$P3_REPO" config core.hooksPath /dev/null >/dev/null 2>&1
    (
        cd "$P3_REPO" || exit 2
        unset CLAUDE_CODE_SESSION_ID
        export WORKFLOW_STATE_DIR="$P3_WF" WORKFLOW_PLANS_DIR="$P3_WF" CLAUDE_TRANSCRIPT_BASE_DIR="$P3_TRANSCRIPTS" AGENTS_MAIN_ROOT="$root_node"
        P3_SID="$sid" node -e "require('$root_node/tests/lib/plan-approval-fixture.js').ensurePlan(process.env.P3_SID, 'clarify_intent');"
        glossary_check_record "$sid" "$P3_REPO_NODE" clarify_intent
        P3_SID="$sid" node -e "
const { markStep } = require('$root_node/hooks/workflow-state/state-io.js');
const fx = require('$root_node/tests/lib/plan-approval-fixture.js');
markStep(process.env.P3_SID, 'workflow_init', 'complete');
fx.approveLive(process.env.P3_SID, 'clarify_intent');
markStep(process.env.P3_SID, 'clarify_intent', 'complete');"
    ) >/dev/null 2>&1
}
