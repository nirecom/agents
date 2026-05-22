#!/bin/bash
# Tests for feat/migrate-repo-commit-446 — commit + push migration artifacts.
# Tests commit-migration-artifacts.sh and orchestrator Step 6.
# RED: existence gate fails while commit-migration-artifacts.sh is missing.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMIT_SCRIPT="$AGENTS_DIR/bin/github-issues/migration/commit-migration-artifacts.sh"
ORCH_SCRIPT="$AGENTS_DIR/bin/github-issues/migration/orchestrate.sh"
FIXTURE_DIR="$AGENTS_DIR/tests/fixtures/migration"

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

# --- Existence gate ---------------------------------------------------------
missing=()
[ -f "$COMMIT_SCRIPT" ] || missing+=("bin/github-issues/migration/commit-migration-artifacts.sh")
[ -f "$ORCH_SCRIPT" ]   || missing+=("bin/github-issues/migration/orchestrate.sh")
if [ "${#missing[@]}" -gt 0 ]; then
    for f in "${missing[@]}"; do
        echo "FAIL: precondition missing — $f"
    done
    echo ""
    echo "Results: 0 passed, ${#missing[@]} failed"
    exit 1
fi

TMP="$(mktemp -d)"

cleanup() {
    # Restore commit script if C12 overwrote it with a failing stub (cp-based, trap-safe).
    if [ -f "${COMMIT_SCRIPT}.c12bak" ]; then
        cp "${COMMIT_SCRIPT}.c12bak" "$COMMIT_SCRIPT" 2>/dev/null || true
        rm -f "${COMMIT_SCRIPT}.c12bak" 2>/dev/null || true
    fi
    [ -f "$COMMIT_SCRIPT" ] && chmod +x "$COMMIT_SCRIPT" 2>/dev/null || true
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Common mock gh / env setup.
MOCK_DIR="$TMP/mock"
mkdir -p "$MOCK_DIR"
cp "$FIXTURE_DIR/gh-mock.sh" "$MOCK_DIR/gh"
chmod +x "$MOCK_DIR/gh"
export MOCK_LOG="$TMP/mock.log"
: > "$MOCK_LOG"
export PATH="$MOCK_DIR:$PATH"
export AGENTS_CONFIG_DIR="$AGENTS_DIR"

# Helper — build a fresh fixture repo at $1 with allowlist files populated.
# If $2 is "with-remote", creates bare remote at $TMP/<basename>-remote.git and
# pushes the initial commit.
make_fixture() {
    local repo="$1"
    local remote_mode="${2:-}"
    mkdir -p "$repo"
    git -C "$repo" init -b main >/dev/null 2>&1
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md >/dev/null
    # ENFORCE_WORKTREE=off: the global pre-commit hook (core.hooksPath) blocks commits in
    # non-linked worktrees when ENFORCE_WORKTREE is on; bypass it for fixture-only commits.
    ENFORCE_WORKTREE=off git -C "$repo" commit -m "init" >/dev/null 2>&1

    if [ "$remote_mode" = "with-remote" ]; then
        local remote_name
        remote_name="$(basename "$repo")-remote.git"
        git -C "$TMP" init --bare "$remote_name" >/dev/null 2>&1
        git -C "$repo" remote add origin "$TMP/$remote_name"
        ENFORCE_WORKTREE=off git -C "$repo" push -u origin main >/dev/null 2>&1
    fi

    # Allowlist files (untracked at this point).
    mkdir -p "$repo/.github/ISSUE_TEMPLATE"
    cat > "$repo/.github/labels.yml" <<'EOF'
- name: type:task
  color: "0e8a16"
EOF
    cat > "$repo/.github/ISSUE_TEMPLATE/task.yml" <<'EOF'
name: Task
description: A normal task.
EOF
    cat > "$repo/.github/ISSUE_TEMPLATE/incident.yml" <<'EOF'
name: Incident
description: Production incident.
EOF
    echo ".migration-state.json" > "$repo/.gitignore"
    mkdir -p "$repo/docs"
    echo "# Todo" > "$repo/docs/todo.md"
    # /migrate-repo Step 1.3 (issue #283) label-bootstrap artifacts.
    mkdir -p "$repo/bin/github-issues"
    cat > "$repo/bin/github-issues/sync-labels.sh" <<'STUB'
#!/usr/bin/env bash
# fixture stub
STUB
    chmod +x "$repo/bin/github-issues/sync-labels.sh"
    mkdir -p "$repo/.github/workflows"
    cat > "$repo/.github/workflows/sync-labels.yml" <<'STUB'
# fixture stub
STUB

    # Allowlist-excluded files.
    mkdir -p "$repo/agents"
    echo "SECRET=x" > "$repo/agents/.env"
    echo "backup" > "$repo/docs/todo.md.bak"
}

# ----------------------------------------------------------------------------
# C5 first (needs the initial state with allowlist files untracked).
REPO_DRY="$TMP/repo-dry"
make_fixture "$REPO_DRY"
INITIAL_COUNT_DRY=$(git -C "$REPO_DRY" rev-list --count HEAD 2>/dev/null || echo 0)
OUT_DRY=$(run_with_timeout 30 bash "$COMMIT_SCRIPT" "$REPO_DRY" --dry-run 2>&1)
POST_COUNT_DRY=$(git -C "$REPO_DRY" rev-list --count HEAD 2>/dev/null || echo 0)
if [ "$INITIAL_COUNT_DRY" = "$POST_COUNT_DRY" ] && \
   echo "$OUT_DRY" | grep -Eq '\[dry-run\] would (stage|commit):'; then
    pass "C5: --dry-run makes no new commit and announces planned action"
else
    fail "C5: initial=$INITIAL_COUNT_DRY post=$POST_COUNT_DRY out='$OUT_DRY'"
fi

# ----------------------------------------------------------------------------
# Main fixture for C1–C4, C6, C10, C11.
REPO="$TMP/repo"
make_fixture "$REPO" "with-remote"

# C1: commit subject
SUBJ_EXPECTED="chore(migration): apply /migrate-repo Step 1/3 artifacts"
run_with_timeout 30 bash "$COMMIT_SCRIPT" "$REPO" --no-push >/dev/null 2>&1
SUBJ_ACTUAL=$(git -C "$REPO" log -1 --format=%s 2>/dev/null)
if [ "$SUBJ_ACTUAL" = "$SUBJ_EXPECTED" ]; then
    pass "C1: commit subject = '$SUBJ_EXPECTED'"
else
    fail "C1: subject='$SUBJ_ACTUAL' expected='$SUBJ_EXPECTED'"
fi

# C2 / C10: allowlist files all included.
# EXPECTED FAILURE until commit-migration-artifacts.sh ALLOWLIST is extended
# (issue #283) to include sync-labels.sh + sync-labels.yml.
FILES_IN_COMMIT=$(git -C "$REPO" show --name-only --format= HEAD 2>/dev/null | grep -v '^$')
c2_missing=()
for f in ".github/labels.yml" ".github/ISSUE_TEMPLATE/task.yml" \
         ".github/ISSUE_TEMPLATE/incident.yml" ".gitignore" "docs/todo.md" \
         "bin/github-issues/sync-labels.sh" ".github/workflows/sync-labels.yml"; do
    echo "$FILES_IN_COMMIT" | grep -Fxq "$f" || c2_missing+=("$f")
done
if [ "${#c2_missing[@]}" -eq 0 ]; then
    pass "C2/C10: all 7 allowlist files in commit (incl. both ISSUE_TEMPLATE + sync-labels artifacts)"
else
    fail "C2/C10: missing from commit: ${c2_missing[*]}"
fi

# C3: allowlist-excluded files remain untracked, NOT in commit.
STATUS_OUT=$(git -C "$REPO" status --porcelain 2>/dev/null)
# On Windows, untracked files in subdirs appear as the dir itself (e.g. "?? agents/").
env_untracked=$(echo "$STATUS_OUT" | grep -E '^\?\? ' | grep -E 'agents' || true)
# docs/todo.md.bak may be hidden by a global gitignore (*.bak); check filesystem instead.
bak_untracked=$([ -f "$REPO/docs/todo.md.bak" ] && echo "present" || echo "")
env_in_commit=$(echo "$FILES_IN_COMMIT" | grep -Fx 'agents/.env' || true)
bak_in_commit=$(echo "$FILES_IN_COMMIT" | grep -Fx 'docs/todo.md.bak' || true)
if [ -n "$env_untracked" ] && [ -n "$bak_untracked" ] && \
   [ -z "$env_in_commit" ] && [ -z "$bak_in_commit" ]; then
    pass "C3: agents/.env and docs/todo.md.bak untracked, not in commit"
else
    fail "C3: env_untracked='$env_untracked' bak_untracked='$bak_untracked' env_in_commit='$env_in_commit' bak_in_commit='$bak_in_commit'"
fi

# C6: commit body lists files.
# EXPECTED FAILURE until commit-migration-artifacts.sh ALLOWLIST is extended
# (issue #283) to include sync-labels.sh + sync-labels.yml.
BODY=$(git -C "$REPO" log -1 --format=%b 2>/dev/null)
# Use -- to prevent grep from interpreting the leading '-' in patterns as an option.
if echo "$BODY" | grep -Fq -- '- .github/labels.yml' && \
   echo "$BODY" | grep -Fq -- '- docs/todo.md' && \
   echo "$BODY" | grep -Fq -- '- bin/github-issues/sync-labels.sh' && \
   echo "$BODY" | grep -Fq -- '- .github/workflows/sync-labels.yml'; then
    pass "C6: commit body lists allowlist files (incl. sync-labels artifacts)"
else
    fail "C6: body missing file list — body='$BODY'"
fi

# C4: idempotent skip — second run does not advance HEAD.
SHA1=$(git -C "$REPO" rev-parse HEAD)
OUT_C4=$(run_with_timeout 30 bash "$COMMIT_SCRIPT" "$REPO" --no-push 2>&1)
SHA2=$(git -C "$REPO" rev-parse HEAD)
if [ "$SHA1" = "$SHA2" ] && echo "$OUT_C4" | grep -Fq 'nothing to commit'; then
    pass "C4: second commit run is no-op ('nothing to commit')"
else
    fail "C4: sha1=$SHA1 sha2=$SHA2 out='$OUT_C4'"
fi

# ----------------------------------------------------------------------------
# C6b: issue range in body — separate fixture.
REPO2="$TMP/repo2"
make_fixture "$REPO2"
cat > "$REPO2/.migration-state.json" <<'EOF'
{
  "current_step": 5,
  "history": {"migrated": [{"issue_number": 1}, {"issue_number": 2}, {"issue_number": 6}]},
  "todo": {"migrated": [{"issue_number": 7}, {"issue_number": 8}]}
}
EOF
run_with_timeout 30 bash "$COMMIT_SCRIPT" "$REPO2" --no-push >/dev/null 2>&1
BODY2=$(git -C "$REPO2" log -1 --format=%b 2>/dev/null)
if echo "$BODY2" | grep -Fq 'history #1-#6' && echo "$BODY2" | grep -Fq 'todo #7-#8'; then
    pass "C6b: commit body includes 'history #1-#6' and 'todo #7-#8'"
else
    fail "C6b: body='$BODY2'"
fi

# ----------------------------------------------------------------------------
# C7: orchestrator Step 6 integration — sentinels in order, commit + push.
REPO7="$TMP/repo7"
make_fixture "$REPO7" "with-remote"
cat > "$REPO7/.migration-state.json" <<'EOF'
{
  "current_step": 5,
  "history": {"migrated": [{"issue_number": 1}]},
  "todo": {"migrated": [{"issue_number": 2}]},
  "todo_md_rewritten": false
}
EOF
OUT7=$(run_with_timeout 60 bash "$ORCH_SCRIPT" "$REPO7" --from-step 6 2>&1)
LINE_UV=$(echo "$OUT7" | awk '/WORKFLOW_USER_VERIFIED/{print NR; exit}')
LINE_OFF=$(echo "$OUT7" | awk '/WORKFLOW_ENFORCE_WORKTREE_OFF/{print NR; exit}')
LINE_ON=$(echo "$OUT7" | awk '/WORKFLOW_ENFORCE_WORKTREE_ON/{print NR; exit}')
COUNT7=$(git -C "$REPO7" rev-list --count HEAD 2>/dev/null || echo 0)
REMOTE7="$TMP/repo7-remote.git"
REMOTE_COUNT7=$(git -C "$REMOTE7" log --oneline main 2>/dev/null | wc -l | tr -d ' ')
order_ok=0
if [ -n "$LINE_UV" ] && [ -n "$LINE_OFF" ] && [ -n "$LINE_ON" ] && \
   [ "$LINE_UV" -lt "$LINE_OFF" ] && [ "$LINE_OFF" -lt "$LINE_ON" ]; then
    order_ok=1
fi
if [ "$order_ok" = "1" ] && [ "$COUNT7" -ge 2 ] && [ "$REMOTE_COUNT7" -ge 2 ]; then
    pass "C7: orchestrator Step 6 — sentinels ordered, commit pushed to remote"
else
    fail "C7: order_ok=$order_ok uv=$LINE_UV off=$LINE_OFF on=$LINE_ON local=$COUNT7 remote=$REMOTE_COUNT7"
fi

# ----------------------------------------------------------------------------
# C8: --dry-run suppresses sentinels.
REPO8="$TMP/repo8"
make_fixture "$REPO8" "with-remote"
cat > "$REPO8/.migration-state.json" <<'EOF'
{"current_step": 5, "history": {"migrated": []}, "todo": {"migrated": []}}
EOF
OUT8=$(run_with_timeout 60 bash "$ORCH_SCRIPT" "$REPO8" --dry-run 2>&1)
has_uv=$(echo "$OUT8" | grep -c 'WORKFLOW_USER_VERIFIED' || true)
has_off=$(echo "$OUT8" | grep -c 'WORKFLOW_ENFORCE_WORKTREE_OFF' || true)
has_on=$(echo "$OUT8" | grep -c 'WORKFLOW_ENFORCE_WORKTREE_ON' || true)
has_dry=$(echo "$OUT8" | grep -Ec '\[dry-run\] would (stage|commit):' || true)
if [ "$has_uv" = "0" ] && [ "$has_off" = "0" ] && [ "$has_on" = "0" ] && [ "$has_dry" -ge 1 ]; then
    pass "C8: --dry-run suppresses sentinels, prints dry-run notice"
else
    fail "C8: uv=$has_uv off=$has_off on=$has_on dry=$has_dry"
fi

# ----------------------------------------------------------------------------
# C9: --from-step 7 skips Step 6.
REPO9="$TMP/repo9"
make_fixture "$REPO9" "with-remote"
cat > "$REPO9/.migration-state.json" <<'EOF'
{"current_step": 6, "history": {"migrated": []}, "todo": {"migrated": []}}
EOF
OUT9=$(run_with_timeout 60 bash "$ORCH_SCRIPT" "$REPO9" --from-step 7 2>&1)
has_step6=$(echo "$OUT9" | grep -c 'Step 6:' || true)
has_uv9=$(echo "$OUT9" | grep -c 'WORKFLOW_USER_VERIFIED' || true)
if [ "$has_step6" = "0" ] && [ "$has_uv9" = "0" ]; then
    pass "C9: --from-step 7 skips Step 6 (no sentinel, no 'Step 6:' header)"
else
    fail "C9: step6_lines=$has_step6 uv_lines=$has_uv9"
fi

# ----------------------------------------------------------------------------
# C11: orchestrator-level idempotency — second --from-step 6 is no-op.
SHA_BEFORE_RERUN=$(git -C "$REPO7" rev-parse HEAD)
OUT11=$(run_with_timeout 60 bash "$ORCH_SCRIPT" "$REPO7" --from-step 6 2>&1)
SHA_AFTER_RERUN=$(git -C "$REPO7" rev-parse HEAD)
if [ "$SHA_BEFORE_RERUN" = "$SHA_AFTER_RERUN" ] && echo "$OUT11" | grep -Fq 'nothing to commit'; then
    pass "C11: orchestrator second Step 6 run is no-op"
else
    fail "C11: sha_before=$SHA_BEFORE_RERUN sha_after=$SHA_AFTER_RERUN out='$OUT11'"
fi

# ----------------------------------------------------------------------------
# C12: child-script failure halts orchestrator, state preserved.
REPO12="$TMP/repo12"
make_fixture "$REPO12" "with-remote"
cat > "$REPO12/.migration-state.json" <<'EOF'
{"current_step": 5, "history": {"migrated": []}, "todo": {"migrated": []}}
EOF
# Overwrite script with a failing stub — cp-based, so .c12bak always holds the real script.
# If SIGKILL prevents cleanup, the real script survives in .c12bak for manual recovery.
cp "$COMMIT_SCRIPT" "${COMMIT_SCRIPT}.c12bak"
printf '#!/usr/bin/env bash\nexit 1\n' > "$COMMIT_SCRIPT"
chmod +x "$COMMIT_SCRIPT"
run_with_timeout 60 bash "$ORCH_SCRIPT" "$REPO12" --from-step 6 >/dev/null 2>&1
RC=$?
cp "${COMMIT_SCRIPT}.c12bak" "$COMMIT_SCRIPT"
rm -f "${COMMIT_SCRIPT}.c12bak"
state_present=0
[ -f "$REPO12/.migration-state.json" ] && state_present=1
if [ "$RC" -ne 0 ] && [ "$state_present" = "1" ]; then
    pass "C12: child failure → orchestrator exits non-zero, state preserved"
else
    fail "C12: rc=$RC state_present=$state_present"
fi

# ----------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
