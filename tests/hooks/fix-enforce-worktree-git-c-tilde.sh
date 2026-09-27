#!/usr/bin/env bash
# tests/hooks/fix-enforce-worktree-git-c-tilde.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/git-repo-detection.js
# Tags: TL1, hook, enforce, worktree, git-c, tilde, scope:common
# #1563 (via #2393): resolveScopeValue treats a `~`-prefixed -C value as
# AMBIGUOUS, falls back to the CWD repo (main) and BLOCKs a write aimed at an
# external repo under $HOME. E1 is RED until `~` is statically expanded; `$VAR`
# and relative paths must stay AMBIGUOUS (E3/E4), and a `~` that expands INTO
# the session repo must still BLOCK (E5).

set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"
# shellcheck source=tests/lib/ew-runner.sh
. "$AGENTS_DIR/tests/lib/ew-runner.sh"

T="$(make_tmp)"
trap 'rm -rf "$T"' EXIT
harness_isolate "$T/iso"

# os.homedir() reads USERPROFILE on Windows and HOME on POSIX — pin both.
FAKE_HOME="$(np "$T/home")"
MAIN="$FAKE_HOME/main"
EXT_STATE="$FAKE_HOME/.claude/projects"
EXT_ABS="$(np "$T/ext-abs")"
ew_make_repo "$MAIN"
ew_make_repo "$EXT_STATE"
ew_make_repo "$EXT_ABS"
mkdir -p "$EXT_STATE/plans"
EW_CONFIG_DIR="$MAIN"

run() { ew_run "$MAIN" "$(ew_bash_payload test "$1")" "HOME=$FAKE_HOME" "USERPROFILE=$FAKE_HOME"; }

case_begin "git-c-tilde-expansion" "hooks/enforce-worktree/git-repo-detection.js"
ew_expect allow "E1. main CWD: git -C ~/.claude/projects rm plans/*.json → ALLOW (external repo)" \
    "$(run 'git -C ~/.claude/projects rm plans/*.json')"
ew_expect allow "E1b. main CWD: git -C ~/.claude/projects commit -m x → ALLOW (external repo)" \
    "$(run 'git -C ~/.claude/projects commit -m x')"
ew_expect block "E5. main CWD: git -C ~/main commit -m x → BLOCK (tilde expands into session repo)" \
    "$(run 'git -C ~/main commit -m x')"
case_end

case_begin "git-c-scope-boundaries" "hooks/enforce-worktree.js"
# E2 is RED pre-fix, contrary to the plan's [external-repo-already-allowed]: the
# absolute -C joins getSessionRepoRoots() as a payload-derived root and is judged
# as a session main checkout — same failure as main-enforce-worktree-guard.sh
# "Bug 2: Bash git -C non-session commit". E1 shares this path after expansion.
ew_expect allow "E2. main CWD: git -C <abs-external> commit -m x → ALLOW (pre-existing RED, shared with Bug 2)" \
    "$(run "git -C \"$EXT_ABS\" commit -m x")"
ew_expect block "E3. main CWD: git -C \$HOME/.claude/projects commit → BLOCK (env var stays AMBIGUOUS)" \
    "$(run 'git -C $HOME/.claude/projects commit -m x')"
ew_expect block "E4. main CWD: git -C ./relative commit → BLOCK (relative stays AMBIGUOUS)" \
    "$(run 'git -C ./relative commit -m x')"
case_end

echo ""
echo "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[[ "$FAIL" -eq 0 ]]
