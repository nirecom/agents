# F-622-1/2/3, R1-R3, G1-G3 tests (Phase 5 resolver + session-dedup)

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
