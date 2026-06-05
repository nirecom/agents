#!/bin/bash
# Tests: bin/github-issues/issue-create-dispatch.sh, skills/issue-create/SKILL.md
# Tags: issue-create, make-parent, group-prefix, normalize

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISPATCH_SCRIPT="$AGENTS_DIR/bin/github-issues/issue-create-dispatch.sh"

PASS=0; FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Part A: Unit tests of normalize_group_title algorithm
# This function mirrors what will be implemented in dispatch.sh
# (defense-in-depth). These tests are GREEN immediately — pure algorithm
# validation — and document the rules the integration tests below depend on.
# ---------------------------------------------------------------------------

normalize_group_title() {
    local t="$1"
    case "$t" in
        "Group: "*)
            printf '%s' "$t"
            ;;
        *)
            local stripped
            stripped=$(printf '%s' "$t" | sed -E 's/^(umbrella|tracking|meta|Umbrella|Tracking|Meta|UMBRELLA|TRACKING|META):[[:space:]]+//')
            printf 'Group: %s' "$stripped"
            ;;
    esac
}

# GP1: umbrella: prefix stripped
RESULT=$(normalize_group_title "umbrella: foo")
if [ "$RESULT" = "Group: foo" ]; then
    pass "GP1: 'umbrella: foo' -> 'Group: foo'"
else
    fail "GP1: got '$RESULT'"
fi

# GP2: tracking: prefix stripped
RESULT=$(normalize_group_title "tracking: bar")
if [ "$RESULT" = "Group: bar" ]; then
    pass "GP2: 'tracking: bar' -> 'Group: bar'"
else
    fail "GP2: got '$RESULT'"
fi

# GP3: meta: prefix stripped
RESULT=$(normalize_group_title "meta: baz")
if [ "$RESULT" = "Group: baz" ]; then
    pass "GP3: 'meta: baz' -> 'Group: baz'"
else
    fail "GP3: got '$RESULT'"
fi

# GP4: idempotent when already Group:
RESULT=$(normalize_group_title "Group: qux")
if [ "$RESULT" = "Group: qux" ]; then
    pass "GP4: 'Group: qux' -> 'Group: qux' (idempotent)"
else
    fail "GP4: got '$RESULT'"
fi

# GP5: bug: NOT in strip set -> prepend only
RESULT=$(normalize_group_title "bug: zap")
if [ "$RESULT" = "Group: bug: zap" ]; then
    pass "GP5: 'bug: zap' -> 'Group: bug: zap' (bug: not stripped)"
else
    fail "GP5: got '$RESULT'"
fi

# GP6: case-insensitive — Umbrella:
RESULT=$(normalize_group_title "Umbrella: foo")
if [ "$RESULT" = "Group: foo" ]; then
    pass "GP6: 'Umbrella: foo' -> 'Group: foo' (case-insensitive)"
else
    fail "GP6: got '$RESULT'"
fi

# GP7: uppercase — META:
RESULT=$(normalize_group_title "META: baz")
if [ "$RESULT" = "Group: baz" ]; then
    pass "GP7: 'META: baz' -> 'Group: baz' (uppercase)"
else
    fail "GP7: got '$RESULT'"
fi

# ---------------------------------------------------------------------------
# Part B: Integration tests via dispatch.sh
# RED until dispatch.sh make-parent is updated with normalize_group_title.
# ---------------------------------------------------------------------------

# Setup helper: build a temp AGENTS_CONFIG_DIR with a mock issue-create.sh
# (records --title to $DISPATCH_TITLE_LOG) and a mock gh CLI.
setup_dispatch_tmp() {
    D_TMP="$(mktemp -d)"
    mkdir -p "$D_TMP/bin/github-issues"
    mkdir -p "$D_TMP/mock-bin"

    # Mock issue-create.sh records the --title value into the file named by
    # the runtime env var DISPATCH_TITLE_LOG and emits a fake issue URL.
    # Single-quoted heredoc on purpose — $DISPATCH_TITLE_LOG is resolved at
    # mock-execution time, not at script-write time.
    cat > "$D_TMP/bin/github-issues/issue-create.sh" << 'MOCK_ISSUE_CREATE'
#!/bin/bash
prev=""
for arg in "$@"; do
    if [ "$prev" = "--title" ]; then
        printf '%s\n' "$arg" > "${DISPATCH_TITLE_LOG}"
        break
    fi
    prev="$arg"
done
echo "https://github.com/owner/repo/issues/999"
MOCK_ISSUE_CREATE
    chmod +x "$D_TMP/bin/github-issues/issue-create.sh"

    # Mock gh: tolerate repo slug lookup, GraphQL databaseId, and POST attach.
    cat > "$D_TMP/mock-bin/gh" << 'MOCK_GH'
#!/bin/bash
ARGS="$*"
case "$ARGS" in
    "repo view --json nameWithOwner --jq .nameWithOwner"*)
        echo "owner/repo" ;;
    "api graphql"*)
        echo "12345" ;;
    "api -X POST "*)
        exit 0 ;;
    *)
        exit 0 ;;
esac
MOCK_GH
    chmod +x "$D_TMP/mock-bin/gh"

    export AGENTS_CONFIG_DIR="$D_TMP"
    export DISPATCH_TITLE_LOG="$D_TMP/title.log"
    : > "$DISPATCH_TITLE_LOG"
    export PATH="$D_TMP/mock-bin:$PATH"
}

teardown_dispatch_tmp() {
    [ -n "${D_TMP:-}" ] && [ -d "$D_TMP" ] && rm -rf "$D_TMP"
    unset AGENTS_CONFIG_DIR DISPATCH_TITLE_LOG D_TMP
}

# GP_INT_1: dispatch.sh make-parent with title "umbrella: foo" -> recorded "Group: foo"
setup_dispatch_tmp
bash "$DISPATCH_SCRIPT" \
    --verdict make-parent --children 1 \
    -- --title "umbrella: foo" --body "Background: test\n\nChanges: test" \
    >/dev/null 2>&1 || true
RECORDED="$(cat "$DISPATCH_TITLE_LOG" 2>/dev/null || echo '')"
if [ "$RECORDED" = "Group: foo" ]; then
    pass "GP_INT_1: dispatch make-parent 'umbrella: foo' -> recorded title 'Group: foo'"
else
    fail "GP_INT_1: recorded title='$RECORDED' (expected 'Group: foo'; RED before dispatch.sh impl)"
fi
teardown_dispatch_tmp

# GP_INT_2: dispatch.sh make-parent with title "tracking: bar" -> "Group: bar"
setup_dispatch_tmp
bash "$DISPATCH_SCRIPT" \
    --verdict make-parent --children 1 \
    -- --title "tracking: bar" --body "Background: test\n\nChanges: test" \
    >/dev/null 2>&1 || true
RECORDED="$(cat "$DISPATCH_TITLE_LOG" 2>/dev/null || echo '')"
if [ "$RECORDED" = "Group: bar" ]; then
    pass "GP_INT_2: dispatch make-parent 'tracking: bar' -> recorded title 'Group: bar'"
else
    fail "GP_INT_2: recorded title='$RECORDED' (expected 'Group: bar'; RED before dispatch.sh impl)"
fi
teardown_dispatch_tmp

# GP_INT_3: dispatch.sh make-parent with title "Group: already" -> idempotent
setup_dispatch_tmp
bash "$DISPATCH_SCRIPT" \
    --verdict make-parent --children 1 \
    -- --title "Group: already" --body "Background: test\n\nChanges: test" \
    >/dev/null 2>&1 || true
RECORDED="$(cat "$DISPATCH_TITLE_LOG" 2>/dev/null || echo '')"
if [ "$RECORDED" = "Group: already" ]; then
    pass "GP_INT_3: dispatch make-parent 'Group: already' -> idempotent"
else
    fail "GP_INT_3: recorded title='$RECORDED' (expected 'Group: already')"
fi
teardown_dispatch_tmp

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
