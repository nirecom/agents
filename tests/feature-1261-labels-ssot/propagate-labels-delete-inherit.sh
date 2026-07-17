#!/bin/bash
# tests/feature-1261-labels-ssot/propagate-labels-delete-inherit.sh
# Tests: bin/github-issues/propagate-labels.sh (DELETE inheritance from sync-labels.sh)
# Tags: labels-ssot, propagation, delete, scope:issue-specific
#
# L3 gap (what this test does NOT catch):
# - Real GitHub API calls and PAT authentication not covered — mock gh intercepts
#   all network calls; no actual HTTPS connection is made.
# - Real sync-labels.sh against live gh API not covered — mock gh is used.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

TARGET="${PROPAGATE_LABELS_SH:-$AGENTS_DIR/bin/github-issues/propagate-labels.sh}"
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
          SIBLING_REPOS AGENTS_WORKSPACE GIT_WORK_DIR GH_MOCK_LABEL_LIST 2>/dev/null || true
}

# ===========================================================================
# T-propagate-delete-inherit: DELETE propagation via propagate-labels.sh →
# sync-labels.sh → gh label delete logged.
# Proves MUST class member: propagate inherits sync-labels DELETE with zero
# code change to propagate-labels.sh.
# ===========================================================================
setup_mock
# Override inline mock gh to support GH_MOCK_LABEL_LIST for `label list`
# and log `label delete` calls.
cat > "$TMP/mock-bin/gh" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
[ -n "${MOCK_LOG:-}" ] && printf '%s\n' "gh $ARGS" >> "$MOCK_LOG"
case "$ARGS" in
  label\ list*)
    if [ -n "${GH_MOCK_LABEL_LIST:-}" ]; then
        printf '%s\n' "$GH_MOCK_LABEL_LIST"
    fi
    exit 0
    ;;
  label\ delete\ *)
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
export PROPAGATE_LABELS_PAT="test-secret-pat-12345"
export GIT_DIFF_RC=0
export AGENTS_WORKSPACE="$AGENTS_DIR"
export GIT_WORK_DIR="$TMP/workdir"
export CANONICAL_LABELS_FILE="$TMP/agents-workspace/.github/labels.yml"
export SIBLING_REPOS="myorg/myrepo"
# labels.yml: type:task のみ (setup_mock の 2 件を上書き)
cat > "$TMP/agents-workspace/.github/labels.yml" <<'LABELS_EOF'
- name: "type:task"
  color: "0e8a16"
  description: "Normal task"
LABELS_EOF
# mock: type:task + stale:ghost を返す → stale:ghost が DELETE 対象
export GH_MOCK_LABEL_LIST=$'type:task\t0e8a16\tNormal task\nstale:ghost\taaaaaa\tOld ghost label'
run_with_timeout 60 bash "$TARGET" >/dev/null 2>&1
DELETE_LOGGED=0
grep -q "gh label delete" "$MOCK_LOG" 2>/dev/null && DELETE_LOGGED=1
if [ "$DELETE_LOGGED" = "1" ]; then
    pass "T-propagate-delete-inherit: sync-labels DELETE propagated via propagate-labels.sh"
else
    fail "T-propagate-delete-inherit: delete_logged=$DELETE_LOGGED log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
