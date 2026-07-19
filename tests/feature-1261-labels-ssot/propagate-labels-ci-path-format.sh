#!/bin/bash
# tests/feature-1261-labels-ssot/propagate-labels-ci-path-format.sh
# Tests: bin/github-issues/propagate-labels.sh
# Tags: labels-ssot, propagation, github-issues, scope:issue-specific
#
# Path-format-specific tests for semicolon-separated absolute-path PROPAGATE_LABELS_REPOS.
# T-propagate-new-1: whitespace trimming, T-propagate-new-2: no-remote failure,
# T-propagate-new-3: SSH URL parsing, T-propagate-new-4: trailing-semicolon skip.
#
# L3 gap: same as propagate-labels-ci.sh — mock git/gh intercepts all calls.

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

TARGET="${PROPAGATE_LABELS_SH:-$AGENTS_DIR/bin/github-issues/propagate-labels.sh}"

TMP=""

setup_mock() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/mock-bin" "$TMP/workdir" "$TMP/agents-workspace/.github"
    mkdir -p "$TMP/repos/myorg/myrepo"
    mkdir -p "$TMP/repos/nirecom/dotfiles"
    mkdir -p "$TMP/repos/sshorg/ssh-test-repo"
    mkdir -p "$TMP/repos/no-remote/repo"
    mkdir -p "$TMP/repos/badurl/repo"

    cat > "$TMP/agents-workspace/.github/labels.yml" <<'LABELS_EOF'
- name: "type:task"
  color: "0e8a16"
  description: "Normal task"
LABELS_EOF

    cat > "$TMP/mock-bin/git" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
[ -n "${MOCK_LOG:-}" ] && printf '%s\n' "git $ARGS" >> "$MOCK_LOG"
case "$1" in
  clone)
    DEST="${!#}"
    mkdir -p "$DEST/.github"
    echo "# old seeded content" > "$DEST/.github/labels.yml"
    exit 0 ;;
  config) exit 0 ;;
  -C)
    _GIT_DIR="$2"; shift 2
    case "$1" in
      config) exit 0 ;;
      diff) exit "${GIT_DIFF_RC:-0}" ;;
      add) exit 0 ;;
      commit) exit 0 ;;
      push) exit 0 ;;
      remote)
        if [ "${2:-}" = "get-url" ]; then
            case "$_GIT_DIR" in
              *no-remote*) exit 1 ;;
              *badurl*)
                printf 'https://github.com/notarepo\n'; exit 0 ;;
              *ssh-test-repo*)
                printf 'git@github.com:sshorg/ssh-test-repo.git\n'; exit 0 ;;
              *dotfiles)
                printf 'https://github.com/nirecom/dotfiles.git\n'; exit 0 ;;
              *)
                _REPO_NAME="$(basename "$_GIT_DIR")"
                _OWNER_NAME="$(basename "$(dirname "$_GIT_DIR")")"
                printf 'https://github.com/%s/%s.git\n' "$_OWNER_NAME" "$_REPO_NAME"
                exit 0 ;;
            esac
        fi
        exit 0 ;;
      *) exit 0 ;;
    esac ;;
  diff) exit "${GIT_DIFF_RC:-0}" ;;
  add) exit 0 ;;
  commit) exit 0 ;;
  push) exit 0 ;;
  *) exit 0 ;;
esac
MOCK_EOF
    chmod +x "$TMP/mock-bin/git"

    cat > "$TMP/mock-bin/gh" <<'MOCK_EOF'
#!/bin/bash
[ -n "${MOCK_LOG:-}" ] && printf '%s\n' "gh $*" >> "$MOCK_LOG"
exit 0
MOCK_EOF
    chmod +x "$TMP/mock-bin/gh"

    export PATH="$TMP/mock-bin:$PATH"
    export MOCK_LOG="$TMP/mock.log"
    : > "$MOCK_LOG"
}

teardown_mock() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP" 2>/dev/null || true
    fi
    TMP=""
    unset MOCK_LOG GIT_DIFF_RC PROPAGATE_LABELS_PAT CANONICAL_LABELS_FILE \
          PROPAGATE_LABELS_REPOS AGENTS_WORKSPACE GIT_WORK_DIR 2>/dev/null || true
}

# ===========================================================================
# T-propagate-new-1: whitespace trimming around semicolons
# Both entries should be processed (two clone invocations).
# ===========================================================================
setup_mock
export PROPAGATE_LABELS_PAT="test-secret-pat-12345"
export GIT_DIFF_RC=0
export AGENTS_WORKSPACE="$AGENTS_DIR"
export GIT_WORK_DIR="$TMP/workdir"
export CANONICAL_LABELS_FILE="$TMP/agents-workspace/.github/labels.yml"
export PROPAGATE_LABELS_REPOS=" $TMP/repos/myorg/myrepo ; $TMP/repos/nirecom/dotfiles "
run_with_timeout 60 bash "$TARGET" >/dev/null 2>&1
RC=$?
CLONE_COUNT="$(grep -c "git clone" "$MOCK_LOG" 2>/dev/null || echo 0)"
if [ "$RC" = "0" ] && [ "$CLONE_COUNT" -ge 2 ]; then
    pass "T-propagate-new-1: whitespace trimming around semicolons → both entries processed"
else
    fail "T-propagate-new-1: rc=$RC clone_count=$CLONE_COUNT log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-propagate-new-2: path with no git remote → entry skipped, exit code 1
# ===========================================================================
setup_mock
export PROPAGATE_LABELS_PAT="test-secret-pat-12345"
export GIT_DIFF_RC=0
export AGENTS_WORKSPACE="$TMP/agents-workspace"
export GIT_WORK_DIR="$TMP/workdir"
export CANONICAL_LABELS_FILE="$TMP/agents-workspace/.github/labels.yml"
export PROPAGATE_LABELS_REPOS="$TMP/repos/no-remote/repo"
run_with_timeout 30 bash "$TARGET" >/dev/null 2>&1
RC=$?
CLONE_CALLED=0
grep -q "git clone" "$MOCK_LOG" 2>/dev/null && CLONE_CALLED=1
if [ "$RC" != "0" ] && [ "$CLONE_CALLED" = "0" ]; then
    pass "T-propagate-new-2: no-remote path → remote get-url fails → skip + exit 1"
else
    fail "T-propagate-new-2: rc=$RC clone_called=$CLONE_CALLED log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-propagate-new-3: SSH remote URL format → resolved owner/repo used in clone
# ===========================================================================
setup_mock
export PROPAGATE_LABELS_PAT="test-secret-pat-12345"
export GIT_DIFF_RC=0
export AGENTS_WORKSPACE="$TMP/agents-workspace"
export GIT_WORK_DIR="$TMP/workdir"
export CANONICAL_LABELS_FILE="$TMP/agents-workspace/.github/labels.yml"
export PROPAGATE_LABELS_REPOS="$TMP/repos/sshorg/ssh-test-repo"
run_with_timeout 30 bash "$TARGET" >/dev/null 2>&1
RC=$?
SSH_REPO_CLONED=0
grep "git clone" "$MOCK_LOG" 2>/dev/null | grep -q "sshorg/ssh-test-repo" && SSH_REPO_CLONED=1
if [ "$SSH_REPO_CLONED" = "1" ]; then
    pass "T-propagate-new-3: SSH remote URL parsed → sshorg/ssh-test-repo used in clone"
else
    fail "T-propagate-new-3: rc=$RC ssh_repo_cloned=$SSH_REPO_CLONED log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-propagate-new-4: trailing semicolon (empty entry skip)
# Only one clone should be invoked; script must exit 0.
# ===========================================================================
setup_mock
export PROPAGATE_LABELS_PAT="test-secret-pat-12345"
export GIT_DIFF_RC=0
export AGENTS_WORKSPACE="$AGENTS_DIR"
export GIT_WORK_DIR="$TMP/workdir"
export CANONICAL_LABELS_FILE="$TMP/agents-workspace/.github/labels.yml"
export PROPAGATE_LABELS_REPOS="$TMP/repos/myorg/myrepo;"
run_with_timeout 30 bash "$TARGET" >/dev/null 2>&1
RC=$?
CLONE_COUNT="$(grep -c "git clone" "$MOCK_LOG" 2>/dev/null || echo 0)"
if [ "$RC" = "0" ] && [ "$CLONE_COUNT" = "1" ]; then
    pass "T-propagate-new-4: trailing semicolon → empty entry skipped, one clone, exit 0"
else
    fail "T-propagate-new-4: rc=$RC clone_count=$CLONE_COUNT log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-propagate-new-5: malformed URL resolution → validation guard fires, exit 1
# remote get-url returns https://github.com/notarepo (no owner/ prefix),
# sed strips to "notarepo" (no slash) → [[ =~ ]] guard at line 61 fires.
# Expect: exit code non-zero, git clone NOT called.
# ===========================================================================
setup_mock
export PROPAGATE_LABELS_PAT="test-secret-pat-12345"
export GIT_DIFF_RC=0
export AGENTS_WORKSPACE="$TMP/agents-workspace"
export GIT_WORK_DIR="$TMP/workdir"
export CANONICAL_LABELS_FILE="$TMP/agents-workspace/.github/labels.yml"
export PROPAGATE_LABELS_REPOS="$TMP/repos/badurl/repo"
run_with_timeout 30 bash "$TARGET" >/dev/null 2>&1
RC=$?
CLONE_CALLED=0
grep -q "git clone" "$MOCK_LOG" 2>/dev/null && CLONE_CALLED=1
if [ "$RC" != "0" ] && [ "$CLONE_CALLED" = "0" ]; then
    pass "T-propagate-new-5: malformed URL resolution → validation guard fires, exit 1, no clone"
else
    fail "T-propagate-new-5: rc=$RC clone_called=$CLONE_CALLED log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-propagate-ci-path-1: existing path → resolved via git remote get-url (no fallback)
# AGENTS_WORKSPACE not consulted when path exists; clone uses owner from remote URL.
# ===========================================================================
setup_mock
mkdir -p "$TMP/repos/testorg/agents"
export AGENTS_WORKSPACE="$TMP/repos/testorg/agents"
export PROPAGATE_LABELS_REPOS="$TMP/repos/myorg/myrepo"
export PROPAGATE_LABELS_PAT="test-pat-path1"
export GIT_WORK_DIR="$TMP/workdir"
export CANONICAL_LABELS_FILE="$TMP/agents-workspace/.github/labels.yml"
run_with_timeout 30 bash "$TARGET" >/dev/null 2>&1
RC=$?
CLONE_HAS_REPO=0
grep "git clone" "$MOCK_LOG" 2>/dev/null | grep -q "myorg/myrepo" && CLONE_HAS_REPO=1
AGENTS_WS_CONSULTED=0
grep -q "\-C $TMP/repos/testorg/agents remote get-url" "$MOCK_LOG" 2>/dev/null && AGENTS_WS_CONSULTED=1
teardown_mock
if [ "$CLONE_HAS_REPO" = "1" ] && [ "$AGENTS_WS_CONSULTED" = "0" ]; then
    pass "T-propagate-ci-path-1: existing path resolved via git remote get-url, AGENTS_WORKSPACE not consulted"
else
    fail "T-propagate-ci-path-1: clone_has_repo=$CLONE_HAS_REPO agents_ws_consulted=$AGENTS_WS_CONSULTED"
fi

# ===========================================================================
# T-propagate-ci-path-2: non-existent path + AGENTS_WORKSPACE owner-lookup fails → exit 1, no clone
# mock *no-remote* branch exits 1 for remote get-url; fallback owner lookup also fails.
# Path uses "no-remote" segment so the mock exits 1 for the path-based lookup too.
# ===========================================================================
setup_mock
mkdir -p "$TMP/repos/no-remote/agents"
export AGENTS_WORKSPACE="$TMP/repos/no-remote/agents"
export PROPAGATE_LABELS_REPOS="/nonexistent/no-remote/myrepo"
export PROPAGATE_LABELS_PAT="test-pat-path2"
export GIT_WORK_DIR="$TMP/workdir"
export CANONICAL_LABELS_FILE="$TMP/agents-workspace/.github/labels.yml"
run_with_timeout 30 bash "$TARGET" >/dev/null 2>&1
RC=$?
CLONE_CALLED=0
grep -q "git clone" "$MOCK_LOG" 2>/dev/null && CLONE_CALLED=1
teardown_mock
if [ "$RC" != "0" ] && [ "$CLONE_CALLED" = "0" ]; then
    pass "T-propagate-ci-path-2: owner-lookup fails → exit 1, no clone"
else
    fail "T-propagate-ci-path-2: rc=$RC clone_called=$CLONE_CALLED"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
