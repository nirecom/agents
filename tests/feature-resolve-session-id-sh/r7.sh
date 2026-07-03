# r7.sh — R7: issue-close-write-outcome.js normal mode (B-29)
# Sourced by feature-resolve-session-id-sh.sh; inherits all globals and helpers.

# ===========================================================================
# B-29: issue-close-write-outcome.js normal mode — writes outcome JSON.
# CLAUDE_CODE_SESSION_ID=own-sid-b29; WORKFLOW_PLANS_DIR=absolute temp dir.
#
# RED pre-fix: the current private resolveSessionId() JSON.parses the CLAUDE_ENV_FILE
# (always throws because the file is KEY=VALUE, not JSON) and then falls back to
# CLAUDE_SESSION_ID env var only — never reads CLAUDE_CODE_SESSION_ID. So with
# only CLAUDE_CODE_SESSION_ID set, resolveSessionId() returns "" and no file is
# written (exits 0, outcome JSON absent).
#
# GREEN post-fix: private resolveSessionId() delegates to
# require(hooks/lib/workflow-state).resolveSessionId() which checks
# CLAUDE_CODE_SESSION_ID first (P2) and the file is written.
# ===========================================================================
setup
PLANS_DIR="$TMP/b29-plans"
mkdir -p "$PLANS_DIR"
NONGIT_CWD="$TMP/b29-nongit"
mkdir -p "$NONGIT_CWD"
OUTCOME_FILE="$PLANS_DIR/own-sid-b29-issue-close-outcome.json"

bash -c "
    unset CLAUDE_SESSION_ID CLAUDE_ENV_FILE
    export CLAUDE_CODE_SESSION_ID='own-sid-b29'
    export WORKFLOW_PLANS_DIR='$PLANS_DIR'
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
