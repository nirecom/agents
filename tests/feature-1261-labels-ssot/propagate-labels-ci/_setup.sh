# tests/feature-1261-labels-ssot/propagate-labels-ci/_setup.sh
# Shared mock setup/teardown helpers for propagate-labels-ci.sh

setup_mock() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/mock-bin"
    mkdir -p "$TMP/workdir"
    mkdir -p "$TMP/agents-workspace/.github"

    # Repo directory stubs for path-based PROPAGATE_LABELS_REPOS
    mkdir -p "$TMP/repos/myorg/myrepo"
    mkdir -p "$TMP/repos/nirecom/dotfiles"
    mkdir -p "$TMP/repos/nirecom/my-private-repo"
    mkdir -p "$TMP/repos/custom-owner/custom-repo"
    mkdir -p "$TMP/repos/testorg/testrepo"
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
    # For -C <dir> remote get-url origin: derives owner/repo from the last two
    # path components of the directory (basename logic).
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
      remote)
        # Only emit output for get-url; other subcommands (set-url etc.) exit 0
        if [ "${2:-}" = "get-url" ]; then
            _REPO_NAME="$(basename "$_GIT_DIR")"
            _OWNER_NAME="$(basename "$(dirname "$_GIT_DIR")")"
            printf 'https://github.com/%s/%s.git\n' "$_OWNER_NAME" "$_REPO_NAME"
        fi
        exit 0
        ;;
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

    # Mock gh: logs all invocations; all subcommands exit 0.
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
          PROPAGATE_LABELS_REPOS AGENTS_WORKSPACE GIT_WORK_DIR GH_MOCK_LABEL_LIST 2>/dev/null || true
}

# Helper: find the first labels.yml written under the workdir
find_sibling_labels() {
    find "$TMP/workdir" -name "labels.yml" 2>/dev/null | head -1
}
