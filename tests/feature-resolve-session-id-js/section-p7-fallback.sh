# JS-17: AGENTS_CONFIG_DIR unset → __dirname fallback anchor still rejects foreign-repo CWD.

# ===========================================================================
# JS-17: AGENTS_CONFIG_DIR unset → __dirname fallback anchor still rejects
# foreign-repo CWD.
# Exercises the `|| path.resolve(__dirname,"..","..","..")` fallback anchor
# branch (AGENTS_CONFIG_DIR unset — the common production path). A wrong `..`
# count would overshoot the repo → getGitCommonDir returns null → fail-open →
# the foreign CWD candidate would be wrongly allowed and its sid returned
# instead of null. This test catches that regression.
# RED until the cross-repo guard lands in write-code (#1099).
# ===========================================================================
FOREIGN_JS17=""
FOREIGN_JS17=$(mktemp -d)
git -C "$FOREIGN_JS17" init -q
setup
# Compute the encoding from inside the foreign repo (cwd-based, exactly like JS-11).
ENC_JS17=$(cd "$FOREIGN_JS17" && node -e "const p=require('path');process.stdout.write(p.resolve(process.cwd()).toLowerCase().replace(/[^a-zA-Z0-9]/g,'-'))")
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENC_JS17"
echo '{}' > "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENC_JS17/foreign-sid-js17.jsonl"
# Key difference vs JS-11: AGENTS_CONFIG_DIR is explicitly unset (-u AGENTS_CONFIG_DIR)
# so the resolver must fall back to path.resolve(__dirname,"..","..","..")
# (the __dirname anchor inside hooks/lib/workflow-state/session-id.js).
OUT=$(cd "$FOREIGN_JS17" && run_with_timeout 60 env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID -u AGENTS_CONFIG_DIR \
  CLAUDE_TRANSCRIPT_BASE_DIR="$CLAUDE_TRANSCRIPT_BASE_DIR" \
  node -e "
const m = require('$TARGET_NODE');
const r = m.resolveSessionId();
process.stdout.write(r === null ? '<null>' : String(r));
" 2>/dev/null)
if [ "$OUT" = "<null>" ]; then
    pass "JS-17: AGENTS_CONFIG_DIR unset → __dirname fallback anchor still rejects foreign-repo CWD"
else
    fail "JS-17: out='$OUT' expected='<null>'"
fi
teardown
rm -rf "$FOREIGN_JS17" 2>/dev/null || true
