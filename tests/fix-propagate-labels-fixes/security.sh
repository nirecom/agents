# Security and validation tests for propagate-labels.sh.
# Sourced by tests/fix-propagate-labels-fixes.sh — not run standalone.

# ===========================================================================
# T-propagate-pat-not-in-output (#security): PAT value must not appear in any
# logged output or written files. The script's stated invariant:
# "The PAT appears only in the clone URL — it is never echoed to stdout
#  nor written into any labels.yml body."
# ===========================================================================
setup_common_mock
export PROPAGATE_LABELS_PAT="super-secret-test-PAT-xyz"
mkdir -p "$TMP/sibling-repo"
touch "$TMP/sibling-repo/.is-git-repo"
export PROPAGATE_LABELS_REPOS="$TMP/sibling-repo"
COMBINED_OUT="$TMP/combined-output.txt"
run_with_timeout 60 bash "$TARGET" > "$COMBINED_OUT" 2>&1 || true
PAT_IN_OUTPUT=0
grep -qF "super-secret-test-PAT-xyz" "$COMBINED_OUT" 2>/dev/null && PAT_IN_OUTPUT=1
# Check any labels.yml written into workdir clone destinations (body must not contain PAT)
PAT_IN_YML=0
grep -rqF "super-secret-test-PAT-xyz" "$TMP/workdir" 2>/dev/null && PAT_IN_YML=1
# Note: MOCK_LOG records mock invocations including clone URL args — that is test
# infrastructure, not script output. The invariant covers stdout/stderr and file bodies only.
if [ "$PAT_IN_OUTPUT" = "0" ] && [ "$PAT_IN_YML" = "0" ]; then
    pass "T-propagate-pat-not-in-output: PAT absent from script stdout/stderr and written labels.yml"
else
    fail "T-propagate-pat-not-in-output: PAT leaked (stdout_stderr=$PAT_IN_OUTPUT labels_yml=$PAT_IN_YML)"
fi
teardown_common_mock

# ===========================================================================
# T-propagate-path-traversal-guard (F2 security guard): CANONICAL_LABELS_FILE
# with ".." must exit 1 with stderr containing "path traversal".
# The F2 guard lives at propagate-labels.sh lines 32-37.
# PAT must be set (PAT check is before F2 check).
# ===========================================================================
setup_common_mock
export PROPAGATE_LABELS_PAT="test-pat"
export CANONICAL_LABELS_FILE="../../etc/passwd"
export PROPAGATE_LABELS_REPOS="$TMP/sibling-repo"
TRAVERSAL_STDERR="$TMP/traversal-stderr.txt"
run_with_timeout 60 bash "$TARGET" >/dev/null 2>"$TRAVERSAL_STDERR"
RC=$?
STDERR_HAS_MSG=0
grep -qi "path traversal" "$TRAVERSAL_STDERR" 2>/dev/null && STDERR_HAS_MSG=1
if [ "$RC" = "1" ] && [ "$STDERR_HAS_MSG" = "1" ]; then
    pass "T-propagate-path-traversal-guard: exits 1 with 'path traversal' in stderr"
else
    fail "T-propagate-path-traversal-guard: rc=$RC stderr_msg=$STDERR_HAS_MSG (expected rc=1, msg=1)"
fi
teardown_common_mock

# ===========================================================================
# T-propagate-sibling-invalid-format: git remote returns an invalid URL that
# does not match the expected github.com pattern. Assert: exit code 1 and no
# "gh label list" invocation (skip is recorded but processing does not continue).
# Tests the SIBLING regex guard at propagate-labels.sh line 100.
# ===========================================================================
setup_common_mock
export PROPAGATE_LABELS_PAT="test-secret-pat-12345"
# Create a custom git mock that returns an invalid URL for remote get-url origin.
cat > "$TMP/mock-bin/git" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
[ -n "${MOCK_LOG:-}" ] && printf '%s\n' "git $ARGS" >> "$MOCK_LOG"
case "$1" in
  clone)
    DEST="${!#}"
    mkdir -p "$DEST/.github"
    echo "# old seeded content" > "$DEST/.github/labels.yml"
    exit 0
    ;;
  config) exit 0 ;;
  -C)
    _GIT_DIR="$2"; shift 2
    case "$1" in
      remote)
        if [ "${2:-}" = "get-url" ]; then
          printf 'not-a-valid-github-url\n'
        fi
        exit 0
        ;;
      rev-parse)
        if [ -e "$_GIT_DIR/.is-git-repo" ]; then exit 0; else exit 1; fi
        ;;
      config) exit 0 ;;
      diff) exit "${GIT_DIFF_RC:-0}" ;;
      add) exit 0 ;;
      commit) exit 0 ;;
      push) exit 0 ;;
      *) exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac
MOCK_EOF
chmod +x "$TMP/mock-bin/git"
mkdir -p "$TMP/sibling-repo"
touch "$TMP/sibling-repo/.is-git-repo"
export PROPAGATE_LABELS_REPOS="$TMP/sibling-repo"
run_with_timeout 60 bash "$TARGET" >/dev/null 2>&1
RC=$?
LIST_COUNT=$(grep -c "gh label list" "$MOCK_LOG" 2>/dev/null; true)
if [ "$RC" = "1" ] && [ "$LIST_COUNT" = "0" ]; then
    pass "T-propagate-sibling-invalid-format: invalid URL causes exit 1, no label list invocation"
else
    fail "T-propagate-sibling-invalid-format: rc=$RC list_count=$LIST_COUNT (expected rc=1 count=0)"
fi
teardown_common_mock

# ===========================================================================
# T-propagate-semicolon-multi-repo: semicolon-separated PROPAGATE_LABELS_REPOS
# with 2 directory paths → 2 "gh label list" invocations. Tests the
# semicolon-split path (tr ';' '\n') at propagate-labels.sh line 158.
# ===========================================================================
setup_common_mock
export PROPAGATE_LABELS_PAT="test-secret-pat-12345"
mkdir -p "$TMP/repo-a" "$TMP/repo-b"
touch "$TMP/repo-a/.is-git-repo" "$TMP/repo-b/.is-git-repo"
export PROPAGATE_LABELS_REPOS="$TMP/repo-a;$TMP/repo-b"
run_with_timeout 60 bash "$TARGET" >/dev/null 2>&1
LIST_COUNT=$(grep -c "gh label list" "$MOCK_LOG" 2>/dev/null || echo 0)
if [ "$LIST_COUNT" = "2" ]; then
    pass "T-propagate-semicolon-multi-repo: semicolon-separated repos both synced (count=$LIST_COUNT)"
else
    fail "T-propagate-semicolon-multi-repo: expected 2 gh label list calls, got $LIST_COUNT (log=$(cat "$MOCK_LOG" 2>/dev/null))"
fi
teardown_common_mock

# ===========================================================================
# T-propagate-clone-fail-continues: git clone fails for one repo but not the
# other. Assert: (a) overall exit code is 1, (b) the successful repo still
# got "gh label list" (processing continued). Tests per-repo failure isolation
# (subshell rc check at propagate-labels.sh lines 153-156).
# The clone mock fails when the DEST path contains "repo-a" in its basename.
# ===========================================================================
setup_common_mock
export PROPAGATE_LABELS_PAT="test-secret-pat-12345"
cat > "$TMP/mock-bin/git" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
[ -n "${MOCK_LOG:-}" ] && printf '%s\n' "git $ARGS" >> "$MOCK_LOG"
case "$1" in
  clone)
    DEST="${!#}"
    # Fail clone when destination slug contains "repo-a"
    case "$DEST" in
      *repo-a*)
        printf 'clone failed for repo-a (mock)\n' >&2
        exit 1
        ;;
    esac
    mkdir -p "$DEST/.github"
    echo "# old seeded content" > "$DEST/.github/labels.yml"
    exit 0
    ;;
  config) exit 0 ;;
  -C)
    _GIT_DIR="$2"; shift 2
    case "$1" in
      remote)
        if [ "${2:-}" = "get-url" ]; then
          _REPO_NAME="$(basename "$_GIT_DIR")"
          _OWNER_NAME="$(basename "$(dirname "$_GIT_DIR")")"
          printf 'https://github.com/%s/%s.git\n' "$_OWNER_NAME" "$_REPO_NAME"
        fi
        exit 0
        ;;
      rev-parse)
        if [ -e "$_GIT_DIR/.is-git-repo" ]; then exit 0; else exit 1; fi
        ;;
      config) exit 0 ;;
      diff) exit "${GIT_DIFF_RC:-0}" ;;
      add) exit 0 ;;
      commit) exit 0 ;;
      push) exit 0 ;;
      *) exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac
MOCK_EOF
chmod +x "$TMP/mock-bin/git"
mkdir -p "$TMP/repo-a" "$TMP/repo-b"
touch "$TMP/repo-a/.is-git-repo" "$TMP/repo-b/.is-git-repo"
export PROPAGATE_LABELS_REPOS="$TMP/repo-a;$TMP/repo-b"
run_with_timeout 60 bash "$TARGET" >/dev/null 2>&1
RC=$?
LIST_COUNT=$(grep -c "gh label list" "$MOCK_LOG" 2>/dev/null || echo 0)
if [ "$RC" = "1" ] && [ "$LIST_COUNT" = "1" ]; then
    pass "T-propagate-clone-fail-continues: clone failure recorded (rc=1), other repo still synced (count=$LIST_COUNT)"
else
    fail "T-propagate-clone-fail-continues: rc=$RC list_count=$LIST_COUNT (expected rc=1 count=1, log=$(cat "$MOCK_LOG" 2>/dev/null))"
fi
teardown_common_mock
