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

make_gh_stub() {
    local stub_dir="$1" state="$2"
    cat > "$stub_dir/gh" <<EOF
#!/bin/bash
case "\$*" in
    *repo*view*) echo "testowner/testrepo"; exit 0 ;;
    *"issues/100"*) echo "$state"; exit 0 ;;
    *"issues/200"*) echo "open"; exit 0 ;;
    *"issues/300"*) echo "closed"; exit 0 ;;
    *"issues/400"*) echo "CLOSED"; exit 0 ;;
    *auth*status*) exit 0 ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$stub_dir/gh"
}

setup_audit_repo() {
    local repo
    repo=$(make_repo)
    mkdir -p "$repo/tests" "$repo/bin"
    cp "$AUDIT_TESTS" "$repo/bin/audit-tests.sh"
    chmod +x "$repo/bin/audit-tests.sh"
    echo "$repo"
}

backdate_commit() {
    local repo="$1" days="$2" msg="$3"
    local d
    d=$(date -u -d "$days days ago" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
        || date -u -v-"${days}"d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
        || python3 -c "import datetime; print((datetime.datetime.utcnow()-datetime.timedelta(days=$days)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
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

echo "---"
if [[ $ERRORS -gt 0 ]]; then
    echo "FAILED: $ERRORS test(s) failed"
    exit 1
fi
echo "ALL PASSED"
exit 0
