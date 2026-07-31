#!/bin/bash
# Tests: bin/session-sync.sh, install/linux/session-sync-init.sh, bin/workflow-plans-dir
# Tags: bin, install, git, session-sync, scope:common
# Tests for bin/session-sync.sh and install/linux/session-sync-init.sh
# Run: bash tests/main-session-sync.sh
#
# Layout: this file is the dispatcher. It owns the shared fixtures, helpers and
# the result footer; the cases live in tests/main-session-sync/*.sh and are
# sourced below in order. Split because the single file exceeded the 500-line
# HARD limit enforced by bin/review-code-size.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOTFILES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PARTS_DIR="$SCRIPT_DIR/main-session-sync"
PASS=0
FAIL=0
PEND=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
# pending: the case cannot be decided in this environment (missing platform
# capability or unimplemented production support). Never counts as a failure —
# always carries the reason so it can be audited.
pending() { PEND=$((PEND + 1)); echo "  PENDING: $1"; }

# Create isolated temp environment
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ---------------------------------------------------------------------------
# Suite-wide environment fixtures (#1564)
#
# Root cause of the hang: bin/session-sync.sh resolves its plans source through
# bin/workflow-plans-dir, which falls back to the *developer's real*
# ~/.workflow-plans when WORKFLOW_PLANS_DIR is unset. Every push/pull/reset case
# therefore copied and committed the whole real plans directory into a fixture
# repo — hundreds of files, CRLF renormalization on Windows — until the suite
# timed out. Pinning the variable once here (rather than at each call site) is
# the class-level fix: any case added later inherits the isolation for free.
# ---------------------------------------------------------------------------
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/workflow-plans"
mkdir -p "$WORKFLOW_PLANS_DIR"
# bin/session-sync.sh locates bin/workflow-plans-dir relative to AGENTS_CONFIG_DIR.
# Pin it to this checkout so the resolver under test is this one, not whichever
# agents config the developer happens to have installed.
export AGENTS_CONFIG_DIR="$DOTFILES_DIR"

# ---------------------------------------------------------------------------
# Deterministic git environment.
#
# The developer machine may set core.hooksPath globally (this repo's own hooks
# do exactly that), which makes `git commit` inside a throwaway fixture repo run
# the agents pre-commit hook and abort. It may also lack a user identity in CI,
# or default to `master`. Replacing the global/system config with a minimal file
# removes all three variables at once, and repo-local config still works — so
# the "init sets core.hooksPath" assertion keeps testing the real thing.
# ---------------------------------------------------------------------------
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$TMPDIR_BASE/gitconfig"
cat > "$GIT_CONFIG_GLOBAL" <<'GITCONFIG'
[user]
	name = Session Sync Test
	email = session-sync-test@example.com
[init]
	defaultBranch = main
[commit]
	gpgSign = false
[advice]
	detachedHead = false
GITCONFIG

# _git_prepare_repo <dir> — make a freshly created/cloned fixture repo safe to
# commit in, independent of machine config. Repo-local so it still holds if the
# global-config isolation above is ever narrowed.
_git_prepare_repo() {
    local dir="$1"
    git -C "$dir" config user.email "session-sync-test@example.com" 2>/dev/null || true
    git -C "$dir" config user.name "Session Sync Test" 2>/dev/null || true
    git -C "$dir" config core.hooksPath /dev/null 2>/dev/null || true
    git -C "$dir" config commit.gpgSign false 2>/dev/null || true
}

# Helper: configure git user in a repo dir (kept for the conflict cases).
_git_config_user() {
    local dir="$1"
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "Test User"
}

# _norm_path <path> — normalize to the path form git echoes back. On Windows the
# shell hands git an MSYS path (/tmp/...) but git stores the native form
# (C:/Users/...); comparing the raw strings would fail for reasons unrelated to
# the behavior under test.
_norm_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1" 2>/dev/null || printf '%s' "$1"
    else
        printf '%s' "$1"
    fi
}

# _mtime_of <file> — epoch mtime, GNU stat then BSD stat, 0 when unavailable.
_mtime_of() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo "0"
}

FAKE_HOME="$TMPDIR_BASE/home"
FAKE_CLAUDE="$FAKE_HOME/.claude"
FAKE_PROJECTS="$FAKE_CLAUDE/projects"
mkdir -p "$FAKE_HOME"

# Create a bare remote repo to simulate github
FAKE_REMOTE="$TMPDIR_BASE/remote.git"
git init --bare "$FAKE_REMOTE" >/dev/null 2>&1

# shellcheck source=tests/main-session-sync/init.sh
. "$PARTS_DIR/init.sh"
# shellcheck source=tests/main-session-sync/sync-basic.sh
. "$PARTS_DIR/sync-basic.sh"
# shellcheck source=tests/main-session-sync/reset.sh
. "$PARTS_DIR/reset.sh"
# shellcheck source=tests/main-session-sync/output-retry.sh
. "$PARTS_DIR/output-retry.sh"
# shellcheck source=tests/main-session-sync/conflict.sh
. "$PARTS_DIR/conflict.sh"
# shellcheck source=tests/main-session-sync/plans.sh
. "$PARTS_DIR/plans.sh"
# shellcheck source=tests/main-session-sync/session-sync-independence.sh
. "$PARTS_DIR/session-sync-independence.sh"

echo ""
echo "=== Results ==="
echo "PASS: $PASS  FAIL: $FAIL  PENDING: $PEND"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
