#!/bin/bash
# Tests: bin/github-issues/migration/commit-migration-artifacts.sh, bin/github-issues/migration/orchestrate.sh, bin/github-issues/sync-labels.sh
# Tags: migration, repo, github, issues, labels, scope:issue-specific
# Tests for feat/migrate-repo-commit-446 — commit + push migration artifacts.
# Tests commit-migration-artifacts.sh and orchestrator Step 6.
# RED: existence gate fails while commit-migration-artifacts.sh is missing.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMMIT_SCRIPT="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/migration/commit-migration-artifacts.sh"
ORCH_SCRIPT="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/migration/orchestrate.sh"
FIXTURE_DIR="$SCRIPT_CHECKOUT_ROOT/tests/fixtures/migration"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

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
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP" 2>/dev/null || true
    fi
}
trap cleanup EXIT
harness_isolate "$TMP/iso"

# Common mock gh / env setup.
MOCK_DIR="$TMP/mock"
mkdir -p "$MOCK_DIR"
cp "$FIXTURE_DIR/gh-mock.sh" "$MOCK_DIR/gh"
chmod +x "$MOCK_DIR/gh"
export MOCK_LOG="$TMP/mock.log"
: > "$MOCK_LOG"
export PATH="$MOCK_DIR:$PATH"

# Helper — build a fresh fixture repo at $1 with allowlist files populated.
# If $2 is "with-remote", creates bare remote at $TMP/<basename>-remote.git and
# pushes the initial commit.
make_fixture() {
    local repo="$1"
    local remote_mode="${2:-}"
    mkdir -p "$repo"
    git -C "$repo" init -b main >/dev/null 2>&1; git -C "$repo" config core.hooksPath /dev/null
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
    echo "# Todo" > "$repo/docs/todo.md"; printf '{"migrate": {"issues": "done"}}\n' > "$repo/.agents.json"  # #2473: .agents.json joins the allowlist
    # /migrate-issues Step 1.3 (issue #283) label-bootstrap artifacts.
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
OUT_DRY=$(run_with_timeout 30 bash "$COMMIT_SCRIPT" "$REPO_DRY" --skill migrate-issues --dry-run 2>&1)
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

# C1: commit subject names the calling skill (#2473: --skill replaced the fixed /migrate-repo text)
SUBJ_EXPECTED="chore(migration): ... /migrate-issues ..."
run_with_timeout 30 bash "$COMMIT_SCRIPT" "$REPO" --skill migrate-issues --no-push >/dev/null 2>&1
SUBJ_ACTUAL=$(git -C "$REPO" log -1 --format=%s 2>/dev/null)
if [[ "$SUBJ_ACTUAL" == "chore(migration): "*"/migrate-issues"* ]] && [[ "$SUBJ_ACTUAL" != *"/migrate-repo"* ]]; then
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
         "bin/github-issues/sync-labels.sh" ".github/workflows/sync-labels.yml" ".agents.json"; do
    echo "$FILES_IN_COMMIT" | grep -Fxq "$f" || c2_missing+=("$f")
done
if [ "${#c2_missing[@]}" -eq 0 ]; then
    pass "C2/C10: all 8 allowlist files in commit (incl. both ISSUE_TEMPLATE + sync-labels artifacts + .agents.json)"
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
OUT_C4=$(run_with_timeout 30 bash "$COMMIT_SCRIPT" "$REPO" --skill migrate-issues --no-push 2>&1)
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
run_with_timeout 30 bash "$COMMIT_SCRIPT" "$REPO2" --skill migrate-issues --no-push >/dev/null 2>&1
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
# orchestrate.sh finds its child via its own dir ($SCRIPT_DIR): run a bin/ copy under $TMP with a failing stub; the checkout is never written.
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/script-checkout-fixture.sh"
C12_MIG="$TMP/c12-checkout/bin/github-issues/migration"
mkdir -p "$C12_MIG"; printf '#!/usr/bin/env bash\nexit 1\n' > "$C12_MIG/commit-migration-artifacts.sh"; chmod +x "$C12_MIG/commit-migration-artifacts.sh"
script_checkout_fixture_copy "$TMP/c12-checkout" bin
run_with_timeout 60 bash "$C12_MIG/orchestrate.sh" "$REPO12" --from-step 6 >/dev/null 2>&1
RC=$?
state_present=0
[ -f "$REPO12/.migration-state.json" ] && state_present=1
if [ "$RC" -ne 0 ] && [ "$state_present" = "1" ]; then
    pass "C12: child failure → orchestrator exits non-zero, state preserved"
else
    fail "C12: rc=$RC state_present=$state_present"
fi

# C13 (#1231): regression guard — docs/ is a symlink into a SEPARATE git repo; git rejects
# `git add -- docs/todo.md` ("beyond a symbolic link") and Step 6 aborts (exit 128). The fix must
# resolve the destination repo and commit docs/todo.md there at its show-prefix path
# (primary_repo/docs -> docs_repo/projects/engineering/mynewrepo). EXPECTED-FAIL until the source
# fix lands. Uses its own fixture (two repos + symlink), NOT make_fixture/teardown_fixture.

# c13_symln — create a REAL symlink cross-platform: a bare `ln -s` on Git-for-Windows MSYS copies the
# directory; MSYS=winsymlinks:nativestrict forces a true link (needs developer mode). The `test -L`
# guard below SKIPs on a directory-copy fallback rather than pass without crossing a symlink boundary.
c13_symln() {
    local target="$1" link="$2"
    MSYS="winsymlinks:nativestrict" ln -sfn "$target" "$link" 2>/dev/null \
        || ln -sfn "$target" "$link" 2>/dev/null || true
}

# JUNCTION_OK guard: skip when real symlink creation is unavailable (Windows
# without developer mode / elevated shell). Probe an EXISTING directory target.
C13_SYMTGT="$TMP/c13-symtgt"
C13_SYMLNK="$TMP/c13-symlnk"
mkdir -p "$C13_SYMTGT"
C13_JUNCTION_OK=0
c13_symln "$C13_SYMTGT" "$C13_SYMLNK"
[ -L "$C13_SYMLNK" ] && C13_JUNCTION_OK=1
rm -f "$C13_SYMLNK" 2>/dev/null || true
rm -rf "$C13_SYMTGT" 2>/dev/null || true

if [ "$C13_JUNCTION_OK" != "1" ]; then
    echo "SKIP C13: symlinks not available (Windows without developer mode)"
else
    C13_PRIMARY="$TMP/c13-primary"
    C13_DOCS="$TMP/c13-docs"

    # --- docs_repo: a standalone git repo with the subdir the symlink targets.
    mkdir -p "$C13_DOCS/projects/engineering/mynewrepo"
    git -C "$C13_DOCS" init -b main >/dev/null 2>&1
    git -C "$C13_DOCS" config user.email "test@example.com"
    git -C "$C13_DOCS" config user.name "Test"
    echo "# docs root" > "$C13_DOCS/README.md"
    # Track the symlink-target subdir via a .keep sentinel — but NOT todo.md, so
    # that todo.md appearing in docs_repo's HEAD is proof the fix committed it
    # there (Assert 3 cannot false-pass off a pre-seeded todo.md).
    echo "" > "$C13_DOCS/projects/engineering/mynewrepo/.keep"
    git -C "$C13_DOCS" -c core.autocrlf=false add -A >/dev/null 2>&1
    ENFORCE_WORKTREE=off git -C "$C13_DOCS" commit -m "init docs" >/dev/null 2>&1

    # --- primary_repo: the migrate-repo target repo, docs/ symlinked into docs_repo.
    mkdir -p "$C13_PRIMARY"
    git -C "$C13_PRIMARY" init -b main >/dev/null 2>&1
    git -C "$C13_PRIMARY" config user.email "test@example.com"
    git -C "$C13_PRIMARY" config user.name "Test"
    echo "init" > "$C13_PRIMARY/README.md"
    git -C "$C13_PRIMARY" add README.md >/dev/null 2>&1
    ENFORCE_WORKTREE=off git -C "$C13_PRIMARY" commit -m "init" >/dev/null 2>&1

    # Non-docs allowlist artifacts (must land in primary_repo commit).
    mkdir -p "$C13_PRIMARY/.github/ISSUE_TEMPLATE"
    cat > "$C13_PRIMARY/.github/labels.yml" <<'EOF'
- name: type:task
  color: "0e8a16"
EOF
    echo ".migration-state.json" > "$C13_PRIMARY/.gitignore"

    # docs/ is a REAL SYMLINK into the docs_repo subdir (the subdir case).
    c13_symln "$C13_DOCS/projects/engineering/mynewrepo" "$C13_PRIMARY/docs"
    # Guard: only proceed if a true symlink was produced (not a directory copy),
    # so the test genuinely exercises the git symlink-boundary the #1231 bug hits.
    if [ ! -L "$C13_PRIMARY/docs" ]; then
        echo "SKIP C13: docs/ did not materialize as a real symlink (directory-copy fallback)"
    else
    # Modify the todo.md thin index through the symlink so Step 6 has a diff to commit.
    echo "# Todo (updated by migration)" > "$C13_PRIMARY/docs/todo.md"

    C13_PRIMARY_SHA_BEFORE=$(git -C "$C13_PRIMARY" rev-parse HEAD 2>/dev/null)
    C13_DOCS_SHA_BEFORE=$(git -C "$C13_DOCS" rev-parse HEAD 2>/dev/null)

    C13_OUT=$(run_with_timeout 30 bash "$COMMIT_SCRIPT" "$C13_PRIMARY" --skill migrate-issues --no-push 2>&1)
    C13_RC=$?

    C13_PRIMARY_SHA_AFTER=$(git -C "$C13_PRIMARY" rev-parse HEAD 2>/dev/null)
    C13_DOCS_SHA_AFTER=$(git -C "$C13_DOCS" rev-parse HEAD 2>/dev/null)

    # Assert 1: primary_repo advanced (non-docs allowlist files committed there).
    primary_advanced=0
    [ -n "$C13_PRIMARY_SHA_AFTER" ] && [ "$C13_PRIMARY_SHA_BEFORE" != "$C13_PRIMARY_SHA_AFTER" ] && primary_advanced=1
    primary_has_labels=0
    git -C "$C13_PRIMARY" show --name-only --format= HEAD 2>/dev/null \
        | grep -Fxq ".github/labels.yml" && primary_has_labels=1

    # Assert 2: docs_repo advanced (docs/todo.md committed into the symlink target repo).
    docs_advanced=0
    [ -n "$C13_DOCS_SHA_AFTER" ] && [ "$C13_DOCS_SHA_BEFORE" != "$C13_DOCS_SHA_AFTER" ] && docs_advanced=1

    # Assert 3: the docs commit path uses the show-prefix (subdir-relative path in docs_repo).
    docs_path_ok=0
    git -C "$C13_DOCS" show --name-only --format= HEAD 2>/dev/null \
        | grep -Fxq "projects/engineering/mynewrepo/todo.md" && docs_path_ok=1

    if [ "$C13_RC" -eq 0 ] && [ "$primary_advanced" = "1" ] && [ "$primary_has_labels" = "1" ] \
       && [ "$docs_advanced" = "1" ] && [ "$docs_path_ok" = "1" ]; then
        pass "C13: symlink docs/ → separate repo, 2-repo commit at show-prefix path"
    else
        fail "C13: rc=$C13_RC primary_adv=$primary_advanced labels=$primary_has_labels docs_adv=$docs_advanced docs_path=$docs_path_ok out='$C13_OUT' (EXPECTED-FAIL until #1231 source fix)"
    fi
    fi  # end real-symlink guard
fi

# #2473: what is staged before a run, and a direct --dry-run. The helpers set R and BARE (the push target).
check() { if eval "$2"; then pass "$1"; else fail "$1: ${3:-}"; fi; }
# unrel_fx <name> <skill> — a fixture whose allowlist for <skill> is already committed and pushed.
unrel_fx() {
    R="$TMP/$1"; BARE="$R-remote.git"
    make_fixture "$R" "with-remote"
    git -C "$R" config core.excludesFile "$R/.git/info/exclude"
    run_with_timeout 30 bash "$COMMIT_SCRIPT" "$R" --skill "$2" >/dev/null 2>&1 || fail "unrel_fx $1: seed commit failed"
}
# stage_unrelated <skill> — stages a tracked-file edit, a new file and allowlist prefix neighbours (EXTRA).
stage_unrelated() {
    EXTRA=(unrelated-new.txt .agents.json.bak)
    [ "$1" = migrate-issues ] && EXTRA+=(.github/ISSUE_TEMPLATE-old)
    for f in "${EXTRA[@]}"; do echo unrelated > "$R/$f"; done
    echo tracked-edit >> "$R/README.md"
    git -C "$R" add -f -- "${EXTRA[@]}" README.md
}
unrel_left() {
    local f
    check "$1: the tracked edit stays staged, in no commit" '[ "$(git -C "$R" status --porcelain -- README.md | tr -d "\r")" = "M  README.md" ]' "$(git -C "$R" status --porcelain)"
    check "$1: the push target keeps the old README.md" '[ "$(git -C "$BARE" show main:README.md | tr -d "\r")" = init ]'
    for f in "${EXTRA[@]}"; do
        check "$1: $f stays staged, not in HEAD or the push target" '[ "$(git -C "$R" status --porcelain -- "$f" | tr -d "\r")" = "A  $f" ] && [ -z "$(git -C "$R" ls-tree -r --name-only HEAD | grep -Fx -- "$f")" ] && [ -z "$(git -C "$BARE" ls-tree -r --name-only main | grep -Fx -- "$f")" ]' "$(git -C "$R" status --porcelain)"
    done
}

case_begin "staged-unrelated-excluded" "bin/github-issues/migration/commit-migration-artifacts.sh"
for skill in migrate-tests migrate-issues; do
    unrel_fx "unrel-$skill" "$skill"
    stage_unrelated "$skill"
    printf '{"migrate":{"tests":"changed"}}\n' > "$R/.agents.json"
    want=".agents.json"
    [ "$skill" = migrate-issues ] && { printf 'name: Extra\n' > "$R/.github/ISSUE_TEMPLATE/extra.yml"; want=".agents.json .github/ISSUE_TEMPLATE/extra.yml"; }
    OUT=$(run_with_timeout 30 bash "$COMMIT_SCRIPT" "$R" --skill "$skill" 2>&1); RC=$?
    got="$(git -C "$R" show --name-only --format= HEAD | tr -d '\r' | sed '/^$/d' | tr '\n' ' ' | sed 's/ $//')"
    check "$skill unrelated staged: exit 0, the commit holds only [$want]" '[ "$RC" -eq 0 ] && [ "$got" = "$want" ]' "rc=$RC got=[$got] out=$OUT"
    check "$skill unrelated staged: the commit reached the push target" '[ "$(git -C "$BARE" rev-parse main)" = "$(git -C "$R" rev-parse HEAD)" ]'
    unrel_left "$skill unrelated staged"
done
case_end

case_begin "staged-unrelated-only-no-commit" "bin/github-issues/migration/commit-migration-artifacts.sh"
for skill in migrate-tests migrate-issues; do
    unrel_fx "only-$skill" "$skill"
    stage_unrelated "$skill"
    head0="$(git -C "$R" rev-parse HEAD)"
    OUT=$(run_with_timeout 30 bash "$COMMIT_SCRIPT" "$R" --skill "$skill" 2>&1); RC=$?
    check "$skill only unrelated staged: exit 0, nothing to commit, no commit, no push" '[ "$RC" -eq 0 ] && grep -Fq "nothing to commit" <<<"$OUT" && [ "$(git -C "$R" rev-parse HEAD)" = "$head0" ] && [ "$(git -C "$BARE" rev-parse main)" = "$head0" ]' "rc=$RC out=$OUT"
    unrel_left "$skill only unrelated staged"
done
case_end

case_begin "dry-run-direct-plan-only" "bin/github-issues/migration/commit-migration-artifacts.sh"
for spec in "migrate-tests|1|chore(migration): record /migrate-tests in .agents.json" "migrate-issues|6|chore(migration): apply /migrate-issues Step 1/3 artifacts"; do
    IFS='|' read -r skill listed subj <<<"$spec"
    R="$TMP/dry-$skill"; BARE="$R-remote.git"
    make_fixture "$R" "with-remote"
    rm -f "$R/docs/todo.md"
    head0="$(git -C "$R" rev-parse HEAD)"
    OUT=$(run_with_timeout 30 bash "$COMMIT_SCRIPT" "$R" --skill "$skill" --dry-run --no-push 2>&1); RC=$?
    check "$skill --dry-run: exit 0, the stage and commit plan lines" '[ "$RC" -eq 0 ] && grep -Fxq "[dry-run] would stage:" <<<"$OUT" && grep -Fxq "  - .agents.json" <<<"$OUT" && grep -Fxq "[dry-run] would commit: $subj" <<<"$OUT"' "rc=$RC out=$OUT"
    check "$skill --dry-run: lists $listed existing allowlist path(s), not an absent one" '[ "$(grep -c "^  - " <<<"$OUT")" -eq "$listed" ] && ! grep -Fq "docs/todo.md" <<<"$OUT"' "$OUT"
    check "$skill --dry-run: HEAD and the push target unchanged" '[ "$(git -C "$R" rev-parse HEAD)" = "$head0" ] && [ "$(git -C "$BARE" rev-parse main)" = "$head0" ]'
    check "$skill --dry-run: nothing staged, .agents.json uncommitted" 'git -C "$R" diff --cached --quiet && [ "$(git -C "$R" status --porcelain -- .agents.json | tr -d "\r")" = "?? .agents.json" ]' "$(git -C "$R" status --porcelain)"
done
case_end

# ----------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
