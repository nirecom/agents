#!/bin/bash
# tests/feature-1261-labels-ssot/propagate-labels-ci.sh
# Tests: bin/github-issues/propagate-labels.sh
# Tags: labels-ssot, propagation, github-issues, scope:issue-specific
#
# L3 gap (what this test does NOT catch):
# - Real GitHub API calls and PAT authentication not covered — mock git/gh
#   intercepts all network calls; no actual HTTPS connection is made.
# - Branch-protection push rejection not simulated — mock git push always
#   succeeds; a real protected branch would reject the push.
# - Real `git diff` computation not exercised — mock reads GIT_DIFF_RC env
#   knob; actual byte-level diff of labels.yml is not evaluated.
# - Real sync-labels.sh against live gh API not covered by most cases —
#   T-propagate-6 exercises the real sync-labels.sh against mock gh only.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# pass / fail / assert_eq / AGENTS_DIR / run_with_timeout provided by _lib.sh.

# Allow overriding the script path so tests can validate against a throwaway
# reference implementation before the real bin path exists.
TARGET="${PROPAGATE_LABELS_SH:-$AGENTS_DIR/bin/github-issues/propagate-labels.sh}"

GENERATED_HEADER="# GENERATED — source: nirecom/agents .github/labels.yml — do not edit directly"

TMP=""

setup_mock() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/mock-bin"
    mkdir -p "$TMP/workdir"
    mkdir -p "$TMP/agents-workspace/.github"

    # Canonical labels.yml fixture
    cat > "$TMP/agents-workspace/.github/labels.yml" <<'LABELS_EOF'
- name: "type:task"
  color: "0e8a16"
  description: "Normal task"
- name: "type:incident"
  color: "d73a4a"
  description: "Incident"
LABELS_EOF

    # Mock git: logs all invocations; handles clone/config/diff/add/commit/push.
    # GIT_DIFF_RC knob: 0 = no diff (skip commit), non-zero = has diff (commit+push).
    cat > "$TMP/mock-bin/git" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
[ -n "${MOCK_LOG:-}" ] && printf '%s\n' "git $ARGS" >> "$MOCK_LOG"
case "$1" in
  clone)
    # Create the target directory and seed a fixture .github/labels.yml
    DEST="${!#}"
    mkdir -p "$DEST/.github"
    echo "# old seeded content" > "$DEST/.github/labels.yml"
    exit 0
    ;;
  config)
    exit 0
    ;;
  -C)
    # git -C <dir> <subcmd> ...
    _GIT_DIR="$2"; shift 2
    case "$1" in
      config) exit 0 ;;
      diff)
        exit "${GIT_DIFF_RC:-0}"
        ;;
      add) exit 0 ;;
      commit) exit 0 ;;
      push) exit 0 ;;
      *) exit 0 ;;
    esac
    ;;
  diff)
    exit "${GIT_DIFF_RC:-0}"
    ;;
  add) exit 0 ;;
  commit) exit 0 ;;
  push) exit 0 ;;
  *) exit 0 ;;
esac
MOCK_EOF
    chmod +x "$TMP/mock-bin/git"

    # Mock gh: logs all invocations; handles label list and label create.
    cat > "$TMP/mock-bin/gh" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
[ -n "${MOCK_LOG:-}" ] && printf '%s\n' "gh $ARGS" >> "$MOCK_LOG"
case "$ARGS" in
  label\ list*)
    exit 0
    ;;
  label\ create\ *--force*)
    exit 0
    ;;
  label\ create\ *)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
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
          SIBLING_REPOS AGENTS_WORKSPACE GIT_WORK_DIR 2>/dev/null || true
}

# Helper: find the first labels.yml written under the workdir
find_sibling_labels() {
    find "$TMP/workdir" -name "labels.yml" 2>/dev/null | head -1
}

# ===========================================================================
# T-propagate-2: PAT unset → skip message, exit 0, git clone NOT logged
# ===========================================================================
setup_mock
unset PROPAGATE_LABELS_PAT 2>/dev/null || true
export AGENTS_WORKSPACE="$TMP/agents-workspace"
export GIT_WORK_DIR="$TMP/workdir"
export CANONICAL_LABELS_FILE="$TMP/agents-workspace/.github/labels.yml"
export SIBLING_REPOS="testorg/testrepo"
STDOUT="$(run_with_timeout 30 bash "$TARGET" 2>&1)"
RC=$?
CLONE_LOGGED=0
grep -q "git clone" "$MOCK_LOG" 2>/dev/null && CLONE_LOGGED=1
SKIP_MSG=0
echo "$STDOUT" | grep -q "PROPAGATE_LABELS_PAT not set" && SKIP_MSG=1
if [ "$RC" = "0" ] && [ "$CLONE_LOGGED" = "0" ] && [ "$SKIP_MSG" = "1" ]; then
    pass "T-propagate-2: PAT unset → skip msg + exit 0 + git clone NOT called"
else
    fail "T-propagate-2: rc=$RC clone_logged=$CLONE_LOGGED skip_msg=$SKIP_MSG stdout=$(printf '%q' "$STDOUT")"
fi
teardown_mock

# ===========================================================================
# T-propagate-2b: PAT empty string → skip message, exit 0, git clone NOT logged
# ===========================================================================
setup_mock
export PROPAGATE_LABELS_PAT=""
export AGENTS_WORKSPACE="$TMP/agents-workspace"
export GIT_WORK_DIR="$TMP/workdir"
export CANONICAL_LABELS_FILE="$TMP/agents-workspace/.github/labels.yml"
export SIBLING_REPOS="testorg/testrepo"
STDOUT="$(run_with_timeout 30 bash "$TARGET" 2>&1)"
RC=$?
CLONE_LOGGED=0
grep -q "git clone" "$MOCK_LOG" 2>/dev/null && CLONE_LOGGED=1
SKIP_MSG=0
echo "$STDOUT" | grep -q "PROPAGATE_LABELS_PAT not set" && SKIP_MSG=1
if [ "$RC" = "0" ] && [ "$CLONE_LOGGED" = "0" ] && [ "$SKIP_MSG" = "1" ]; then
    pass "T-propagate-2b: PAT empty → skip msg + exit 0 + git clone NOT called"
else
    fail "T-propagate-2b: rc=$RC clone_logged=$CLONE_LOGGED skip_msg=$SKIP_MSG stdout=$(printf '%q' "$STDOUT")"
fi
teardown_mock

# ===========================================================================
# T-propagate-1: clone URL contains PAT-embedded token for each sibling
# ===========================================================================
setup_mock
export PROPAGATE_LABELS_PAT="test-secret-pat-12345"
export GIT_DIFF_RC=0
export AGENTS_WORKSPACE="$TMP/agents-workspace"
export GIT_WORK_DIR="$TMP/workdir"
export CANONICAL_LABELS_FILE="$TMP/agents-workspace/.github/labels.yml"
export SIBLING_REPOS="myorg/myrepo"
run_with_timeout 30 bash "$TARGET" >/dev/null 2>&1
CLONE_URL_HAS_PAT=0
grep "git clone" "$MOCK_LOG" 2>/dev/null | grep -q "x-access-token:test-secret-pat-12345" && CLONE_URL_HAS_PAT=1
if [ "$CLONE_URL_HAS_PAT" = "1" ]; then
    pass "T-propagate-1: clone URL embeds PAT as x-access-token:<PAT>"
else
    fail "T-propagate-1: clone_url_has_pat=$CLONE_URL_HAS_PAT log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-propagate-3 / T-propagate-header-exact: GENERATED header is the first line
# of the sibling labels.yml AND matches the exact literal. GENERATED_HEADER is
# defined (top of file) as the verbatim contract literal, so this single
# assertion covers both "header present as line 1" and "header text is exact".
# ===========================================================================
setup_mock
export PROPAGATE_LABELS_PAT="test-secret-pat-12345"
export GIT_DIFF_RC=0
export AGENTS_WORKSPACE="$TMP/agents-workspace"
export GIT_WORK_DIR="$TMP/workdir"
export CANONICAL_LABELS_FILE="$TMP/agents-workspace/.github/labels.yml"
export SIBLING_REPOS="myorg/myrepo"
run_with_timeout 30 bash "$TARGET" >/dev/null 2>&1
SIBLING_LABELS="$(find_sibling_labels)"
FIRST_LINE=""
[ -n "$SIBLING_LABELS" ] && FIRST_LINE="$(head -1 "$SIBLING_LABELS")"
assert_eq "T-propagate-3/header-exact: GENERATED header is exact first line of sibling labels.yml" \
    "$GENERATED_HEADER" "$FIRST_LINE"
teardown_mock

# ===========================================================================
# T-propagate-4: no diff → git commit NOT logged
# Use real AGENTS_DIR so sync-labels.sh (invoked after git diff) can run
# against mock gh, keeping the overall exit code clean.
# ===========================================================================
setup_mock
export PROPAGATE_LABELS_PAT="test-secret-pat-12345"
export GIT_DIFF_RC=0  # no changes
export AGENTS_WORKSPACE="$AGENTS_DIR"
export GIT_WORK_DIR="$TMP/workdir"
export CANONICAL_LABELS_FILE="$TMP/agents-workspace/.github/labels.yml"
export SIBLING_REPOS="myorg/myrepo"
run_with_timeout 30 bash "$TARGET" >/dev/null 2>&1
RC=$?
COMMIT_LOGGED=0
grep -qE "git (-C [^ ]+ )?commit" "$MOCK_LOG" 2>/dev/null && COMMIT_LOGGED=1
if [ "$RC" = "0" ] && [ "$COMMIT_LOGGED" = "0" ]; then
    pass "T-propagate-4: no diff → git commit NOT called"
else
    fail "T-propagate-4: rc=$RC commit_logged=$COMMIT_LOGGED log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-propagate-5: diff present → git commit AND git push logged
# Use real AGENTS_DIR so sync-labels.sh can run against mock gh cleanly.
# ===========================================================================
setup_mock
export PROPAGATE_LABELS_PAT="test-secret-pat-12345"
export GIT_DIFF_RC=1  # has changes
export AGENTS_WORKSPACE="$AGENTS_DIR"
export GIT_WORK_DIR="$TMP/workdir"
export CANONICAL_LABELS_FILE="$TMP/agents-workspace/.github/labels.yml"
export SIBLING_REPOS="myorg/myrepo"
run_with_timeout 30 bash "$TARGET" >/dev/null 2>&1
COMMIT_LOGGED=0
PUSH_LOGGED=0
grep -qE "git (-C [^ ]+ )?commit" "$MOCK_LOG" 2>/dev/null && COMMIT_LOGGED=1
grep -qE "git (-C [^ ]+ )?push" "$MOCK_LOG" 2>/dev/null && PUSH_LOGGED=1
if [ "$COMMIT_LOGGED" = "1" ] && [ "$PUSH_LOGGED" = "1" ]; then
    pass "T-propagate-5: diff present → git commit AND git push called"
else
    fail "T-propagate-5: commit_logged=$COMMIT_LOGGED push_logged=$PUSH_LOGGED log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-propagate-6: sync-labels.sh --repo invoked per sibling → gh label in log
# Use real AGENTS_DIR so real sync-labels.sh runs against mock gh.
# ===========================================================================
setup_mock
export PROPAGATE_LABELS_PAT="test-secret-pat-12345"
export GIT_DIFF_RC=0
export AGENTS_WORKSPACE="$AGENTS_DIR"
export GIT_WORK_DIR="$TMP/workdir"
export CANONICAL_LABELS_FILE="$TMP/agents-workspace/.github/labels.yml"
export SIBLING_REPOS="myorg/myrepo"
run_with_timeout 60 bash "$TARGET" >/dev/null 2>&1
GH_LABEL_LOGGED=0
grep -q "gh label" "$MOCK_LOG" 2>/dev/null && GH_LABEL_LOGGED=1
REPO_FLAG_LOGGED=0
grep "gh label" "$MOCK_LOG" 2>/dev/null | grep -q "myorg/myrepo" && REPO_FLAG_LOGGED=1
if [ "$GH_LABEL_LOGGED" = "1" ] && [ "$REPO_FLAG_LOGGED" = "1" ]; then
    pass "T-propagate-6: sync-labels.sh invoked → gh label list/create seen with --repo sibling"
else
    fail "T-propagate-6: gh_label_logged=$GH_LABEL_LOGGED repo_flag_logged=$REPO_FLAG_LOGGED log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-propagate-multi: both default siblings processed (clone called for each)
# ===========================================================================
setup_mock
export PROPAGATE_LABELS_PAT="test-secret-pat-12345"
export GIT_DIFF_RC=0
export AGENTS_WORKSPACE="$TMP/agents-workspace"
export GIT_WORK_DIR="$TMP/workdir"
export CANONICAL_LABELS_FILE="$TMP/agents-workspace/.github/labels.yml"
export SIBLING_REPOS="nirecom/dotfiles nirecom/dotfiles-private"
run_with_timeout 60 bash "$TARGET" >/dev/null 2>&1
RC=$?
DOTFILES_CLONED=0
DOTFILES_PRIVATE_CLONED=0
grep "git clone" "$MOCK_LOG" 2>/dev/null | grep -qE "nirecom/dotfiles[^-]|nirecom/dotfiles\.git" && DOTFILES_CLONED=1
grep "git clone" "$MOCK_LOG" 2>/dev/null | grep -q "nirecom/dotfiles-private" && DOTFILES_PRIVATE_CLONED=1
# If the clone line doesn't separate cleanly try broader match
if [ "$DOTFILES_CLONED" = "0" ]; then
    grep "git clone" "$MOCK_LOG" 2>/dev/null | grep "nirecom" | grep -v "private" | grep -q "dotfiles" && DOTFILES_CLONED=1
fi
if [ "$DOTFILES_CLONED" = "1" ] && [ "$DOTFILES_PRIVATE_CLONED" = "1" ]; then
    pass "T-propagate-multi: both siblings cloned (dotfiles + dotfiles-private)"
else
    fail "T-propagate-multi: rc=$RC dotfiles_cloned=$DOTFILES_CLONED private_cloned=$DOTFILES_PRIVATE_CLONED log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-propagate-header-dedup: running twice yields exactly one GENERATED header
# ===========================================================================
setup_mock
export PROPAGATE_LABELS_PAT="test-secret-pat-12345"
export GIT_DIFF_RC=0
export AGENTS_WORKSPACE="$TMP/agents-workspace"
export GIT_WORK_DIR="$TMP/workdir"
export CANONICAL_LABELS_FILE="$TMP/agents-workspace/.github/labels.yml"
export SIBLING_REPOS="myorg/myrepo"
# First run
run_with_timeout 30 bash "$TARGET" >/dev/null 2>&1
# Second run (simulating re-invocation; script overwrites via temp file so no dup)
run_with_timeout 30 bash "$TARGET" >/dev/null 2>&1
SIBLING_LABELS="$(find_sibling_labels)"
HEADER_COUNT=0
[ -n "$SIBLING_LABELS" ] && HEADER_COUNT="$(grep -c "GENERATED" "$SIBLING_LABELS" 2>/dev/null || echo 0)"
assert_eq "T-propagate-header-dedup: exactly one GENERATED header after two runs" "1" "$HEADER_COUNT"
teardown_mock

# ===========================================================================
# T-propagate-git-identity: git config user.email + user.name logged before commit
# ===========================================================================
setup_mock
export PROPAGATE_LABELS_PAT="test-secret-pat-12345"
export GIT_DIFF_RC=1  # trigger commit path
export AGENTS_WORKSPACE="$TMP/agents-workspace"
export GIT_WORK_DIR="$TMP/workdir"
export CANONICAL_LABELS_FILE="$TMP/agents-workspace/.github/labels.yml"
export SIBLING_REPOS="myorg/myrepo"
run_with_timeout 30 bash "$TARGET" >/dev/null 2>&1
EMAIL_LOGGED=0
NAME_LOGGED=0
grep -qE "git.*config.*user\.email.*github-actions\[bot\]" "$MOCK_LOG" 2>/dev/null && EMAIL_LOGGED=1
grep -qE "git.*config.*user\.name.*github-actions\[bot\]" "$MOCK_LOG" 2>/dev/null && NAME_LOGGED=1
# Verify config is logged before commit
CONFIG_BEFORE_COMMIT=0
if [ "$EMAIL_LOGGED" = "1" ] && [ "$NAME_LOGGED" = "1" ]; then
    EMAIL_LINE="$(grep -nE "git.*config.*user\.email" "$MOCK_LOG" 2>/dev/null | head -1 | cut -d: -f1)"
    COMMIT_LINE="$(grep -nE "git.*commit" "$MOCK_LOG" 2>/dev/null | head -1 | cut -d: -f1)"
    if [ -n "$EMAIL_LINE" ] && [ -n "$COMMIT_LINE" ] && [ "$EMAIL_LINE" -lt "$COMMIT_LINE" ]; then
        CONFIG_BEFORE_COMMIT=1
    fi
fi
if [ "$EMAIL_LOGGED" = "1" ] && [ "$NAME_LOGGED" = "1" ] && [ "$CONFIG_BEFORE_COMMIT" = "1" ]; then
    pass "T-propagate-git-identity: git config user.email + user.name logged before commit"
else
    fail "T-propagate-git-identity: email_logged=$EMAIL_LOGGED name_logged=$NAME_LOGGED before_commit=$CONFIG_BEFORE_COMMIT log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-propagate-independent: first sibling clone fails, second still processed
# Final exit code must be non-zero.
# ===========================================================================
setup_mock
export PROPAGATE_LABELS_PAT="test-secret-pat-12345"
export GIT_DIFF_RC=0
export AGENTS_WORKSPACE="$TMP/agents-workspace"
export GIT_WORK_DIR="$TMP/workdir"
export CANONICAL_LABELS_FILE="$TMP/agents-workspace/.github/labels.yml"
export SIBLING_REPOS="nirecom/dotfiles nirecom/dotfiles-private"
# Override mock git to fail on clone of first sibling (dotfiles), succeed for second
cat > "$TMP/mock-bin/git" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
[ -n "${MOCK_LOG:-}" ] && printf '%s\n' "git $ARGS" >> "$MOCK_LOG"
case "$1" in
  clone)
    DEST="${!#}"
    # Fail if cloning dotfiles (first sibling), succeed for dotfiles-private
    if echo "$DEST" | grep -q "dotfiles-private"; then
        mkdir -p "$DEST/.github"
        echo "# old seeded" > "$DEST/.github/labels.yml"
        exit 0
    else
        echo "mock: clone failed for first sibling" >&2
        exit 1
    fi
    ;;
  config) exit 0 ;;
  -C)
    _GIT_DIR="$2"; shift 2
    case "$1" in
      config) exit 0 ;;
      diff) exit "${GIT_DIFF_RC:-0}" ;;
      add) exit 0 ;;
      commit) exit 0 ;;
      push) exit 0 ;;
      *) exit 0 ;;
    esac
    ;;
  diff) exit "${GIT_DIFF_RC:-0}" ;;
  add) exit 0 ;;
  commit) exit 0 ;;
  push) exit 0 ;;
  *) exit 0 ;;
esac
MOCK_EOF
chmod +x "$TMP/mock-bin/git"
: > "$MOCK_LOG"
run_with_timeout 30 bash "$TARGET" >/dev/null 2>&1
RC=$?
FIRST_ATTEMPTED=0
grep "git clone" "$MOCK_LOG" 2>/dev/null | grep -v "private" | grep -q "dotfiles" && FIRST_ATTEMPTED=1
SECOND_ATTEMPTED=0
grep "git clone" "$MOCK_LOG" 2>/dev/null | grep -q "dotfiles-private" && SECOND_ATTEMPTED=1
if [ "$RC" != "0" ] && [ "$FIRST_ATTEMPTED" = "1" ] && [ "$SECOND_ATTEMPTED" = "1" ]; then
    pass "T-propagate-independent: first sibling failure does not stop second; final rc non-zero"
else
    fail "T-propagate-independent: rc=$RC first_attempted=$FIRST_ATTEMPTED second_attempted=$SECOND_ATTEMPTED log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-propagate-no-leak: PAT absent from committed labels.yml body and from stdout
# ===========================================================================
setup_mock
export PROPAGATE_LABELS_PAT="super-secret-token-xyz789"
export GIT_DIFF_RC=0
export AGENTS_WORKSPACE="$TMP/agents-workspace"
export GIT_WORK_DIR="$TMP/workdir"
export CANONICAL_LABELS_FILE="$TMP/agents-workspace/.github/labels.yml"
export SIBLING_REPOS="myorg/myrepo"
STDOUT="$(run_with_timeout 30 bash "$TARGET" 2>&1)"
SIBLING_LABELS="$(find_sibling_labels)"
PAT_IN_FILE=0
[ -n "$SIBLING_LABELS" ] && grep -q "super-secret-token-xyz789" "$SIBLING_LABELS" 2>/dev/null && PAT_IN_FILE=1
PAT_IN_STDOUT=0
echo "$STDOUT" | grep -q "super-secret-token-xyz789" && PAT_IN_STDOUT=1
if [ "$PAT_IN_FILE" = "0" ] && [ "$PAT_IN_STDOUT" = "0" ]; then
    pass "T-propagate-no-leak: PAT absent from committed labels.yml body and from stdout"
else
    fail "T-propagate-no-leak: pat_in_file=$PAT_IN_FILE pat_in_stdout=$PAT_IN_STDOUT"
fi
teardown_mock

# ===========================================================================
# T-propagate-env: custom SIBLING_REPOS (single entry) + custom CANONICAL_LABELS_FILE
# ===========================================================================
setup_mock
export PROPAGATE_LABELS_PAT="test-secret-pat-12345"
export GIT_DIFF_RC=0
# Custom canonical source
mkdir -p "$TMP/custom-src/.github"
cat > "$TMP/custom-src/.github/custom-labels.yml" <<'CUSTOM_EOF'
- name: "custom:label"
  color: "aabbcc"
  description: "Custom label for env test"
CUSTOM_EOF
export AGENTS_WORKSPACE="$TMP/agents-workspace"
export GIT_WORK_DIR="$TMP/workdir"
export CANONICAL_LABELS_FILE="$TMP/custom-src/.github/custom-labels.yml"
export SIBLING_REPOS="custom-owner/custom-repo"
run_with_timeout 30 bash "$TARGET" >/dev/null 2>&1
RC=$?
# Only custom-owner/custom-repo should be cloned
CUSTOM_CLONED=0
grep "git clone" "$MOCK_LOG" 2>/dev/null | grep -q "custom-owner/custom-repo" && CUSTOM_CLONED=1
DEFAULT_CLONED=0
grep "git clone" "$MOCK_LOG" 2>/dev/null | grep -q "nirecom/dotfiles" && DEFAULT_CLONED=1
# Custom content should appear in the sibling file
SIBLING_LABELS="$(find_sibling_labels)"
CUSTOM_CONTENT=0
[ -n "$SIBLING_LABELS" ] && grep -q "custom:label" "$SIBLING_LABELS" 2>/dev/null && CUSTOM_CONTENT=1
if [ "$CUSTOM_CLONED" = "1" ] && [ "$DEFAULT_CLONED" = "0" ] && [ "$CUSTOM_CONTENT" = "1" ]; then
    pass "T-propagate-env: custom SIBLING_REPOS + CANONICAL_LABELS_FILE respected"
else
    fail "T-propagate-env: rc=$RC custom_cloned=$CUSTOM_CLONED default_cloned=$DEFAULT_CLONED custom_content=$CUSTOM_CONTENT log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
