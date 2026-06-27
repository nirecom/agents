# JS-13, JS-14: Priority 7 positive paths — guard must ALLOW same-repo and linked-worktree.

# ===========================================================================
# JS-13: git-confirmed same-repo positive path — guard must ALLOW P7.
# Both AGENTS_CONFIG_DIR and CLAUDE_PROJECT_DIR point at the SAME freshly-
# initialised git repo, so isSameGitRepo resolves true via a real matching
# git-common-dir (NOT fail-open). A JSONL exists under the encoded path;
# resolveSessionId() must return "same-repo-sid-js13".
# GREEN before AND after the guard lands — load-bearing regression guard
# ensuring the cross-repo guard does not over-block same-repo P7 candidates.
# ===========================================================================
TROOT_JS13=""
TROOT_JS13=$(mktemp -d)
git -C "$TROOT_JS13" init -q
setup
export AGENTS_CONFIG_DIR="$TROOT_JS13"
export CLAUDE_PROJECT_DIR="$TROOT_JS13"
ENC_JS13=$(cd "$TROOT_JS13" && node -e "const p=require('path');process.stdout.write(p.resolve(process.cwd()).toLowerCase().replace(/[^a-zA-Z0-9]/g,'-'))")
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENC_JS13"
echo '{}' > "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENC_JS13/same-repo-sid-js13.jsonl"
OUT=$(cd "$TROOT_JS13" && run_with_timeout 60 env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID \
  AGENTS_CONFIG_DIR="$TROOT_JS13" \
  CLAUDE_PROJECT_DIR="$CLAUDE_PROJECT_DIR" \
  CLAUDE_TRANSCRIPT_BASE_DIR="$CLAUDE_TRANSCRIPT_BASE_DIR" \
  node -e "
const m = require('$TARGET_NODE');
const r = m.resolveSessionId();
process.stdout.write(r === null ? '<null>' : String(r));
" 2>/dev/null)
if [ "$OUT" = "same-repo-sid-js13" ]; then
    pass "JS-13: guard allows git-confirmed same-repo CWD candidate (positive path)"
else
    fail "JS-13: out='$OUT' expected='same-repo-sid-js13'"
fi
teardown
rm -rf "$TROOT_JS13" 2>/dev/null || true

# ===========================================================================
# JS-14: linked-worktree same-repo positive path — guard must ALLOW P7.
# Primary production scenario for #1099: ENFORCE_WORKTREE=on means the active
# Claude Code session runs from a LINKED WORKTREE of the agents repo. A linked
# worktree's `git rev-parse --git-common-dir` resolves to the MAIN repo's .git
# (the shared common dir), so the linked worktree and the main worktree of the
# same repo have an identical common-dir → isSameGitRepo must return true and
# the guard MUST allow P7 to scan the candidate.
# GREEN before AND after the guard lands — load-bearing regression guard
# ensuring the cross-repo guard does not wrongly reject linked-worktree paths.
# ===========================================================================
TROOT_JS14=""
TROOT_JS14=$(mktemp -d)
git -C "$TROOT_JS14" init -q
git -C "$TROOT_JS14" -c user.email=test@example.com -c user.name=test commit --allow-empty -qm init
WTPARENT_JS14=$(mktemp -d)
WTPATH_JS14="$WTPARENT_JS14/linked-wt"
git -C "$TROOT_JS14" worktree add -q "$WTPATH_JS14" -b js14-branch
setup
export AGENTS_CONFIG_DIR="$TROOT_JS14"
export CLAUDE_PROJECT_DIR="$WTPATH_JS14"
ENC_JS14=$(cd "$WTPATH_JS14" && node -e "const p=require('path');process.stdout.write(p.resolve(process.cwd()).toLowerCase().replace(/[^a-zA-Z0-9]/g,'-'))")
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENC_JS14"
echo '{}' > "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENC_JS14/linked-wt-sid-js14.jsonl"
OUT=$(cd "$WTPATH_JS14" && run_with_timeout 60 env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID \
  AGENTS_CONFIG_DIR="$TROOT_JS14" \
  CLAUDE_PROJECT_DIR="$CLAUDE_PROJECT_DIR" \
  CLAUDE_TRANSCRIPT_BASE_DIR="$CLAUDE_TRANSCRIPT_BASE_DIR" \
  node -e "
const m = require('$TARGET_NODE');
const r = m.resolveSessionId();
process.stdout.write(r === null ? '<null>' : String(r));
" 2>/dev/null)
if [ "$OUT" = "linked-wt-sid-js14" ]; then
    pass "JS-14: guard allows linked-worktree candidate of the same repo (common-dir match)"
else
    fail "JS-14: out='$OUT' expected='linked-wt-sid-js14'"
fi
git -C "$TROOT_JS14" worktree remove --force "$WTPATH_JS14" 2>/dev/null || true
teardown
rm -rf "$TROOT_JS14" "$WTPARENT_JS14" 2>/dev/null || true
