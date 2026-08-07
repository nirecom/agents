# Helper: `gh` PATH stubs shared by every group (#1833)
# Tests: bin/audit-tests.sh, bin/audit-tests-common.sh, bin/lib/test-retire-predicate.sh
# Tags: TL2, audit-tests, retire, helper, scope:issue-specific
# Sourced by tests/fix-1833-audit-tests-survival-first.sh (before any group)
#
# Four flavours of a fake GitHub CLI, one per way metadata can be obtained or
# lost. They are kept together because the differences between them ARE the
# contract under test (see group B and group M), and a reader comparing two of
# them should not have to open two files.

# ── gh stubs ────────────────────────────────────────────────────────────────
# The stub answers `gh repo view` with a fixed slug and
# `gh api repos/<slug>/issues/<N>` from the $MOCK_ISSUES env var, one
# "<num> <state> <closed_at>" record per line. Unknown numbers exit 1 (404).

install_gh_mock() {
    local bindir="$1"
    mkdir -p "$bindir"
    cat > "$bindir/gh" <<'GHEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "repo" && "${2:-}" == "view" ]]; then
  echo "acme/widget"
  exit 0
fi
if [[ "${1:-}" == "api" ]]; then
  target=""
  for a in "$@"; do
    case "$a" in
      */issues/*) target="${a##*/issues/}" ;;
    esac
  done
  while IFS=' ' read -r num state closed; do
    [[ -z "${num:-}" ]] && continue
    if [[ "$num" == "$target" ]]; then
      printf '%s %s\n' "$state" "${closed:-}"
      exit 0
    fi
  done <<< "${MOCK_ISSUES:-}"
  exit 1
fi
exit 0
GHEOF
    chmod +x "$bindir/gh"
}

# install_gh_mock_api_fails <bindir> — `gh repo view` succeeds (so the script
# stays ONLINE) but every `gh api` call fails, simulating timeout / 5xx.
install_gh_mock_api_fails() {
    local bindir="$1"
    mkdir -p "$bindir"
    cat > "$bindir/gh" <<'GHEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "repo" && "${2:-}" == "view" ]]; then
  echo "acme/widget"
  exit 0
fi
exit 1
GHEOF
    chmod +x "$bindir/gh"
}

# install_gh_mock_repo_view_fails <bindir> — `gh` is installed and runnable but
# `gh repo view` itself exits non-zero (no remote, wrong auth scope, network
# down). The slug never resolves, so no issue can be looked up. Distinct from
# install_gh_mock_api_fails, where the slug DID resolve.
install_gh_mock_repo_view_fails() {
    local bindir="$1"
    mkdir -p "$bindir"
    cat > "$bindir/gh" <<'GHEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "repo" && "${2:-}" == "view" ]]; then
  echo "error: failed to resolve repository" >&2
  exit 1
fi
echo "error: no repository slug" >&2
exit 1
GHEOF
    chmod +x "$bindir/gh"
}

# install_gh_mock_slow <bindir> <seconds> — `gh repo view` answers instantly so
# the script stays ONLINE, but every `gh api` call sleeps past the pinned
# $GH_TIMEOUT. This is the branch where run-with-timeout.sh kills the child.
install_gh_mock_slow() {
    local bindir="$1" secs="$2"
    mkdir -p "$bindir"
    cat > "$bindir/gh" <<GHEOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "repo" && "\${2:-}" == "view" ]]; then
  echo "acme/widget"
  exit 0
fi
sleep $secs
echo "closed 2019-01-01"
exit 0
GHEOF
    chmod +x "$bindir/gh"
}
