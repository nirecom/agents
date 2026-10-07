# r7.sh — R7: issue-close-write-outcome.js normal mode (B-29)
# Sourced by feature-resolve-session-id-sh.sh; inherits all globals and helpers.

# ===========================================================================
# B-29: issue-close-write-outcome.js normal mode — writes outcome JSON with only CLAUDE_CODE_SESSION_ID set.
# RED pre-fix: the old private resolveSessionId() never read CLAUDE_CODE_SESSION_ID → no file written.
# GREEN post-fix: it delegates to hooks/workflow-state resolveSessionId() (CLAUDE_CODE_SESSION_ID first, P2).
# #2434: the outcome file is a control file — <WORKFLOW_STATE_DIR>/<sid>.control/issue-close-outcome.json.
# ===========================================================================
setup
PLANS_DIR="$TMP/b29-plans"
WF_DIR="$TMP/b29-workflow"
mkdir -p "$PLANS_DIR" "$WF_DIR"
NONGIT_CWD="$TMP/b29-nongit"
mkdir -p "$NONGIT_CWD"
OUTCOME_FILE="$WF_DIR/own-sid-b29.control/issue-close-outcome.json"

bash -c "
    export CLAUDE_CODE_SESSION_ID='own-sid-b29'
    export WORKFLOW_PLANS_DIR='$PLANS_DIR'
    export WORKFLOW_STATE_DIR='$WF_DIR'
    export AGENTS_CONFIG_DIR='$AGENTS_DIR'
    cd '$NONGIT_CWD'
    node '$AGENTS_DIR/bin/issue-close-write-outcome.js' 999 completed appended closed posted cleared
" 2>/dev/null
# Verification passes the file as argv — MSYS converts path-like arguments but
# not paths embedded in program text (same technique as the enc() helper).
if [ -f "$OUTCOME_FILE" ] && node -e "
    const b = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
    if (!b.issues || !b.issues.find(e=>e.issueNumber===999)) process.exit(1);
" "$OUTCOME_FILE" 2>/dev/null; then
    pass "B-29: issue-close-write-outcome.js writes outcome JSON for CLAUDE_CODE_SESSION_ID (post-fix GREEN)"
else
    fail "B-29: outcome file missing or lacks issueNumber 999 — pre-fix RED (CLAUDE_CODE_SESSION_ID not read by old resolveSessionId)"
fi
teardown
