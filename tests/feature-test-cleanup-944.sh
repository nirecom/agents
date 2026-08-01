#!/bin/bash
# Tests: skills/_shared/test-design.md, bin/review-code-size, bin/audit-tests.sh
# Tags: scope:issue-specific, test-cleanup, scope-classification, audit-tests
# Tests for issue #944: tests cleanup governance + audit-tests.sh
#
# L3 gap (what this test does NOT catch):
# - Real gh api network calls: mocked via PATH stub; actual GitHub issue state lookups untested
# - Real git log across worktrees: isolated tmp repos used; production repo clock drift untested
# - audit-tests.sh invoked by a human operator confirming candidate list before bulk delete
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DESIGN="$AGENTS_ROOT/skills/_shared/test-design.md"
REVIEW_SIZE="$AGENTS_ROOT/bin/review-code-size"
AUDIT_TESTS="$AGENTS_ROOT/bin/audit-tests.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)/feature-test-cleanup-944"

ERRORS=0
fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }
skip() { echo "SKIP: $1"; }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

TMPDIR_BASE=$(mktemp -d)
EMPTY_HOOKS_DIR="$TMPDIR_BASE/no-hooks"
mkdir -p "$EMPTY_HOOKS_DIR"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

make_repo() {
    local repo
    repo=$(mktemp -d -p "$TMPDIR_BASE")
    git -C "$repo" init -q
    git -C "$repo" config core.hooksPath "$EMPTY_HOOKS_DIR"
    git -C "$repo" config core.autocrlf false
    git -C "$repo" checkout -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m "initial"
    echo "$repo"
}

make_lines() {
    local n="$1" i
    for ((i = 1; i <= n; i++)); do echo "line $i"; done
}

# days_ago_iso <days> — UTC timestamp N days in the past, ISO-8601 with Z.
# Single source for every backdated timestamp in this suite (git commit dates
# and gh-stub closed_at values alike).
days_ago_iso() {
    local days="$1"
    date -u -d "$days days ago" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
        || date -u -v-"${days}"d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
        || uv run python -c "import datetime; print((datetime.datetime.utcnow()-datetime.timedelta(days=$days)).strftime('%Y-%m-%dT%H:%M:%SZ'))"
}

# make_gh_stub <stub_dir> <state> [closed_at]
#
# gh stub for bin/audit-tests.sh. The script queries
#   gh api repos/<slug>/issues/<N> --jq '.state + " " + (.closed_at // "")'
# and filters on the issue's closed_at (#1557) — NOT on the file's commit date.
# The stub therefore has to emit BOTH fields: a state-only stub makes every
# closed issue hit the "closed but closed_at unavailable — skipped" branch, so
# no dispatcher is ever a candidate.
#
# closed_at defaults to a long-past date so the issue is stale under any
# --stale-months value; cases that need a specific staleness boundary pass
# their own value. An open issue always reports an empty closed_at, matching
# `.closed_at // ""` against a live open issue.
make_gh_stub() {
    local stub_dir="$1" state="$2" closed_at="${3:-2019-01-01T00:00:00Z}"
    local state_lc parametrized_closed_at="$closed_at"
    state_lc="$(echo "$state" | tr '[:upper:]' '[:lower:]')"
    [[ "$state_lc" == "closed" ]] || parametrized_closed_at=""
    cat > "$stub_dir/gh" <<EOF
#!/bin/bash
case "\$*" in
    *repo*view*) echo "testowner/testrepo"; exit 0 ;;
    *"issues/100"*) echo "$state $parametrized_closed_at"; exit 0 ;;
    *"issues/200"*) echo "open "; exit 0 ;;
    *"issues/300"*) echo "closed $closed_at"; exit 0 ;;
    *"issues/400"*) echo "CLOSED $closed_at"; exit 0 ;;
    *auth*status*) exit 0 ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$stub_dir/gh"
}

# install_audit_libs <dest-dir>
#
# bin/audit-tests.sh sources its libs from the COPIED script's own $SCRIPT_DIR
# (see bin/audit-tests.sh:15-19), so lib/ must sit next to wherever the script
# was copied — NOT unconditionally at <repo>/bin/lib/. Every copy site therefore
# passes the directory that contains its own copy of audit-tests.sh.
# Wildcard copy (not an explicit file list) so new bin/lib/*.sh files do not
# break these fixtures.
install_audit_libs() {
    local dest="$1"
    mkdir -p "$dest/lib"
    cp "$AGENTS_ROOT"/bin/lib/*.sh "$dest/lib/"
}

setup_audit_repo() {
    local repo
    repo=$(make_repo)
    mkdir -p "$repo/tests" "$repo/bin"
    cp "$AUDIT_TESTS" "$repo/bin/audit-tests.sh"
    chmod +x "$repo/bin/audit-tests.sh"
    install_audit_libs "$repo/bin"
    # audit-tests.sh shells out to "$SCRIPT_DIR/run-with-timeout.sh" for its gh
    # call; without it every issue lookup silently fails, no dispatcher is ever
    # a candidate, and every online-path assertion passes vacuously.
    cp "$AGENTS_ROOT/bin/run-with-timeout.sh" "$repo/bin/run-with-timeout.sh"
    chmod +x "$repo/bin/run-with-timeout.sh"
    echo "$repo"
}

backdate_commit() {
    local repo="$1" days="$2" msg="$3"
    local d
    d="$(days_ago_iso "$days")"
    GIT_AUTHOR_DATE="$d" GIT_COMMITTER_DATE="$d" git -C "$repo" commit -q -m "$msg"
}

# shellcheck source=feature-test-cleanup-944/group-a-governance.sh
. "$SCRIPT_DIR/group-a-governance.sh"
# shellcheck source=feature-test-cleanup-944/group-b-code-size.sh
. "$SCRIPT_DIR/group-b-code-size.sh"
# shellcheck source=feature-test-cleanup-944/group-c-filtering.sh
. "$SCRIPT_DIR/group-c-filtering.sh"
# shellcheck source=feature-test-cleanup-944/group-d-flags.sh
. "$SCRIPT_DIR/group-d-flags.sh"
# shellcheck source=feature-test-cleanup-944/group-e-deletion.sh
. "$SCRIPT_DIR/group-e-deletion.sh"

echo "---"
if [[ $ERRORS -gt 0 ]]; then
    echo "FAILED: $ERRORS test(s) failed"
    exit 1
fi
echo "ALL PASSED"
exit 0
