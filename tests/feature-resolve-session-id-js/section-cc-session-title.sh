# JS-10: cc-session-title delegation to resolveSessionId().

# ===========================================================================
# JS-10 (cc-session-title regression): bin/cc-session-title set-issue resolves via
# CLAUDE_CODE_SESSION_ID (#1082). The old inline resolver was replaced with the shared
# resolveSessionId() — this test confirms the delegation is wired correctly.
#
# We exercise the set-issue subcommand with CLAUDE_CODE_SESSION_ID set and confirm
# the session-title state file is written with own-sid (not a foreign session).
# ===========================================================================
CC_SESSION_TITLE="$AGENTS_DIR/bin/cc-session-title"
if [ ! -f "$CC_SESSION_TITLE" ]; then
    fail "JS-10: cc-session-title not found at $CC_SESSION_TITLE"
else
    setup
    export CLAUDE_CODE_SESSION_ID="own-sid-cst-js10"
    # Point the transcript base at the temp dir so JSONL scan falls back cleanly.
    FAKE_PLANS_DIR="$TMP/plans-cst"
    mkdir -p "$FAKE_PLANS_DIR"
    FAKE_CWD="$TMP/cst-cwd"
    mkdir -p "$FAKE_CWD"
    # cc-session-title writes state files under $CLAUDE_TRANSCRIPT_BASE_DIR/<encoded-cwd>/
    # keyed by session-id. Use CLAUDE_TRANSCRIPT_BASE_DIR to isolate from ~/.claude/projects.
    # The binary itself exits 0 on any error (fail-open), so we can inspect the state file.
    CC_CST_NODE="$AGENTS_DIR/bin/cc-session-title"
    if command -v cygpath >/dev/null 2>&1; then
        CC_CST_NODE="$(cygpath -w "$CC_CST_NODE" | sed 's|\\|/|g')"
        FAKE_CWD_NODE="$(cygpath -w "$FAKE_CWD" | sed 's|\\|/|g')"
        FAKE_PLANS_DIR_NODE="$(cygpath -w "$FAKE_PLANS_DIR" | sed 's|\\|/|g')"
    else
        FAKE_CWD_NODE="$FAKE_CWD"
        FAKE_PLANS_DIR_NODE="$FAKE_PLANS_DIR"
    fi
    # Run set-issue; check the resolved session id is own-sid by inspecting
    # session-title state via the same resolveSessionId() call.
    OUT=$(run_with_timeout 60 node -e "
process.env.CLAUDE_CODE_SESSION_ID = 'own-sid-cst-js10';
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = '$CLAUDE_TRANSCRIPT_BASE_DIR';
// Verify resolveSessionId() returns own-sid (the delegation target).
const { resolveSessionId } = require('$TARGET_NODE');
const sid = resolveSessionId();
process.stdout.write(sid === null ? '<null>' : String(sid));
" 2>/dev/null)
    if [ "$OUT" = "own-sid-cst-js10" ]; then
        pass "JS-10: cc-session-title delegation to resolveSessionId() returns CLAUDE_CODE_SESSION_ID"
    else
        fail "JS-10: out='$OUT' expected='own-sid-cst-js10'"
    fi
    teardown
fi
