#!/bin/bash
# Tests: agents/issues/, agents/issues/100/sub_issues, agents/issues/201, agents/issues/201/sub_issues, agents/issues/42, agents/issues/9999, bin/gh, bin/github-issues/issue-create-dispatch.sh, bin/github-issues/issue-create.sh, skills/issue-create/SKILL.md, skills/workflow-init/SKILL.md
# Tags: issue-create, github, sub-issue, frontmatter, tests, scope:issue-specific
#
# L3 gap (what this test does NOT catch):
# - Real GitHub API: actual sub_issues POST acceptance, GraphQL databaseId availability
# - MSYS_NO_PATHCONV interaction on live Windows Git Bash sessions
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration
#
# Tests for the new /issue-create skill:
#   bin/github-issues/issue-create.sh  — bash wrapper around gh issue create
#   skills/issue-create/SKILL.md       — YAML frontmatter skill definition
#   rules/github-issues.md             — ## Issue creation section
#   CLAUDE.md                          — /issue-create mention
#
# RED: this suite fails clean while bin/github-issues/issue-create.sh is missing.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$AGENTS_DIR/bin/github-issues/issue-create.sh"
DISPATCH="$AGENTS_DIR/bin/github-issues/issue-create-dispatch.sh"
SKILL_MD="$AGENTS_DIR/skills/issue-create/SKILL.md"
WORKFLOW_INIT_MD="$AGENTS_DIR/skills/workflow-init/SKILL.md"
RULES_GH="$AGENTS_DIR/rules/github-issues.md"
CLAUDE_MD="$AGENTS_DIR/CLAUDE.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

# Early-exit: if the implementation is missing, report cleanly and exit.
if [ ! -f "$TARGET" ]; then
    echo "FAIL: bin/github-issues/issue-create.sh not found (implementation missing)"
    echo ""
    echo "Results: 0 passed, 30 failed"
    exit 1
fi

# ---------------------------------------------------------------------------
# Inline gh mock factory — creates a self-contained mock in $TMP/mock-bin/gh
# per test so each test gets its own args log and env vars.
# ---------------------------------------------------------------------------

TMP=""

setup_mock() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/mock-bin"
    cat > "$TMP/mock-bin/gh" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
if [ -n "${GH_MOCK_ARGS_LOG:-}" ]; then
    printf '%s\n' "$ARGS" >> "$GH_MOCK_ARGS_LOG"
fi
case "$ARGS" in
  auth\ status*)
    echo "Token scopes: 'gist', 'project', 'read:org', 'repo'"
    exit 0 ;;
  issue\ create\ *)
    # Default: same NUM for every create (back-compat with single-create tests).
    # Opt-in counter mode for bulk: when GH_MOCK_ISSUE_NUMS is a comma list, each
    # successive `issue create` consumes the next number in manifest order via a
    # file-based cursor (the mock runs once per gh call, so state must persist).
    if [ -n "${GH_MOCK_ISSUE_NUMS:-}" ]; then
        CURSOR_FILE="${GH_MOCK_CREATE_CURSOR:-/tmp/gh-mock-create-cursor}"
        IDX=0
        [ -f "$CURSOR_FILE" ] && IDX=$(cat "$CURSOR_FILE")
        IFS=',' read -ra NUMS <<< "$GH_MOCK_ISSUE_NUMS"
        NUM="${NUMS[$IDX]:-9999}"
        echo $((IDX + 1)) > "$CURSOR_FILE"
    else
        NUM="${GH_MOCK_NEW_ISSUE_NUM:-9999}"
    fi
    echo "https://github.com/nirecom/agents/issues/${NUM}"
    exit 0 ;;
  project\ item-add\ *)
    if [ "${GH_MOCK_PROJECT_FAIL:-0}" = "1" ]; then
        echo "error: project attach failed" >&2
        exit 1
    fi
    echo "PVTI_mock_item_id_9999"
    exit 0 ;;
  issue\ view\ *createdAt*)
    if [ "${GH_MOCK_CREATEDAT_EMPTY:-0}" = "1" ]; then
        echo ""; exit 0
    fi
    echo "2026-05-15"
    exit 0 ;;
  project\ item-edit\ *)
    if [ "${GH_MOCK_ITEM_EDIT_FAIL:-0}" = "1" ]; then
        echo "error: item-edit failed" >&2; exit 1
    fi
    exit 0 ;;
  issue\ reopen\ *)
    RNUM=$(echo "$ARGS" | awk '{print $3}')
    eval "RFAIL=\${GH_MOCK_REOPEN_FAIL_${RNUM}:-0}"
    if [ "$RFAIL" = "1" ]; then
        echo "error: cannot reopen issue $RNUM" >&2
        exit 1
    fi
    exit 0 ;;
  api\ repos/*/issues/*\ --jq*)
    # parent-ancestor-reopen.sh: api repos/<owner>/<repo>/issues/<N> --jq .parent.number // empty
    INUM=$(echo "$ARGS" | awk '{print $2}' | awk -F/ '{print $NF}')
    eval "ABSENT=\${GH_MOCK_PARENT_ABSENT_${INUM}:-0}"
    if [ "$ABSENT" = "1" ]; then
        echo ""; exit 0
    fi
    eval "PNUM=\${GH_MOCK_PARENT_NUM_${INUM}:-}"
    echo "$PNUM"
    exit 0 ;;
  issue\ view\ *--json\ id*)
    # Extract issue number from args (positional after "issue view")
    NUM=$(echo "$ARGS" | awk '{print $3}')
    echo "I_kwDOmock${NUM}"
    exit 0 ;;
  api\ graphql\ *databaseId*)
    # Fix #713: dispatch now fetches databaseId via GraphQL API instead of gh issue view.
    # Extract issue number from the query string (issue(number: N)) and return a
    # deterministic integer derived from it. The caller uses --jq so return just the value.
    if [ "${GH_MOCK_GRAPHQL_DBID_FAIL:-0}" = "1" ]; then
        echo "error: graphql request failed" >&2
        exit 1
    fi
    NUM=$(echo "$ARGS" | sed 's/.*issue(number: \([0-9]*\)).*/\1/')
    echo "${NUM}000"
    exit 0 ;;
  issue\ view\ *--json\ state*)
    NUM=$(echo "$ARGS" | awk '{print $3}')
    eval "STATE=\${GH_MOCK_ISSUE_STATE_${NUM}:-OPEN}"
    echo "$STATE"
    exit 0 ;;
  issue\ comment\ *)
    exit 0 ;;
  api\ *-X\ POST*sub_issues*)
    if [ "${GH_MOCK_SUBISSUE_API_FAIL:-0}" = "1" ]; then
      echo "error: sub-issue attach failed" >&2
      exit 1
    fi
    # Opt-in per-attach failure: GH_MOCK_SUBISSUE_FAIL_FROM=N fails the Nth (and
    # later) sub_issues POST while letting earlier ones succeed. File-based cursor
    # counts attaches across the per-call mock processes.
    if [ -n "${GH_MOCK_SUBISSUE_FAIL_FROM:-}" ]; then
      ATTACH_CURSOR="${GH_MOCK_SUBISSUE_CURSOR:-/tmp/gh-mock-subissue-cursor}"
      ACOUNT=0
      [ -f "$ATTACH_CURSOR" ] && ACOUNT=$(cat "$ATTACH_CURSOR")
      ACOUNT=$((ACOUNT + 1))
      echo "$ACOUNT" > "$ATTACH_CURSOR"
      if [ "$ACOUNT" -ge "$GH_MOCK_SUBISSUE_FAIL_FROM" ]; then
        echo "error: sub-issue attach #${ACOUNT} failed" >&2
        exit 1
      fi
    fi
    exit 0 ;;
  repo\ view\ *nameWithOwner*)
    echo "nirecom/agents"
    exit 0 ;;
  repo\ view\ *--json\ owner,name*)
    echo "nirecom/agents"
    exit 0 ;;
  issue\ view\ *--json\ url*)
    NUM=$(echo "$ARGS" | awk '{print $3}')
    echo "https://github.com/nirecom/agents/issues/${NUM}"
    exit 0 ;;
  api\ graphql\ *projectsV2*)
    case "$ARGS" in
      *"| length"*) echo "1"; exit 0 ;;
      *) printf '{"id":"PVT_kwHOAMF_jc4BXf9E","number":1,"ownerLogin":"nirecom"}\n'; exit 0 ;;
    esac ;;
  api\ graphql\ *fields*|api\ graphql\ *projectId*)
    case "$ARGS" in
      *"hasNextPage"*) echo "false"; exit 0 ;;
      *"endCursor"*)   echo ""; exit 0 ;;
      *) echo "PVTF_lAHOAMF_jc4BXf9EzhSsYwA"; exit 0 ;;
    esac ;;
  api\ graphql\ *projectItems*)
    echo ""; exit 0 ;;
  *)
    echo "MOCK GH: no match for args=$ARGS" >&2
    exit 2 ;;
esac
MOCK_EOF
    chmod +x "$TMP/mock-bin/gh"
    export PATH="$TMP/mock-bin:$PATH"
    export GH_MOCK_ARGS_LOG="$TMP/gh-args.log"
    : > "$GH_MOCK_ARGS_LOG"
}

# Canonical body for tests that don't specifically exercise schema validation
# but still pass through the validation block (S2/S4/S5/S6). Tests that exit
# before validation (S3/S7-S11) don't need this.
CANONICAL_BODY="Background: test\nChanges: test"

teardown_mock() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi
    TMP=""
    unset GH_MOCK_ARGS_LOG GH_MOCK_PROJECT_FAIL GH_MOCK_CREATEDAT_EMPTY GH_MOCK_ITEM_EDIT_FAIL 2>/dev/null || true
    unset GH_MOCK_SUBISSUE_API_FAIL GH_MOCK_NEW_ISSUE_NUM GH_MOCK_ISSUE_STATE_42 GH_MOCK_ISSUE_STATE_43 GH_MOCK_ISSUE_STATE_100 2>/dev/null || true
    unset GH_MOCK_PARENT_NUM_200 GH_MOCK_PARENT_ABSENT_100 GH_MOCK_REOPEN_FAIL_100 GH_MOCK_GRAPHQL_DBID_FAIL 2>/dev/null || true
    unset GH_MOCK_ISSUE_NUMS GH_MOCK_CREATE_CURSOR GH_MOCK_SUBISSUE_FAIL_FROM GH_MOCK_SUBISSUE_CURSOR 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# S1: script exists and is executable
# ---------------------------------------------------------------------------
if [ -x "$TARGET" ]; then
    pass "S1: script exists at expected path and is executable"
else
    fail "S1: script exists but is not executable"
fi

# ---------------------------------------------------------------------------
# S2: type:task always applied to gh issue create invocation
# ---------------------------------------------------------------------------
setup_mock
run_with_timeout 30 bash "$TARGET" --title "Test task" --body "$(printf "$CANONICAL_BODY")" >/dev/null 2>&1
RC=$?
if grep -q -- "type:task" "$GH_MOCK_ARGS_LOG" 2>/dev/null; then
    pass "S2: type:task label always applied to gh issue create"
else
    fail "S2: type:task label not found in gh invocation (rc=$RC log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null))"
fi
teardown_mock

# ---------------------------------------------------------------------------
# S3: --label type:* → exit 2, no gh issue create call
# ---------------------------------------------------------------------------
setup_mock
run_with_timeout 30 bash "$TARGET" --title "Test" --body "body" \
    --label "type:incident" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 2 ] && ! grep -q "issue create" "$GH_MOCK_ARGS_LOG" 2>/dev/null; then
    pass "S3: --label type:incident → exit 2, no gh issue create call"
else
    fail "S3: --label type:incident handling incorrect (rc=$RC log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null))"
fi
teardown_mock

# ---------------------------------------------------------------------------
# S4: --label area:hooks (non-type:*) passes through alongside type:task
# ---------------------------------------------------------------------------
setup_mock
run_with_timeout 30 bash "$TARGET" --title "Hooks task" --body "$(printf "$CANONICAL_BODY")" \
    --label "area:hooks" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ] && \
   grep -q "type:task" "$GH_MOCK_ARGS_LOG" 2>/dev/null && \
   grep -q "area:hooks" "$GH_MOCK_ARGS_LOG" 2>/dev/null; then
    pass "S4: non-type:* label passes through alongside type:task"
else
    fail "S4: non-type:* label passthrough incorrect (rc=$RC log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null))"
fi
teardown_mock

# ---------------------------------------------------------------------------
# S5: Projects v2 attach non-fatal — gh project item-add fails → exit 0,
#     stderr warning, stdout has issue URL
# ---------------------------------------------------------------------------
setup_mock
export GH_MOCK_PROJECT_FAIL=1
STDOUT_OUT="$TMP/s5-stdout.txt"
STDERR_OUT="$TMP/s5-stderr.txt"
run_with_timeout 30 bash "$TARGET" --title "Test" --body "$(printf "$CANONICAL_BODY")" \
    >"$STDOUT_OUT" 2>"$STDERR_OUT"
RC=$?
if [ "$RC" -eq 0 ] && \
   grep -qE "https://github.com/.+/issues/[0-9]+" "$STDOUT_OUT" 2>/dev/null && \
   [ -s "$STDERR_OUT" ]; then
    pass "S5: project item-add failure is non-fatal (exit 0, URL on stdout, warning on stderr)"
else
    fail "S5: project item-add non-fatal handling incorrect (rc=$RC stdout=$(cat "$STDOUT_OUT" 2>/dev/null) stderr=$(cat "$STDERR_OUT" 2>/dev/null))"
fi
teardown_mock

# ---------------------------------------------------------------------------
# S6: final stdout line is a parseable GitHub issue URL
# ---------------------------------------------------------------------------
setup_mock
STDOUT_OUT="$TMP/s6-stdout.txt"
run_with_timeout 30 bash "$TARGET" --title "URL test" --body "$(printf "$CANONICAL_BODY")" \
    >"$STDOUT_OUT" 2>/dev/null
LAST_LINE=$(tail -1 "$STDOUT_OUT" 2>/dev/null)
if echo "$LAST_LINE" | grep -qE "https://github.com/.+/issues/[0-9]+"; then
    pass "S6: final stdout line is a parseable GitHub issue URL"
else
    fail "S6: final stdout line is not a GitHub URL (got='$LAST_LINE')"
fi
teardown_mock

# ---------------------------------------------------------------------------
# S7: --title missing → exit 2, stderr contains "--title"
# ---------------------------------------------------------------------------
setup_mock
STDERR_OUT="$TMP/s7-stderr.txt"
run_with_timeout 30 bash "$TARGET" --body "body" >/dev/null 2>"$STDERR_OUT"
RC=$?
if [ "$RC" -eq 2 ] && grep -qi -- "--title" "$STDERR_OUT" 2>/dev/null; then
    pass "S7: missing --title → exit 2, stderr mentions --title"
else
    fail "S7: missing --title handling incorrect (rc=$RC stderr=$(cat "$STDERR_OUT" 2>/dev/null))"
fi
teardown_mock

# ---------------------------------------------------------------------------
# S8: --body and --body-file both missing → exit 2
# ---------------------------------------------------------------------------
setup_mock
run_with_timeout 30 bash "$TARGET" --title "No body" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 2 ]; then
    pass "S8: missing --body and --body-file → exit 2"
else
    fail "S8: missing body should exit 2, got rc=$RC"
fi
teardown_mock

# ---------------------------------------------------------------------------
# S9: --body and --body-file both provided → exit 2 (mutually exclusive)
# ---------------------------------------------------------------------------
setup_mock
echo "file body" > "$TMP/body.txt"
run_with_timeout 30 bash "$TARGET" --title "Conflict" --body "inline" \
    --body-file "$TMP/body.txt" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 2 ]; then
    pass "S9: --body and --body-file together → exit 2"
else
    fail "S9: --body and --body-file together should exit 2, got rc=$RC"
fi
teardown_mock

# ---------------------------------------------------------------------------
# S10: --body-file path does not exist → exit 1
# ---------------------------------------------------------------------------
setup_mock
run_with_timeout 30 bash "$TARGET" --title "Missing file" \
    --body-file "$TMP/nonexistent.txt" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 1 ]; then
    pass "S10: nonexistent --body-file → exit 1"
else
    fail "S10: nonexistent --body-file should exit 1, got rc=$RC"
fi
teardown_mock

# ---------------------------------------------------------------------------
# S11: gh not in PATH → exit 1, stderr contains "gh CLI not found"
# ---------------------------------------------------------------------------
TMPDIR_E5="$(mktemp -d)"
STDERR_OUT="$TMPDIR_E5/s11-stderr.txt"
run_with_timeout 30 env PATH="/bin:/usr/bin" HOME="${HOME:-/root}" \
    bash "$TARGET" --title "No gh" --body "body" >/dev/null 2>"$STDERR_OUT"
RC=$?
if [ "$RC" -eq 1 ] && grep -qiE "gh.*not found|not found.*gh|gh CLI" "$STDERR_OUT" 2>/dev/null; then
    pass "S11: gh not in PATH → exit 1, stderr mentions gh"
else
    fail "S11: gh not in PATH handling incorrect (rc=$RC stderr=$(cat "$STDERR_OUT" 2>/dev/null))"
fi
rm -rf "$TMPDIR_E5"

# ---------------------------------------------------------------------------
# S12: inline Background: + Changes: both present → exit 0
# ---------------------------------------------------------------------------
setup_mock
run_with_timeout 30 bash "$TARGET" --title "Schema ok" \
    --body "$(printf 'Background: bg\nChanges: ch')" >/dev/null 2>/dev/null
RC=$?
if [ "$RC" -eq 0 ]; then
    pass "S12: inline Background: + Changes: present → exit 0"
else
    fail "S12: inline Background: + Changes: should exit 0, got rc=$RC"
fi
teardown_mock

# ---------------------------------------------------------------------------
# S13: Background: only (Changes missing) → exit 3, stderr mentions Changes
# ---------------------------------------------------------------------------
setup_mock
STDERR_OUT="$TMP/s13-stderr.txt"
run_with_timeout 30 bash "$TARGET" --title "Missing Changes" \
    --body "Background: bg" >/dev/null 2>"$STDERR_OUT"
RC=$?
if [ "$RC" -eq 3 ] && grep -qF "Changes" "$STDERR_OUT" 2>/dev/null; then
    pass "S13: Background: only → exit 3, stderr mentions Changes"
else
    fail "S13: Background: only handling incorrect (rc=$RC stderr=$(cat "$STDERR_OUT" 2>/dev/null))"
fi
teardown_mock

# ---------------------------------------------------------------------------
# S14: ## Background H2 + ## Changes H2 → exit 0
# ---------------------------------------------------------------------------
setup_mock
run_with_timeout 30 bash "$TARGET" --title "H2 schema" \
    --body "$(printf '## Background\nbg\n\n## Changes\nch')" >/dev/null 2>/dev/null
RC=$?
if [ "$RC" -eq 0 ]; then
    pass "S14: ## Background + ## Changes H2 → exit 0"
else
    fail "S14: ## Background + ## Changes H2 should exit 0, got rc=$RC"
fi
teardown_mock

# ---------------------------------------------------------------------------
# S15: ### background + ### changes (H3 lowercase) → exit 0
# ---------------------------------------------------------------------------
setup_mock
run_with_timeout 30 bash "$TARGET" --title "H3 lowercase" \
    --body "$(printf '### background\nbg\n\n### changes\nch')" >/dev/null 2>/dev/null
RC=$?
if [ "$RC" -eq 0 ]; then
    pass "S15: ### background + ### changes (H3 lowercase) → exit 0"
else
    fail "S15: ### background + ### changes H3 lowercase should exit 0, got rc=$RC"
fi
teardown_mock

# ---------------------------------------------------------------------------
# S16: no canonical fields → exit 3, stderr contains "Background, Changes" (IFS join regression)
# ---------------------------------------------------------------------------
setup_mock
STDERR_OUT="$TMP/s16-stderr.txt"
run_with_timeout 30 bash "$TARGET" --title "No fields" \
    --body "no fields at all" >/dev/null 2>"$STDERR_OUT"
RC=$?
if [ "$RC" -eq 3 ] && grep -qF "Background, Changes" "$STDERR_OUT" 2>/dev/null; then
    pass "S16: no canonical fields → exit 3, stderr has 'Background, Changes' (IFS join correct)"
else
    fail "S16: no canonical fields handling incorrect (rc=$RC stderr=$(cat "$STDERR_OUT" 2>/dev/null))"
fi
teardown_mock

# ---------------------------------------------------------------------------
# S17: ISSUE_CREATE_SKIP_SCHEMA=1 bypass → exit 0 even with empty body
# ---------------------------------------------------------------------------
setup_mock
export ISSUE_CREATE_SKIP_SCHEMA=1
run_with_timeout 30 bash "$TARGET" --title "Bypass" \
    --body "" >/dev/null 2>/dev/null
unset ISSUE_CREATE_SKIP_SCHEMA
RC=$?
if [ "$RC" -eq 0 ]; then
    pass "S17: ISSUE_CREATE_SKIP_SCHEMA=1 bypass → exit 0 with empty body"
else
    fail "S17: ISSUE_CREATE_SKIP_SCHEMA=1 bypass should exit 0, got rc=$RC"
fi
teardown_mock

# ---------------------------------------------------------------------------
# S18: --body-file with Background only (Changes missing) → exit 3
# ---------------------------------------------------------------------------
setup_mock
BODY_FILE_TMP="$TMP/s18-body.txt"
printf 'Background: bg\n' > "$BODY_FILE_TMP"
STDERR_OUT="$TMP/s18-stderr.txt"
run_with_timeout 30 bash "$TARGET" --title "File missing Changes" \
    --body-file "$BODY_FILE_TMP" >/dev/null 2>"$STDERR_OUT"
RC=$?
if [ "$RC" -eq 3 ] && grep -qF "Changes" "$STDERR_OUT" 2>/dev/null; then
    pass "S18: --body-file with Changes missing → exit 3"
else
    fail "S18: --body-file missing Changes handling incorrect (rc=$RC stderr=$(cat "$STDERR_OUT" 2>/dev/null))"
fi
teardown_mock

# ---------------------------------------------------------------------------
# S19: SKILL.md doc regression — mentions ISSUE_CREATE_SKIP_SCHEMA and exits 3
# ---------------------------------------------------------------------------
if [ ! -f "$SKILL_MD" ]; then
    fail "S19: skills/issue-create/SKILL.md missing"
elif grep -q "ISSUE_CREATE_SKIP_SCHEMA" "$SKILL_MD" && grep -q "exits 3" "$SKILL_MD"; then
    pass "S19: SKILL.md documents ISSUE_CREATE_SKIP_SCHEMA and exits 3"
else
    fail "S19: SKILL.md missing ISSUE_CREATE_SKIP_SCHEMA or 'exits 3' reference"
fi

# ---------------------------------------------------------------------------
# D1: skills/issue-create/SKILL.md exists with name: issue-create and description:
# ---------------------------------------------------------------------------
if [ ! -f "$SKILL_MD" ]; then
    fail "D1: skills/issue-create/SKILL.md missing — RED until implementation"
elif grep -q "^name: issue-create" "$SKILL_MD" && grep -q "^description:" "$SKILL_MD"; then
    pass "D1: SKILL.md has YAML frontmatter with name: issue-create and description:"
else
    fail "D1: SKILL.md exists but missing name: issue-create or description: in frontmatter"
fi

# ---------------------------------------------------------------------------
# D2: SKILL.md mentions the wrapper path bin/github-issues/issue-create.sh
# ---------------------------------------------------------------------------
if [ ! -f "$SKILL_MD" ]; then
    fail "D2: skills/issue-create/SKILL.md missing — RED until implementation"
elif grep -q "bin/github-issues/issue-create.sh" "$SKILL_MD"; then
    pass "D2: SKILL.md references bin/github-issues/issue-create.sh"
else
    fail "D2: SKILL.md does not reference bin/github-issues/issue-create.sh"
fi

# ---------------------------------------------------------------------------
# D3: rules/github-issues.md contains ## Issue creation heading and /issue-create
# ---------------------------------------------------------------------------
if [ ! -f "$RULES_GH" ]; then
    fail "D3: rules/github-issues.md not found"
elif grep -q "^## Issue creation" "$RULES_GH" && grep -q "/issue-create" "$RULES_GH"; then
    pass "D3: rules/github-issues.md has ## Issue creation heading and /issue-create mention"
else
    fail "D3: rules/github-issues.md missing ## Issue creation heading or /issue-create mention — RED until implementation"
fi

# ---------------------------------------------------------------------------
# D4: CLAUDE.md mentions /issue-create
# ---------------------------------------------------------------------------
if [ ! -f "$CLAUDE_MD" ]; then
    fail "D4: CLAUDE.md not found"
elif grep -q "/issue-create" "$CLAUDE_MD"; then
    pass "D4: CLAUDE.md mentions /issue-create"
else
    fail "D4: CLAUDE.md does not mention /issue-create — RED until implementation"
fi

# ---------------------------------------------------------------------------
# T1: Content Date happy path — item-add with --format json, item-edit with right args, no warnings
# ---------------------------------------------------------------------------
setup_mock
STDERR_OUT="$TMP/t1-stderr.txt"
run_with_timeout 30 bash "$TARGET" --title "Date test" --body "$(printf "$CANONICAL_BODY")" >/dev/null 2>"$STDERR_OUT"
RC=$?
if [ "$RC" -eq 0 ] \
   && grep -qE "issue view 9999" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
   && grep -qE "project item-add.*--format json.*--jq|project item-add.*--jq.*--format json" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
   && grep -q "project item-edit" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
   && grep -q -- "--date 2026-05-15" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
   && grep -q -- "--field-id PVTF_lAHOAMF_jc4BXf9EzhSsYwA" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
   && grep -q -- "--project-id PVT_kwHOAMF_jc4BXf9E" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
   && ! grep -qi "warn:" "$STDERR_OUT" 2>/dev/null; then
    pass "T1: Content Date set: correct issue#, --format json in item-add, right date/ids, no warnings"
else
    fail "T1: Content Date happy-path incorrect (rc=$RC log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null) stderr=$(cat "$STDERR_OUT" 2>/dev/null))"
fi
teardown_mock

# ---------------------------------------------------------------------------
# T2: createdAt fetch fails → item-edit skipped, non-fatal (exit 0)
# ---------------------------------------------------------------------------
setup_mock
export GH_MOCK_CREATEDAT_EMPTY=1
STDERR_OUT="$TMP/t2-stderr.txt"
run_with_timeout 30 bash "$TARGET" --title "No createdAt" --body "$(printf "$CANONICAL_BODY")" >/dev/null 2>"$STDERR_OUT"
RC=$?
if [ "$RC" -eq 0 ] \
   && ! grep -q "project item-edit" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
   && grep -qiE "failed to fetch createdAt|empty createdAt" "$STDERR_OUT" 2>/dev/null; then
    pass "T2: createdAt failure skips item-edit (non-fatal)"
else
    fail "T2: createdAt failure handling incorrect (rc=$RC stderr=$(cat "$STDERR_OUT" 2>/dev/null))"
fi
teardown_mock

# ---------------------------------------------------------------------------
# T3: item-edit fails → non-fatal (exit 0, URL on stdout, warning on stderr)
# ---------------------------------------------------------------------------
setup_mock
export GH_MOCK_ITEM_EDIT_FAIL=1
STDOUT_OUT="$TMP/t3-stdout.txt"
STDERR_OUT="$TMP/t3-stderr.txt"
run_with_timeout 30 bash "$TARGET" --title "Edit fail" --body "$(printf "$CANONICAL_BODY")" >"$STDOUT_OUT" 2>"$STDERR_OUT"
RC=$?
if [ "$RC" -eq 0 ] \
   && grep -qE "https://github.com/.+/issues/[0-9]+" "$STDOUT_OUT" 2>/dev/null \
   && grep -qiE "failed to set Content Date|Content Date set failed" "$STDERR_OUT" 2>/dev/null; then
    pass "T3: item-edit failure is non-fatal (exit 0, URL on stdout, warning on stderr)"
else
    fail "T3: item-edit non-fatal handling incorrect (rc=$RC stderr=$(cat "$STDERR_OUT" 2>/dev/null))"
fi
teardown_mock

# ---------------------------------------------------------------------------
# T4: _ISSUE_CREATE_INTERNAL_* env-var overrides honored (short-circuit path)
# ---------------------------------------------------------------------------
setup_mock
export _ISSUE_CREATE_INTERNAL_OWNER=nirecom
export _ISSUE_CREATE_INTERNAL_PROJECT_NUM=1
export _ISSUE_CREATE_INTERNAL_PROJECT_ID=PVT_override_project
export _ISSUE_CREATE_INTERNAL_FIELD_ID=PVTF_override_field
run_with_timeout 30 bash "$TARGET" --title "Override" --body "$(printf "$CANONICAL_BODY")" >/dev/null 2>/dev/null
RC=$?
if [ "$RC" -eq 0 ] \
   && grep -q -- "--field-id PVTF_override_field" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
   && grep -q -- "--project-id PVT_override_project" "$GH_MOCK_ARGS_LOG" 2>/dev/null; then
    pass "T4: _ISSUE_CREATE_INTERNAL_* env-var overrides honored (short-circuit path)"
else
    fail "T4: env-var override not honored (rc=$RC log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null))"
fi
unset _ISSUE_CREATE_INTERNAL_OWNER _ISSUE_CREATE_INTERNAL_PROJECT_NUM _ISSUE_CREATE_INTERNAL_PROJECT_ID _ISSUE_CREATE_INTERNAL_FIELD_ID
teardown_mock

# ---------------------------------------------------------------------------
# DV1: verdict=none → exactly one `gh issue create`, no extra API calls
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV1: dispatch script missing — RED until implementation"
else
    setup_mock
    STDOUT_OUT="$TMP/dv1-stdout.txt"
    run_with_timeout 30 bash "$DISPATCH" --verdict none -- --title "T" --body "$(printf "$CANONICAL_BODY")" >"$STDOUT_OUT" 2>/dev/null
    RC=$?
    CREATE_COUNT=$(grep -c "issue create" "$GH_MOCK_ARGS_LOG" 2>/dev/null || echo 0)
    LAST_LINE=$(tail -1 "$STDOUT_OUT" 2>/dev/null)
    if [ "$RC" -eq 0 ] \
       && [ "$CREATE_COUNT" -eq 1 ] \
       && ! grep -q "issue reopen" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && ! grep -q "sub_issues" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && echo "$LAST_LINE" | grep -qE "https://github.com/.+/issues/[0-9]+"; then
        pass "DV1: verdict=none → exactly one gh issue create, no extra API calls"
    else
        fail "DV1: verdict=none behavior incorrect (rc=$RC create_count=$CREATE_COUNT stdout='$LAST_LINE' log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null))"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# DV2: verdict=reopen --target 42 → `gh issue reopen 42`, no `gh issue create`
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV2: dispatch script missing — RED until implementation"
else
    setup_mock
    STDOUT_OUT="$TMP/dv2-stdout.txt"
    run_with_timeout 30 bash "$DISPATCH" --verdict reopen --target 42 >"$STDOUT_OUT" 2>/dev/null
    RC=$?
    LAST_LINE=$(tail -1 "$STDOUT_OUT" 2>/dev/null)
    if [ "$RC" -eq 0 ] \
       && grep -q "issue reopen 42" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && ! grep -q "issue create" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && [ "$LAST_LINE" = "https://github.com/nirecom/agents/issues/42" ]; then
        pass "DV2: verdict=reopen --target 42 → reopen called, stdout=URL of #42"
    else
        fail "DV2: verdict=reopen behavior incorrect (rc=$RC stdout='$LAST_LINE' log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null))"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# DV3: verdict=sibling --related 42 → body contains `Related to #42`
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV3: dispatch script missing — RED until implementation"
else
    setup_mock
    STDOUT_OUT="$TMP/dv3-stdout.txt"
    run_with_timeout 30 bash "$DISPATCH" --verdict sibling --related 42 -- --title "T" --body "$(printf 'Background: Original\nChanges: test')" >"$STDOUT_OUT" 2>/dev/null
    RC=$?
    LAST_LINE=$(tail -1 "$STDOUT_OUT" 2>/dev/null)
    # Body suffix is injected with a real newline, so check the whole args log (multi-line).
    if [ "$RC" -eq 0 ] \
       && grep -q "issue create" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && grep -q "Original" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && grep -q "Related to #42" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && echo "$LAST_LINE" | grep -qE "https://github.com/.+/issues/[0-9]+"; then
        pass "DV3: verdict=sibling --related 42 → body augmented with Related to #42"
    else
        fail "DV3: verdict=sibling behavior incorrect (rc=$RC stdout='$LAST_LINE' log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null))"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# DV4: verdict=sub-of --parent 100 → fetches CHILD id (not parent), attaches via API
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV4: dispatch script missing — RED until implementation"
else
    setup_mock
    export GH_MOCK_NEW_ISSUE_NUM=200
    STDOUT_OUT="$TMP/dv4-stdout.txt"
    run_with_timeout 30 bash "$DISPATCH" --verdict sub-of --parent 100 -- --title "T" --body "$(printf "$CANONICAL_BODY")" >"$STDOUT_OUT" 2>/dev/null
    RC=$?
    LAST_LINE=$(tail -1 "$STDOUT_OUT" 2>/dev/null)
    if [ "$RC" -eq 0 ] \
       && grep -q "api graphql" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && grep -q "issue(number: 200)" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && grep -q "repos/nirecom/agents/issues/100/sub_issues" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && grep -q "sub_issue_id=200000" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && echo "$LAST_LINE" | grep -q "/issues/200$"; then
        pass "DV4: verdict=sub-of --parent 100 → child databaseId fetched via GraphQL and attached"
    else
        fail "DV4: verdict=sub-of behavior incorrect (rc=$RC stdout='$LAST_LINE' log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null))"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# DV5: verdict=make-parent --children 42,43 → fetches BOTH child ids and attaches each
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV5: dispatch script missing — RED until implementation"
else
    setup_mock
    export GH_MOCK_NEW_ISSUE_NUM=201
    STDOUT_OUT="$TMP/dv5-stdout.txt"
    run_with_timeout 30 bash "$DISPATCH" --verdict make-parent --children 42,43 -- --title "T" --body "$(printf "$CANONICAL_BODY")" >"$STDOUT_OUT" 2>/dev/null
    RC=$?
    LAST_LINE=$(tail -1 "$STDOUT_OUT" 2>/dev/null)
    ATTACH_201_COUNT=$(grep -c "repos/nirecom/agents/issues/201/sub_issues" "$GH_MOCK_ARGS_LOG" 2>/dev/null || echo 0)
    # Fix #713: make-parent fetches databaseId via GraphQL (api graphql) instead of
    # gh issue view --json databaseId. Mock returns "${NUM}000" for issue(number: N),
    # so child 42 → 42000 and child 43 → 43000.
    if [ "$RC" -eq 0 ] \
       && grep -q "issue(number: 42)" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && grep -q "issue(number: 43)" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && grep -q -- "-F sub_issue_id=42000" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && grep -q -- "-F sub_issue_id=43000" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && [ "$ATTACH_201_COUNT" -ge 2 ] \
       && [ "$LAST_LINE" = "https://github.com/nirecom/agents/issues/201" ]; then
        pass "DV5: verdict=make-parent --children 42,43 → both children attached under new parent 201 with -F sub_issue_id=<integer>"
    else
        fail "DV5: verdict=make-parent behavior incorrect (rc=$RC stdout='$LAST_LINE' attach_201_count=$ATTACH_201_COUNT log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null))"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# DV6: sub-of with sub-issue API failure → non-zero exit (structural failure)
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV6: dispatch script missing — RED until implementation"
else
    setup_mock
    export GH_MOCK_SUBISSUE_API_FAIL=1
    export GH_MOCK_NEW_ISSUE_NUM=202
    run_with_timeout 30 bash "$DISPATCH" --verdict sub-of --parent 100 -- --title "T" --body "$(printf "$CANONICAL_BODY")" >/dev/null 2>/dev/null
    RC=$?
    if [ "$RC" -ne 0 ]; then
        pass "DV6: sub-of + sub-issue API failure → non-zero exit"
    else
        fail "DV6: sub-of + sub-issue API failure should exit non-zero, got rc=$RC"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# DV-graphql-fail: GH_MOCK_GRAPHQL_DBID_FAIL=1 → gh api graphql returns non-zero → dispatch exits non-zero
# Fix #713: get_child_database_id() uses api graphql; a GraphQL failure must propagate as a non-zero exit.
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV-graphql-fail: dispatch script missing — RED until implementation"
else
    setup_mock
    export GH_MOCK_GRAPHQL_DBID_FAIL=1
    export GH_MOCK_NEW_ISSUE_NUM=200
    run_with_timeout 30 bash "$DISPATCH" --verdict sub-of --parent 100 -- --title "T" --body "$(printf "$CANONICAL_BODY")" >/dev/null 2>/dev/null
    RC=$?
    if [ "$RC" -ne 0 ]; then
        pass "DV-graphql-fail: gh api graphql databaseId failure → dispatch exits non-zero"
    else
        fail "DV-graphql-fail: gh api graphql failure should propagate as non-zero exit, got rc=$RC"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# DV7: SKILL.md references `is-github-dotcom-remote`
# ---------------------------------------------------------------------------
if [ ! -f "$SKILL_MD" ]; then
    fail "DV7: skills/issue-create/SKILL.md missing — RED until implementation"
elif grep -q "is-github-dotcom-remote" "$SKILL_MD"; then
    pass "DV7: SKILL.md references is-github-dotcom-remote"
else
    fail "DV7: SKILL.md does not reference is-github-dotcom-remote — RED until implementation"
fi

# ---------------------------------------------------------------------------
# DV8: Sub-issue API call shape — `api -X POST` + sub_issues path + -F sub_issue_id=<integer>
# Fix #432: sub_issue_id must be passed via -F (numeric) using the child's
# databaseId integer, not -f (string) with the GraphQL node id.
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV8: dispatch script missing — RED until implementation"
else
    setup_mock
    export GH_MOCK_NEW_ISSUE_NUM=200
    run_with_timeout 30 bash "$DISPATCH" --verdict sub-of --parent 100 -- --title "T" --body "$(printf "$CANONICAL_BODY")" >/dev/null 2>/dev/null
    RC=$?
    if [ "$RC" -eq 0 ] \
       && grep -q "api .*-X POST" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && grep -q "repos/nirecom/agents/issues/100/sub_issues" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && grep -q "api graphql" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && grep -q "issue(number: 200)" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && grep -qE -- "-F sub_issue_id=[0-9]+" "$GH_MOCK_ARGS_LOG" 2>/dev/null; then
        pass "DV8: sub-issue API call has correct shape (api graphql databaseId, api -X POST, sub_issues path, -F sub_issue_id=<integer>)"
    else
        fail "DV8: sub-issue API call shape incorrect (rc=$RC log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null))"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# DV9: verdict=reopen without --target → exit 2
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV9: dispatch script missing — RED until implementation"
else
    setup_mock
    run_with_timeout 30 bash "$DISPATCH" --verdict reopen >/dev/null 2>/dev/null
    RC=$?
    if [ "$RC" -eq 2 ]; then
        pass "DV9: verdict=reopen without --target → exit 2"
    else
        fail "DV9: verdict=reopen without --target should exit 2, got rc=$RC"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# D5: SKILL.md references bin/github-issues/issue-create-dispatch.sh
# ---------------------------------------------------------------------------
if [ ! -f "$SKILL_MD" ]; then
    fail "D5: skills/issue-create/SKILL.md missing — RED until implementation"
elif grep -q "issue-create-dispatch.sh" "$SKILL_MD"; then
    pass "D5: SKILL.md references bin/github-issues/issue-create-dispatch.sh"
else
    fail "D5: SKILL.md does not reference issue-create-dispatch.sh — RED until implementation"
fi

# ---------------------------------------------------------------------------
# D6: SKILL.md contains "Survey", "Verdict", AND "Confirm" (case-insensitive)
# ---------------------------------------------------------------------------
if [ ! -f "$SKILL_MD" ]; then
    fail "D6: skills/issue-create/SKILL.md missing — RED until implementation"
elif grep -qi "survey" "$SKILL_MD" && grep -qi "verdict" "$SKILL_MD" && grep -qi "confirm" "$SKILL_MD"; then
    pass "D6: SKILL.md contains Survey, Verdict, and Confirm (case-insensitive)"
else
    fail "D6: SKILL.md missing one of Survey/Verdict/Confirm — RED until implementation"
fi

# ---------------------------------------------------------------------------
# DV10: sub-of + parent CLOSED → ancestor reopen called, stdout last line = URL
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV10: dispatch script missing — RED until implementation"
else
    setup_mock
    export GH_MOCK_NEW_ISSUE_NUM=200
    export GH_MOCK_PARENT_NUM_200=100
    export GH_MOCK_ISSUE_STATE_100=CLOSED
    STDOUT_OUT="$TMP/dv10-stdout.txt"
    run_with_timeout 30 bash "$DISPATCH" --verdict sub-of --parent 100 -- --title "T" --body "$(printf "$CANONICAL_BODY")" >"$STDOUT_OUT" 2>/dev/null
    RC=$?
    LAST_LINE=$(tail -1 "$STDOUT_OUT" 2>/dev/null)
    if [ "$RC" -eq 0 ] \
       && grep -q "issue reopen 100" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && echo "$LAST_LINE" | grep -q "/issues/200$"; then
        pass "DV10: sub-of parent CLOSED → ancestor reopen called, stdout last line = URL"
    else
        fail "DV10: sub-of parent CLOSED expected reopen + URL (rc=$RC last='$LAST_LINE' log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null))"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# DV11: sub-of + parent OPEN → reopen NOT called, stdout last line = URL
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV11: dispatch script missing — RED until implementation"
else
    setup_mock
    export GH_MOCK_NEW_ISSUE_NUM=200
    export GH_MOCK_PARENT_NUM_200=100
    export GH_MOCK_ISSUE_STATE_100=OPEN
    STDOUT_OUT="$TMP/dv11-stdout.txt"
    run_with_timeout 30 bash "$DISPATCH" --verdict sub-of --parent 100 -- --title "T" --body "$(printf "$CANONICAL_BODY")" >"$STDOUT_OUT" 2>/dev/null
    RC=$?
    LAST_LINE=$(tail -1 "$STDOUT_OUT" 2>/dev/null)
    if [ "$RC" -eq 0 ] \
       && ! grep -q "issue reopen" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && echo "$LAST_LINE" | grep -q "/issues/200$"; then
        pass "DV11: sub-of parent OPEN → no reopen, stdout last line = URL"
    else
        fail "DV11: sub-of parent OPEN should skip reopen (rc=$RC last='$LAST_LINE' log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null))"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# DV12: sub-of + REOPEN_FAIL_100 → dispatch exit 0, WARN to stderr, stdout last line = URL
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV12: dispatch script missing — RED until implementation"
else
    setup_mock
    export GH_MOCK_NEW_ISSUE_NUM=200
    export GH_MOCK_PARENT_NUM_200=100
    export GH_MOCK_ISSUE_STATE_100=CLOSED
    export GH_MOCK_REOPEN_FAIL_100=1
    STDOUT_OUT="$TMP/dv12-stdout.txt"
    STDERR_OUT="$TMP/dv12-stderr.txt"
    run_with_timeout 30 bash "$DISPATCH" --verdict sub-of --parent 100 -- --title "T" --body "$(printf "$CANONICAL_BODY")" >"$STDOUT_OUT" 2>"$STDERR_OUT"
    RC=$?
    LAST_LINE=$(tail -1 "$STDOUT_OUT" 2>/dev/null)
    if [ "$RC" -eq 0 ] \
       && grep -qi "warn" "$STDERR_OUT" 2>/dev/null \
       && echo "$LAST_LINE" | grep -q "/issues/200$"; then
        pass "DV12: reopen failure non-fatal → exit 0, WARN to stderr, URL on stdout"
    else
        fail "DV12: reopen failure should be non-fatal (rc=$RC last='$LAST_LINE' stderr=$(cat "$STDERR_OUT" 2>/dev/null))"
    fi
    teardown_mock
fi

# ===========================================================================
# DV-BULK series (#1155): verdict=bulk-sub-of — create N children from a TSV
# manifest and attach each under --parent. Multi-URL stdout, manifest order.
#
# These exercise the dispatch arm that does not yet exist on the current code,
# so DV-BULK1/2 are RED until implementation; DV-BULK3/4/5 (usage errors) and
# the DOC cases are RED until the verdict/whitelist/docs land.
# ===========================================================================

# ---------------------------------------------------------------------------
# DV-BULK1: --parent 100 --manifest <2-line TSV> → 2 issue create + 2 sub_issues
#           POST to parent 100, exit 0, stdout has exactly 2 URLs in manifest order
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV-BULK1: dispatch script missing — RED until implementation"
else
    setup_mock
    export GH_MOCK_ISSUE_NUMS="300,301"
    export GH_MOCK_CREATE_CURSOR="$TMP/create-cursor"
    MANIFEST="$TMP/bulk1-manifest.tsv"
    printf 'First child\tBackground: a\\nChanges: a\n' >  "$MANIFEST"
    printf 'Second child\tBackground: b\\nChanges: b\n' >> "$MANIFEST"
    STDOUT_OUT="$TMP/dvbulk1-stdout.txt"
    run_with_timeout 30 bash "$DISPATCH" --verdict bulk-sub-of --parent 100 --manifest "$MANIFEST" >"$STDOUT_OUT" 2>/dev/null
    RC=$?
    CREATE_COUNT=$(grep -c "issue create" "$GH_MOCK_ARGS_LOG" 2>/dev/null || echo 0)
    ATTACH_COUNT=$(grep -c "repos/nirecom/agents/issues/100/sub_issues" "$GH_MOCK_ARGS_LOG" 2>/dev/null || echo 0)
    URLS=$(grep -E "^https://github.com/.+/issues/[0-9]+$" "$STDOUT_OUT" 2>/dev/null | tr -d '\r')
    URL_COUNT=$(printf '%s\n' "$URLS" | grep -c . )
    ORDER=$(printf '%s\n' "$URLS" | grep -oE '[0-9]+$' | paste -sd, -)
    if [ "$RC" -eq 0 ] \
       && [ "$CREATE_COUNT" -eq 2 ] \
       && [ "$ATTACH_COUNT" -eq 2 ] \
       && [ "$URL_COUNT" -eq 2 ] \
       && [ "$ORDER" = "300,301" ]; then
        pass "DV-BULK1: 2-child manifest → 2 creates + 2 attaches to #100, 2 URLs in order (300,301)"
    else
        fail "DV-BULK1: rc=$RC creates=$CREATE_COUNT attaches=$ATTACH_COUNT urls=$URL_COUNT order='$ORDER' log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# DV-BULK2: same manifest but 2nd attach fails → exit 1, 1st URL still on stdout,
#           stderr has retry info
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV-BULK2: dispatch script missing — RED until implementation"
else
    setup_mock
    export GH_MOCK_ISSUE_NUMS="400,401"
    export GH_MOCK_CREATE_CURSOR="$TMP/create-cursor"
    export GH_MOCK_SUBISSUE_FAIL_FROM=2
    export GH_MOCK_SUBISSUE_CURSOR="$TMP/subissue-cursor"
    MANIFEST="$TMP/bulk2-manifest.tsv"
    printf 'First child\tBackground: a\\nChanges: a\n' >  "$MANIFEST"
    printf 'Second child\tBackground: b\\nChanges: b\n' >> "$MANIFEST"
    STDOUT_OUT="$TMP/dvbulk2-stdout.txt"
    STDERR_OUT="$TMP/dvbulk2-stderr.txt"
    run_with_timeout 30 bash "$DISPATCH" --verdict bulk-sub-of --parent 100 --manifest "$MANIFEST" >"$STDOUT_OUT" 2>"$STDERR_OUT"
    RC=$?
    if [ "$RC" -eq 1 ] \
       && grep -qE "^https://github.com/.+/issues/400$" "$STDOUT_OUT" 2>/dev/null \
       && grep -qiE "retry|sub_issue_id|sub_issues" "$STDERR_OUT" 2>/dev/null; then
        pass "DV-BULK2: 2nd attach fails → exit 1, 1st URL on stdout, retry info on stderr"
    else
        fail "DV-BULK2: rc=$RC stdout=$(cat "$STDOUT_OUT" 2>/dev/null) stderr=$(cat "$STDERR_OUT" 2>/dev/null)"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# DV-BULK3: --verdict bulk-sub-of without --manifest → exit 2
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV-BULK3: dispatch script missing — RED until implementation"
else
    setup_mock
    run_with_timeout 30 bash "$DISPATCH" --verdict bulk-sub-of --parent 100 >/dev/null 2>/dev/null
    RC=$?
    if [ "$RC" -eq 2 ]; then
        pass "DV-BULK3: bulk-sub-of without --manifest → exit 2"
    else
        fail "DV-BULK3: bulk-sub-of without --manifest should exit 2, got rc=$RC"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# DV-BULK4: --verdict bulk-sub-of without --parent → exit 2
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV-BULK4: dispatch script missing — RED until implementation"
else
    setup_mock
    MANIFEST="$TMP/bulk4-manifest.tsv"
    printf 'Only child\tBackground: a\\nChanges: a\n' > "$MANIFEST"
    run_with_timeout 30 bash "$DISPATCH" --verdict bulk-sub-of --manifest "$MANIFEST" >/dev/null 2>/dev/null
    RC=$?
    if [ "$RC" -eq 2 ]; then
        pass "DV-BULK4: bulk-sub-of without --parent → exit 2"
    else
        fail "DV-BULK4: bulk-sub-of without --parent should exit 2, got rc=$RC"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# DV-BULK5: --parent 100 --manifest <empty file> → exit 2
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV-BULK5: dispatch script missing — RED until implementation"
else
    setup_mock
    MANIFEST="$TMP/bulk5-empty.tsv"
    : > "$MANIFEST"
    run_with_timeout 30 bash "$DISPATCH" --verdict bulk-sub-of --parent 100 --manifest "$MANIFEST" >/dev/null 2>/dev/null
    RC=$?
    if [ "$RC" -eq 2 ]; then
        pass "DV-BULK5: bulk-sub-of with empty manifest → exit 2"
    else
        fail "DV-BULK5: bulk-sub-of with empty manifest should exit 2, got rc=$RC"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# DV-BULK-EDGE1: manifest with empty-title row in the middle → skipped,
#                CREATE_COUNT=2, ATTACH_COUNT=2, 2 URLs on stdout
#
# Note: bash `read` with IFS=$'\t' strips leading IFS chars, so a row of
# "\t<body>" would assign <body> to title. An empty line ("\n") or a
# tab-only line ("\t\n") reliably produces title="" which the [[ -z ]] check
# catches and skips.
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV-BULK-EDGE1: dispatch script missing — RED until implementation"
else
    setup_mock
    export GH_MOCK_ISSUE_NUMS="300,301"
    export GH_MOCK_CREATE_CURSOR="$TMP/create-cursor"
    MANIFEST="$TMP/bulk-edge1-manifest.tsv"
    printf 'First child\tBackground: a\\nChanges: a\n' >  "$MANIFEST"
    printf '\n'                                           >> "$MANIFEST"
    printf 'Third child\tBackground: c\\nChanges: c\n'  >> "$MANIFEST"
    STDOUT_OUT="$TMP/dvbulk-edge1-stdout.txt"
    run_with_timeout 30 bash "$DISPATCH" --verdict bulk-sub-of --parent 100 --manifest "$MANIFEST" >"$STDOUT_OUT" 2>/dev/null
    RC=$?
    CREATE_COUNT=$(grep -c "issue create" "$GH_MOCK_ARGS_LOG" 2>/dev/null || echo 0)
    ATTACH_COUNT=$(grep -c "repos/nirecom/agents/issues/100/sub_issues" "$GH_MOCK_ARGS_LOG" 2>/dev/null || echo 0)
    URLS=$(grep -E "^https://github.com/.+/issues/[0-9]+$" "$STDOUT_OUT" 2>/dev/null | tr -d '\r')
    URL_COUNT=$(printf '%s\n' "$URLS" | grep -c . )
    if [ "$RC" -eq 0 ] \
       && [ "$CREATE_COUNT" -eq 2 ] \
       && [ "$ATTACH_COUNT" -eq 2 ] \
       && [ "$URL_COUNT" -eq 2 ]; then
        pass "DV-BULK-EDGE1: empty-title row skipped → 2 creates, 2 attaches, 2 URLs"
    else
        fail "DV-BULK-EDGE1: rc=$RC creates=$CREATE_COUNT attaches=$ATTACH_COUNT urls=$URL_COUNT log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# DV-BULK-EDGE2: manifest with trailing newline → CREATE_COUNT=2 (not 3)
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV-BULK-EDGE2: dispatch script missing — RED until implementation"
else
    setup_mock
    export GH_MOCK_ISSUE_NUMS="300,301"
    export GH_MOCK_CREATE_CURSOR="$TMP/create-cursor"
    MANIFEST="$TMP/bulk-edge2-manifest.tsv"
    printf 'First child\tBackground: a\\nChanges: a\nSecond child\tBackground: b\\nChanges: b\n' > "$MANIFEST"
    STDOUT_OUT="$TMP/dvbulk-edge2-stdout.txt"
    run_with_timeout 30 bash "$DISPATCH" --verdict bulk-sub-of --parent 100 --manifest "$MANIFEST" >"$STDOUT_OUT" 2>/dev/null
    RC=$?
    CREATE_COUNT=$(grep -c "issue create" "$GH_MOCK_ARGS_LOG" 2>/dev/null || echo 0)
    ATTACH_COUNT=$(grep -c "repos/nirecom/agents/issues/100/sub_issues" "$GH_MOCK_ARGS_LOG" 2>/dev/null || echo 0)
    URLS=$(grep -E "^https://github.com/.+/issues/[0-9]+$" "$STDOUT_OUT" 2>/dev/null | tr -d '\r')
    URL_COUNT=$(printf '%s\n' "$URLS" | grep -c . )
    if [ "$RC" -eq 0 ] \
       && [ "$CREATE_COUNT" -eq 2 ] \
       && [ "$ATTACH_COUNT" -eq 2 ] \
       && [ "$URL_COUNT" -eq 2 ]; then
        pass "DV-BULK-EDGE2: trailing newline not counted as extra row → 2 creates, 2 attaches, 2 URLs"
    else
        fail "DV-BULK-EDGE2: rc=$RC creates=$CREATE_COUNT attaches=$ATTACH_COUNT urls=$URL_COUNT log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# DV-BULK-EDGE3: title/body with shell metacharacters → passed safely
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV-BULK-EDGE3: dispatch script missing — RED until implementation"
else
    setup_mock
    export GH_MOCK_ISSUE_NUMS="300"
    export GH_MOCK_CREATE_CURSOR="$TMP/create-cursor"
    MANIFEST="$TMP/bulk-edge3-manifest.tsv"
    # Title contains $HOME, double-quotes, and backticks; body contains $VAR and quotes
    printf 'Test $HOME "quoted" `backtick` value\tBackground: test with $VAR and "quotes"\\nChanges: done\n' > "$MANIFEST"
    STDOUT_OUT="$TMP/dvbulk-edge3-stdout.txt"
    run_with_timeout 30 bash "$DISPATCH" --verdict bulk-sub-of --parent 100 --manifest "$MANIFEST" >"$STDOUT_OUT" 2>/dev/null
    RC=$?
    CREATE_COUNT=$(grep -c "issue create" "$GH_MOCK_ARGS_LOG" 2>/dev/null || echo 0)
    ATTACH_COUNT=$(grep -c "repos/nirecom/agents/issues/100/sub_issues" "$GH_MOCK_ARGS_LOG" 2>/dev/null || echo 0)
    URLS=$(grep -E "^https://github.com/.+/issues/[0-9]+$" "$STDOUT_OUT" 2>/dev/null | tr -d '\r')
    URL_COUNT=$(printf '%s\n' "$URLS" | grep -c . )
    if [ "$RC" -eq 0 ] \
       && [ "$CREATE_COUNT" -eq 1 ] \
       && [ "$ATTACH_COUNT" -eq 1 ] \
       && [ "$URL_COUNT" -eq 1 ]; then
        pass "DV-BULK-EDGE3: metacharacters in title/body passed safely → 1 create, 1 attach, 1 URL"
    else
        fail "DV-BULK-EDGE3: rc=$RC creates=$CREATE_COUNT attaches=$ATTACH_COUNT urls=$URL_COUNT log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# DV-BULK-DOC1: skills/issue-create/SKILL.md contains skip-survey reference
# ---------------------------------------------------------------------------
if [ ! -f "$SKILL_MD" ]; then
    fail "DV-BULK-DOC1: skills/issue-create/SKILL.md missing — RED until implementation"
elif grep -q "skip-survey" "$SKILL_MD"; then
    pass "DV-BULK-DOC1: SKILL.md references skip-survey"
else
    fail "DV-BULK-DOC1: SKILL.md does not reference skip-survey — RED until implementation"
fi

# ---------------------------------------------------------------------------
# DV-BULK-DOC2: skills/issue-create/SKILL.md contains bulk-sub-of
# ---------------------------------------------------------------------------
if [ ! -f "$SKILL_MD" ]; then
    fail "DV-BULK-DOC2: skills/issue-create/SKILL.md missing — RED until implementation"
elif grep -q "bulk-sub-of" "$SKILL_MD"; then
    pass "DV-BULK-DOC2: SKILL.md references bulk-sub-of"
else
    fail "DV-BULK-DOC2: SKILL.md does not reference bulk-sub-of — RED until implementation"
fi

# ---------------------------------------------------------------------------
# WF-META-DOC1: skills/workflow-init/SKILL.md PM path contains a sub-issue
#               creation mandate. The mandate must signal sub-issue/bulk creation
#               or "全件" coverage — bare "PM4" already exists for an unrelated
#               outline step, so it alone must NOT satisfy this check.
# ---------------------------------------------------------------------------
if [ ! -f "$WORKFLOW_INIT_MD" ]; then
    fail "WF-META-DOC1: skills/workflow-init/SKILL.md missing"
elif grep -qE "bulk|sub-issue|全件" "$WORKFLOW_INIT_MD"; then
    pass "WF-META-DOC1: workflow-init SKILL.md PM path has sub-issue creation mandate"
else
    fail "WF-META-DOC1: workflow-init SKILL.md missing sub-issue creation mandate — RED until implementation"
fi

# ---------------------------------------------------------------------------
# F-622-1: SKILL.md mentions worktree-notes-append.js in Phase 5
# ---------------------------------------------------------------------------
if [ ! -f "$SKILL_MD" ]; then
    fail "F-622-1: SKILL.md missing"
elif grep -q "worktree-notes-append.js" "$SKILL_MD"; then
    pass "F-622-1: SKILL.md mentions worktree-notes-append.js"
else
    fail "F-622-1: SKILL.md does not mention worktree-notes-append.js — RED until Phase 5 is added"
fi

# ---------------------------------------------------------------------------
# F-622-2: SKILL.md Phase 5 contains non-fatal behavior note
# ---------------------------------------------------------------------------
if [ ! -f "$SKILL_MD" ]; then
    fail "F-622-2: SKILL.md missing"
elif grep -qiE "non.fatal|non fatal|nonfatal" "$SKILL_MD"; then
    pass "F-622-2: SKILL.md Phase 5 contains non-fatal directive"
else
    fail "F-622-2: SKILL.md missing non-fatal directive — RED until Phase 5 is added"
fi

# ---------------------------------------------------------------------------
# F-622-3: SKILL.md Phase 5 mentions --skip-if-main flag
# ---------------------------------------------------------------------------
if [ ! -f "$SKILL_MD" ]; then
    fail "F-622-3: SKILL.md missing"
elif grep -q -- "--skip-if-main" "$SKILL_MD"; then
    pass "F-622-3: SKILL.md Phase 5 mentions --skip-if-main"
else
    fail "F-622-3: SKILL.md does not mention --skip-if-main — RED until Phase 5 is added"
fi

# ---------------------------------------------------------------------------
# R1 (#641): resolver fires when ISSUE_CREATE_* env unset
# Mock gh repo view + gh api graphql to simulate the auto-resolve path.
# item-add must be called with the RESOLVED owner/project_num (not hardcoded).
# ---------------------------------------------------------------------------
setup_mock
# Augment the mock with repo view --json owner,name + api graphql projectsV2 + fields.
# Overwrite mock gh to add the new branches (preserve existing behaviors).
cat > "$TMP/mock-bin/gh" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
if [ -n "${GH_MOCK_ARGS_LOG:-}" ]; then
    printf '%s\n' "$ARGS" >> "$GH_MOCK_ARGS_LOG"
fi
case "$ARGS" in
  auth\ status*)
    echo "Token scopes: 'gist', 'project', 'read:org', 'repo'"
    exit 0 ;;
  repo\ view\ *--json\ owner,name*)
    echo "${GH_MOCK_OWNER_REPO:-nirecom/agents}"
    exit 0 ;;
  repo\ view\ *nameWithOwner*)
    echo "nirecom/agents"
    exit 0 ;;
  api\ graphql\ *projectsV2*)
    if [ "${GH_MOCK_GRAPHQL_RESOLVER_FAIL:-0}" = "1" ]; then
        case "$ARGS" in
          *"| length"*) echo "0"; exit 0 ;;
          *) echo ""; exit 0 ;;
        esac
    fi
    case "$ARGS" in
      *"| length"*) echo "${GH_MOCK_PROJECTS_NODE_COUNT:-1}"; exit 0 ;;
      *)
        if [ "${GH_MOCK_PROJECTS_NODE_COUNT:-1}" -eq 0 ]; then
            echo ""
        else
            printf '{"id":"%s","number":%s,"ownerLogin":"%s"}\n' \
                "${GH_MOCK_PROJECT_ID:-PVT_resolved}" \
                "${GH_MOCK_PROJECT_NUM:-1}" \
                "${GH_MOCK_PROJECT_OWNER:-nirecom}"
        fi
        exit 0
        ;;
    esac
    ;;
  api\ graphql\ *fields*|api\ graphql\ *projectId*)
    case "$ARGS" in
      *"hasNextPage"*) echo "false"; exit 0 ;;
      *"endCursor"*)   echo ""; exit 0 ;;
      *) echo "${GH_MOCK_CONTENT_DATE_FIELD_ID:-PVTF_resolved_content_date}"; exit 0 ;;
    esac
    ;;
  issue\ create\ *)
    NUM="${GH_MOCK_NEW_ISSUE_NUM:-9999}"
    echo "https://github.com/nirecom/agents/issues/${NUM}"; exit 0 ;;
  project\ item-add\ *)
    if [ "${GH_MOCK_PROJECT_FAIL:-0}" = "1" ]; then
        echo "error: project attach failed" >&2; exit 1
    fi
    echo "PVTI_mock_item_id"; exit 0 ;;
  issue\ view\ *createdAt*)
    echo "2026-05-15"; exit 0 ;;
  issue\ view\ *--json\ url*)
    NUM=$(echo "$ARGS" | awk '{print $3}')
    echo "https://github.com/nirecom/agents/issues/${NUM}"; exit 0 ;;
  api\ graphql\ *projectItems*)
    echo ""; exit 0 ;;
  project\ item-edit\ *) exit 0 ;;
  *)
    echo "MOCK GH: no match for args=$ARGS" >&2; exit 2 ;;
esac
MOCK_EOF
chmod +x "$TMP/mock-bin/gh"
# Isolate cache.
export WORKFLOW_PLANS_DIR="$TMP/plans"
export GH_MOCK_PROJECT_OWNER="nirecom"
export GH_MOCK_PROJECT_NUM="1"
export GH_MOCK_PROJECT_ID="PVT_resolved"
# Ensure ISSUE_CREATE_* envs are all unset.
unset ISSUE_CREATE_OWNER ISSUE_CREATE_PROJECT_NUM \
      ISSUE_CREATE_PROJECT_ID ISSUE_CREATE_FIELD_ID 2>/dev/null
run_with_timeout 30 bash "$TARGET" --title "Resolver fire" --body "$(printf "$CANONICAL_BODY")" >/dev/null 2>&1
RC=$?
HAS_GRAPHQL=0
HAS_ITEM_ADD_RESOLVED=0
grep -q "api graphql" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_GRAPHQL=1
grep -qE "project item-add (--owner nirecom --num 1|1 --owner nirecom)" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_ITEM_ADD_RESOLVED=1
if [ "$RC" -eq 0 ] && [ "$HAS_GRAPHQL" -eq 1 ] && [ "$HAS_ITEM_ADD_RESOLVED" -eq 1 ]; then
    pass "R1-resolver-fire: ISSUE_CREATE_* unset → resolver runs + item-add uses resolved owner/num"
else
    fail "R1-resolver-fire: rc=$RC graphql=$HAS_GRAPHQL item_add=$HAS_ITEM_ADD_RESOLVED log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
unset WORKFLOW_PLANS_DIR GH_MOCK_PROJECT_OWNER GH_MOCK_PROJECT_NUM \
      GH_MOCK_PROJECT_ID GH_MOCK_CONTENT_DATE_FIELD_ID GH_MOCK_PROJECTS_NODE_COUNT 2>/dev/null
teardown_mock

# ---------------------------------------------------------------------------
# R2 (#641): --help path does NOT trigger resolver (lazy resolution)
# ---------------------------------------------------------------------------
setup_mock
export WORKFLOW_PLANS_DIR="$TMP/plans"
run_with_timeout 30 bash "$TARGET" --help >/dev/null 2>&1
RC=$?
GRAPHQL_CALLED=0
grep -q "api graphql" "$GH_MOCK_ARGS_LOG" 2>/dev/null && GRAPHQL_CALLED=1
if [ "$RC" -eq 0 ] && [ "$GRAPHQL_CALLED" -eq 0 ]; then
    pass "R2-lazy-help: --help path → no graphql call (lazy resolution)"
else
    fail "R2-lazy-help: rc=$RC graphql=$GRAPHQL_CALLED log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
unset WORKFLOW_PLANS_DIR
teardown_mock

# ---------------------------------------------------------------------------
# R3 (#641): resolver returns 0 linked projects → issue is created, item-add NOT called
# ---------------------------------------------------------------------------
setup_mock
cat > "$TMP/mock-bin/gh" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
if [ -n "${GH_MOCK_ARGS_LOG:-}" ]; then
    printf '%s\n' "$ARGS" >> "$GH_MOCK_ARGS_LOG"
fi
case "$ARGS" in
  auth\ status*)
    echo "Token scopes: 'project', 'repo'"; exit 0 ;;
  repo\ view\ *--json\ owner,name*) echo "nirecom/agents"; exit 0 ;;
  repo\ view\ *nameWithOwner*) echo "nirecom/agents"; exit 0 ;;
  api\ graphql\ *projectsV2*)
    case "$ARGS" in
      *"| length"*) echo "0"; exit 0 ;;
      *) echo ""; exit 0 ;;
    esac
    ;;
  api\ graphql\ *) echo ""; exit 0 ;;
  issue\ create\ *)
    echo "https://github.com/nirecom/agents/issues/9999"; exit 0 ;;
  project\ item-add\ *)
    echo "PVTI_mock"; exit 0 ;;
  issue\ view\ *createdAt*) echo "2026-05-15"; exit 0 ;;
  project\ item-edit\ *) exit 0 ;;
  *) echo "MOCK GH: no match $ARGS" >&2; exit 2 ;;
esac
MOCK_EOF
chmod +x "$TMP/mock-bin/gh"
export WORKFLOW_PLANS_DIR="$TMP/plans"
unset ISSUE_CREATE_OWNER ISSUE_CREATE_PROJECT_NUM \
      ISSUE_CREATE_PROJECT_ID ISSUE_CREATE_FIELD_ID 2>/dev/null
STDERR_OUT="$TMP/r3-stderr.txt"
run_with_timeout 30 bash "$TARGET" --title "Resolver fail" --body "$(printf "$CANONICAL_BODY")" >/dev/null 2>"$STDERR_OUT"
RC=$?
HAS_ITEM_ADD=0
grep -q "project item-add" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_ITEM_ADD=1
if [ "$RC" -eq 0 ] && [ "$HAS_ITEM_ADD" -eq 0 ]; then
    pass "R3-resolver-fail: 0 linked projects → issue created, item-add NOT called, exit 0"
else
    fail "R3-resolver-fail: rc=$RC item_add=$HAS_ITEM_ADD log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null) stderr=$(cat "$STDERR_OUT" 2>/dev/null)"
fi
unset WORKFLOW_PLANS_DIR
teardown_mock


# ============================================================================
# G-series (session-dedup feature) — Phase 2 survey strategy in SKILL.md.
#
# G1: Phase 2 contains `--limit 50` for Pass 1 (static grep)
# G2: Phase 2 contains `--paginate` in Pass 2 (static grep)
# G3: Phase 2 Pass 2 does NOT have `--limit` (uses --paginate instead)
# ============================================================================

skip() { echo "SKIP: $1"; }

if [ ! -f "$SKILL_MD" ]; then
    fail "G-pre: skills/issue-create/SKILL.md not found"
else
    # G1: --limit 50 present for Pass 1.
    if grep -qE -- '--limit[[:space:]]+50\b' "$SKILL_MD"; then
        pass "G1: SKILL.md Phase 2 Pass 1 includes '--limit 50'"
    else
        skip "G1: '--limit 50' not yet in SKILL.md (pre-implementation)"
    fi

    # G2: --paginate present in Pass 2.
    if grep -q -- '--paginate' "$SKILL_MD"; then
        pass "G2: SKILL.md Phase 2 Pass 2 includes '--paginate'"
    else
        skip "G2: '--paginate' not yet in SKILL.md (pre-implementation)"
    fi

    # G3: Pass 2 (--paginate) line does NOT also carry --limit.
    # Heuristic: every line that contains --paginate must NOT contain --limit.
    if grep -q -- '--paginate' "$SKILL_MD"; then
        BAD=$(grep -- '--paginate' "$SKILL_MD" | grep -c -- '--limit' || true)
        if [ "${BAD:-0}" -eq 0 ]; then
            pass "G3: Pass 2 lines with '--paginate' do NOT carry '--limit'"
        else
            fail "G3: $BAD line(s) carry both --paginate and --limit (must use --paginate alone)"
        fi
    else
        skip "G3: '--paginate' not yet present, ordering check skipped (pre-implementation)"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
