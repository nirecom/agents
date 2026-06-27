# JS-1 through JS-9: JSONL fallback + priority chain regression guards.

# ===========================================================================
# JS-1: JSONL fallback path — no ctx, no CLAUDE_ENV_FILE, CLAUDE_PROJECT_DIR
# points at fixture; resolveSessionId() returns the JSONL basename.
# ===========================================================================
setup
export CLAUDE_PROJECT_DIR="C:/git/test"
PROJDIR_ENCODED=$(encode_path "$CLAUDE_PROJECT_DIR")
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED"
echo "{}" > "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED/jsonl-sid-js1.jsonl"
# cd to $TMP so WORKTREE_NOTES.md in the worktree CWD cannot short-circuit the resolver.
OUT=$(cd "$TMP" && run_with_timeout 60 env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID node -e "
const m = require('$TARGET_NODE');
const r = m.resolveSessionId();
process.stdout.write(r === null ? '<null>' : String(r));
" 2>/dev/null)
if [ "$OUT" = "jsonl-sid-js1" ]; then
    pass "JS-1: resolveSessionId falls through to JSONL scan when prior paths fail"
else
    fail "JS-1: out='$OUT' expected='jsonl-sid-js1'"
fi
teardown

# ===========================================================================
# JS-2: No JSONL dir → returns null.
# ===========================================================================
setup
export CLAUDE_PROJECT_DIR="C:/git/no-such-dir"
# Do not create the encoded subdir.
# cd to $TMP so WORKTREE_NOTES.md in the worktree CWD cannot short-circuit the resolver.
OUT=$(cd "$TMP" && run_with_timeout 60 env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID node -e "
const m = require('$TARGET_NODE');
const r = m.resolveSessionId();
process.stdout.write(r === null ? '<null>' : String(r));
" 2>/dev/null)
if [ "$OUT" = "<null>" ]; then
    pass "JS-2: resolveSessionId returns null when no JSONL fixture exists"
else
    fail "JS-2: out='$OUT' expected='<null>'"
fi
teardown

# ===========================================================================
# JS-3: ctx.sessionIdFromInput wins (priority 1 — regression guard).
# ===========================================================================
setup
export CLAUDE_PROJECT_DIR="C:/git/test"
PROJDIR_ENCODED=$(encode_path "$CLAUDE_PROJECT_DIR")
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED"
echo "{}" > "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED/jsonl-loser.jsonl"
OUT=$(run_with_timeout 60 node -e "
const m = require('$TARGET_NODE');
const r = m.resolveSessionId({ sessionIdFromInput: 'ctx-sid-wins' });
process.stdout.write(r === null ? '<null>' : String(r));
" 2>/dev/null)
if [ "$OUT" = "ctx-sid-wins" ]; then
    pass "JS-3: ctx.sessionIdFromInput beats JSONL scan (priority 1 invariant)"
else
    fail "JS-3: out='$OUT' expected='ctx-sid-wins'"
fi
teardown

# ===========================================================================
# JS-4: ctx.transcriptPath wins over JSONL (priority 3 invariant).
# ===========================================================================
setup
export CLAUDE_PROJECT_DIR="C:/git/test"
PROJDIR_ENCODED=$(encode_path "$CLAUDE_PROJECT_DIR")
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED"
echo "{}" > "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED/jsonl-loser.jsonl"
OUT=$(run_with_timeout 60 node -e "
const m = require('$TARGET_NODE');
const r = m.resolveSessionId({ transcriptPath: '/some/path/transcript-sid-wins.jsonl' });
process.stdout.write(r === null ? '<null>' : String(r));
" 2>/dev/null)
if [ "$OUT" = "transcript-sid-wins" ]; then
    pass "JS-4: ctx.transcriptPath beats JSONL scan (priority 3 invariant)"
else
    fail "JS-4: out='$OUT' expected='transcript-sid-wins'"
fi
teardown

# ===========================================================================
# JS-5: CLAUDE_ENV_FILE wins over JSONL (priority 2 invariant).
# ===========================================================================
setup
ENV_FILE="$TMP/claude-env-js5"
echo "CLAUDE_SESSION_ID=env-file-sid-wins" > "$ENV_FILE"
export CLAUDE_ENV_FILE="$ENV_FILE"
export CLAUDE_PROJECT_DIR="C:/git/test"
PROJDIR_ENCODED=$(encode_path "$CLAUDE_PROJECT_DIR")
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED"
echo "{}" > "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED/jsonl-loser.jsonl"
OUT=$(run_with_timeout 60 env -u CLAUDE_CODE_SESSION_ID node -e "
const m = require('$TARGET_NODE');
const r = m.resolveSessionId();
process.stdout.write(r === null ? '<null>' : String(r));
" 2>/dev/null)
if [ "$OUT" = "env-file-sid-wins" ]; then
    pass "JS-5: CLAUDE_ENV_FILE beats JSONL scan (priority 2 invariant)"
else
    fail "JS-5: out='$OUT' expected='env-file-sid-wins'"
fi
teardown

# ===========================================================================
# JS-6: CLAUDE_CODE_SESSION_ID beats a newer foreign JSONL (#1082 concurrent-session fix).
# A JSONL for a different (foreign) session exists and is the most-recently-modified.
# CLAUDE_CODE_SESSION_ID must take priority and the resolver must return own-sid, not
# the foreign session id.
# ===========================================================================
setup
export CLAUDE_CODE_SESSION_ID="own-sid-js6"
export CLAUDE_PROJECT_DIR="C:/git/test"
PROJDIR_ENCODED=$(encode_path "$CLAUDE_PROJECT_DIR")
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED"
# foreign session JSONL is NEWER (would have won the old JSONL-only path)
echo "{}" > "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED/foreign-session-id.jsonl"
touch -t 202601010000 "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED/foreign-session-id.jsonl"
OUT=$(run_with_timeout 60 node -e "
const m = require('$TARGET_NODE');
const r = m.resolveSessionId();
process.stdout.write(r === null ? '<null>' : String(r));
" 2>/dev/null)
if [ "$OUT" = "own-sid-js6" ]; then
    pass "JS-6: CLAUDE_CODE_SESSION_ID beats newer foreign JSONL (concurrent-session fix)"
else
    fail "JS-6: out='$OUT' expected='own-sid-js6'"
fi
teardown

# ===========================================================================
# JS-7: CLAUDE_CODE_SESSION_ID beats ctx.transcriptPath (priority check).
# Verifies CLAUDE_CODE_SESSION_ID is higher priority than transcriptPath fallback.
# ===========================================================================
setup
export CLAUDE_CODE_SESSION_ID="own-sid-js7"
OUT=$(run_with_timeout 60 node -e "
const m = require('$TARGET_NODE');
const r = m.resolveSessionId({ transcriptPath: '/some/path/transcript-other-sid.jsonl' });
process.stdout.write(r === null ? '<null>' : String(r));
" 2>/dev/null)
if [ "$OUT" = "own-sid-js7" ]; then
    pass "JS-7: CLAUDE_CODE_SESSION_ID beats ctx.transcriptPath (higher priority)"
else
    fail "JS-7: out='$OUT' expected='own-sid-js7'"
fi
teardown

# ===========================================================================
# JS-8: CLAUDE_CODE_SESSION_ID unset → JSONL fallback still works (no regression).
# Without CLAUDE_CODE_SESSION_ID, the legacy JSONL scan continues to work.
# ===========================================================================
setup
export CLAUDE_PROJECT_DIR="C:/git/test"
PROJDIR_ENCODED=$(encode_path "$CLAUDE_PROJECT_DIR")
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED"
echo "{}" > "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED/fallback-session-js8.jsonl"
# cd to $TMP so WORKTREE_NOTES.md in the worktree CWD cannot short-circuit the resolver.
OUT=$(cd "$TMP" && run_with_timeout 60 env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID node -e "
const m = require('$TARGET_NODE');
const r = m.resolveSessionId();
process.stdout.write(r === null ? '<null>' : String(r));
" 2>/dev/null)
if [ "$OUT" = "fallback-session-js8" ]; then
    pass "JS-8: CLAUDE_CODE_SESSION_ID unset → JSONL fallback still resolves (no regression)"
else
    fail "JS-8: out='$OUT' expected='fallback-session-js8'"
fi
teardown

# ===========================================================================
# JS-9: ctx.sessionIdFromInput still beats CLAUDE_CODE_SESSION_ID (priority 1 invariant).
# ===========================================================================
setup
export CLAUDE_CODE_SESSION_ID="code-sid-js9-should-lose"
OUT=$(run_with_timeout 60 node -e "
const m = require('$TARGET_NODE');
const r = m.resolveSessionId({ sessionIdFromInput: 'ctx-input-wins-js9' });
process.stdout.write(r === null ? '<null>' : String(r));
" 2>/dev/null)
if [ "$OUT" = "ctx-input-wins-js9" ]; then
    pass "JS-9: ctx.sessionIdFromInput beats CLAUDE_CODE_SESSION_ID (priority 1 invariant)"
else
    fail "JS-9: out='$OUT' expected='ctx-input-wins-js9'"
fi
teardown
