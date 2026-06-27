# JS-11, JS-12: Priority 7 cross-repo guard — must return null for foreign repos.

# ===========================================================================
# JS-11: foreign CWD only — guard must return null.
# CLAUDE_PROJECT_DIR is unset. CWD is a freshly-initialised foreign git repo
# (not related to the agents repo). A JSONL exists under the encoded foreign
# CWD in CLAUDE_TRANSCRIPT_BASE_DIR. Without the Priority 7 cross-repo guard
# the resolver returns the foreign sid; with the guard it returns null.
# RED until the cross-repo guard lands in write-code (#1099).
# ===========================================================================
FOREIGN_JS11=""
FOREIGN_JS11=$(mktemp -d)
git -C "$FOREIGN_JS11" init -q
setup
# Compute the encoding node produces from inside the foreign repo (Windows-safe).
ENC_JS11=$(cd "$FOREIGN_JS11" && node -e "const p=require('path');process.stdout.write(p.resolve(process.cwd()).toLowerCase().replace(/[^a-zA-Z0-9]/g,'-'))")
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENC_JS11"
echo '{}' > "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENC_JS11/foreign-sid-js11.jsonl"
# P1–P6 all miss: no CLAUDE_PROJECT_DIR; no ctx; no WORKTREE_NOTES.md in $FOREIGN_JS11.
OUT=$(cd "$FOREIGN_JS11" && run_with_timeout 60 env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID \
  CLAUDE_TRANSCRIPT_BASE_DIR="$CLAUDE_TRANSCRIPT_BASE_DIR" \
  node -e "
const m = require('$TARGET_NODE');
const r = m.resolveSessionId();
process.stdout.write(r === null ? '<null>' : String(r));
" 2>/dev/null)
if [ "$OUT" = "<null>" ]; then
    pass "JS-11: guard skips foreign-repo CWD candidate"
else
    fail "JS-11: out='$OUT' expected='<null>'"
fi
teardown
rm -rf "$FOREIGN_JS11" 2>/dev/null || true

# ===========================================================================
# JS-12: mixed candidates (agents CLAUDE_PROJECT_DIR + foreign CWD).
# Reproduces the C1 single-pre-guard defect: resolver falls through from an
# empty agents candidate to the foreign CWD JSONL and returns the foreign sid.
# With the per-candidate cross-repo guard both candidates are checked against
# their respective git common-dir; the foreign CWD is rejected → null.
# RED until the cross-repo guard lands in write-code (#1099).
# ===========================================================================
FOREIGN_JS12=""
FOREIGN_JS12=$(mktemp -d)
git -C "$FOREIGN_JS12" init -q
setup
# CLAUDE_PROJECT_DIR points at the agents worktree (same git repo as this script).
export CLAUDE_PROJECT_DIR="$AGENTS_DIR"
# Create the encoded agents-dir transcript dir but place NO JSONL there (empty scan).
AGENTS_ENC=$(node -e "const p=require('path');process.stdout.write(p.resolve('$AGENTS_DIR').toLowerCase().replace(/[^a-zA-Z0-9]/g,'-'))")
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR/$AGENTS_ENC"
# Foreign repo: put a JSONL so the scanner would find it if not guarded.
ENC_JS12=$(cd "$FOREIGN_JS12" && node -e "const p=require('path');process.stdout.write(p.resolve(process.cwd()).toLowerCase().replace(/[^a-zA-Z0-9]/g,'-'))")
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENC_JS12"
echo '{}' > "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENC_JS12/foreign-sid-js12.jsonl"
# Run from inside foreign repo with CLAUDE_PROJECT_DIR=agents (mixed candidates).
OUT=$(cd "$FOREIGN_JS12" && run_with_timeout 60 env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID \
  CLAUDE_PROJECT_DIR="$CLAUDE_PROJECT_DIR" \
  CLAUDE_TRANSCRIPT_BASE_DIR="$CLAUDE_TRANSCRIPT_BASE_DIR" \
  node -e "
const m = require('$TARGET_NODE');
const r = m.resolveSessionId();
process.stdout.write(r === null ? '<null>' : String(r));
" 2>/dev/null)
if [ "$OUT" = "<null>" ]; then
    pass "JS-12: per-candidate guard scans agents candidate (empty) then skips foreign cwd → null"
else
    fail "JS-12: out='$OUT' expected='<null>'"
fi
teardown
rm -rf "$FOREIGN_JS12" 2>/dev/null || true
