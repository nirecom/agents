# Shared test infrastructure for fix-propagate-labels-fixes tests.
# Sourced by tests/fix-propagate-labels-fixes.sh — not run standalone.

AGENTS_DIR="${AGENTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
TARGET="${PROPAGATE_LABELS_SH:-$AGENTS_DIR/bin/github-issues/propagate-labels.sh}"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    elif command -v perl >/dev/null 2>&1; then perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    else "$@"; fi
}

TMP=""

# ---------------------------------------------------------------------------
# Shared mock factory. Writes a git + gh mock into $TMP/mock-bin that log every
# invocation to $MOCK_LOG. The git mock resolves `-C <dir> remote get-url origin`
# to https://github.com/<owner>/<repo>.git by taking the last two path
# components of <dir>, mirroring propagate-labels-ci/_setup.sh. rev-parse
# --git-dir exit code is controlled per-directory via a marker file
# ($dir/.is-git-repo present → exit 0, absent → exit 1) so depth-1 scan tests
# can distinguish parent dirs from repo dirs.
# ---------------------------------------------------------------------------
setup_common_mock() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/mock-bin" "$TMP/workdir" "$TMP/agents-workspace/.github"

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
ARGS="$*"
[ -n "${MOCK_LOG:-}" ] && printf '%s\n' "gh $ARGS" >> "$MOCK_LOG"
case "$ARGS" in
  auth\ token*)
    [ -n "${GH_MOCK_AUTH_TOKEN:-}" ] && printf '%s\n' "$GH_MOCK_AUTH_TOKEN"
    exit 0
    ;;
  label\ list*)
    [ -n "${GH_MOCK_LABEL_LIST:-}" ] && printf '%s\n' "$GH_MOCK_LABEL_LIST"
    exit 0
    ;;
  *) exit 0 ;;
esac
MOCK_EOF
    chmod +x "$TMP/mock-bin/gh"

    export PATH="$TMP/mock-bin:$PATH"
    export MOCK_LOG="$TMP/mock.log"
    : > "$MOCK_LOG"
    export GIT_DIFF_RC=0
    export AGENTS_WORKSPACE="$AGENTS_DIR"
    export GIT_WORK_DIR="$TMP/workdir"
    export CANONICAL_LABELS_FILE="$TMP/agents-workspace/.github/labels.yml"
}

teardown_common_mock() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP" 2>/dev/null || true
    fi
    TMP=""
    unset MOCK_LOG GIT_DIFF_RC PROPAGATE_LABELS_PAT CANONICAL_LABELS_FILE \
          PROPAGATE_LABELS_REPOS AGENTS_WORKSPACE GIT_WORK_DIR \
          GH_MOCK_LABEL_LIST GH_MOCK_AUTH_TOKEN PROPAGATE_LABELS_NO_DELETE \
          2>/dev/null || true
}
