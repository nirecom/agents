#!/usr/bin/env bash
# Tests: skills/worktree-end/scripts/abort-branch.sh, skills/worktree-end/scripts/abort-branch.md, skills/worktree-end/SKILL.md, skills/issue-close-verified/scripts/check-wip-owner.sh, skills/workflow-abort-accepted/scripts/show-worktree-state.sh, skills/workflow-abort-accepted/SKILL.md
# Tags: TL1, workflow-abort, worktree-end, issue-close-verified, wip-state, regression-2920, scope:issue-specific
# lang-check: ignore -- grep patterns intentionally accept English/Japanese wording for the same doc needle.
# #2920 S7/S9: abort-branch.sh refuses a worktree with uncommitted changes (WE-3 kept) and, on a
# clean one, abandons every closes_issues WIP mark whose `check --session-id` is `same`, past a
# wip-state exit 1 (other/none/check failure only warn); check-wip-owner.sh warns
# only on `other`. Both reach wip-state via WIP_STATE_SH (stubbed); abort-branch.sh checks its cwd.
# TL3 gap (what this test does NOT catch):
# - the real wip-state.sh against a GitHub Projects v2 board;
# - the prose steps WE-5/6/7/9a run by the model; their wiring is pinned structurally from SKILL.md.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
_ISOLATION_TMP_ROOT="$(make_tmp)"; readonly _ISOLATION_TMP_ROOT
harness_isolate "$_ISOLATION_TMP_ROOT"
unset CLAUDE_CODE_SESSION_ID
export CLAUDE_TRANSCRIPT_BASE_DIR="$_ISOLATION_TMP_ROOT/transcripts-empty"
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR"
trap 'rm -rf "$_ISOLATION_TMP_ROOT"' EXIT

WE_DIR="$SCRIPT_CHECKOUT_ROOT/skills/worktree-end"
ABORT_BRANCH="$WE_DIR/scripts/abort-branch.sh"
ABORT_DOC="$WE_DIR/scripts/abort-branch.md"
CHECK_OWNER="$SCRIPT_CHECKOUT_ROOT/skills/issue-close-verified/scripts/check-wip-owner.sh"

# The stub logs "<verb> <N>" (full argv to STUB_ARGV_LOG) and answers from STUB_ANSWERS:
# "<key>:exit:stdout" entries, <key> = "<verb>@<N>" or "<N>" (any verb); the first match wins.
STUB="$_ISOLATION_TMP_ROOT/wip-state-stub.sh"
STUB_LOG="$_ISOLATION_TMP_ROOT/wip-state-calls.log"
STUB_ARGV_LOG="$_ISOLATION_TMP_ROOT/wip-state-argv.log"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
echo "$1 $2" >> "$STUB_LOG"
echo "$*" >> "$STUB_ARGV_LOG"
for entry in $STUB_ANSWERS; do
    n="${entry%%:*}"; rest="${entry#*:}"; code="${rest%%:*}"; out="${rest#*:}"
    if [ "$n" = "$2" ] || [ "$n" = "$1@$2" ]; then
        [ -n "$out" ] && echo "$out"
        [ "$code" != 0 ] && echo "warn: stub failure for #$2" >&2
        exit "$code"
    fi
done
exit 0
EOF
chmod +x "$STUB"
export STUB_LOG STUB_ARGV_LOG
WIP_STATE_SH="$(np "$STUB")"
export WIP_STATE_SH
calls() { tr '\n' ',' < "$STUB_LOG"; }

# seed_state <sid> <issues-json> — a started session whose closes_issues is <issues-json>.
seed_state() {
    run_with_timeout 30 node -e '
const fs = require("fs"), path = require("path");
const [sid, issues] = process.argv.slice(1);
const s = { version: 1, session_id: sid, created_at: new Date().toISOString(), steps: {},
  closes_issues: JSON.parse(issues) };
fs.writeFileSync(path.join(process.env.WORKFLOW_STATE_DIR, sid + ".json"), JSON.stringify(s, null, 2));
' "$1" "$2" </dev/null
}

# mk_worktree <dir> — a fixture repo with one commit and a clean working tree.
mk_worktree() {
    harness_git_init "$1"
    echo base > "$1/file.txt"
    git -C "$1" add file.txt
    git -C "$1" -c user.name=t -c user.email=t@example.invalid commit -qm base
}
CLEAN_WT="$_ISOLATION_TMP_ROOT/wt-clean"; mk_worktree "$CLEAN_WT"
DIRTY_WT="$_ISOLATION_TMP_ROOT/wt-dirty"; mk_worktree "$DIRTY_WT"
echo "uncommitted edit" >> "$DIRTY_WT/file.txt"
[ -n "$(git -C "$DIRTY_WT" status --porcelain)" ] || { echo "FATAL: dirty fixture is clean"; exit 1; }

case_begin "abort-branch-continues-past-wip-failure" "skills/worktree-end/scripts/abort-branch.sh"
if [ ! -f "$ABORT_BRANCH" ]; then
    fail "abort-branch: script exists" "$ABORT_BRANCH is missing"
else
    seed_state "f2920-ab" "[11, 12, 13]"
    : > "$STUB_LOG"; : > "$STUB_ARGV_LOG"
    export STUB_ANSWERS="check@11:0:same check@12:0:same check@13:0:same abandon@11:1:"
    OUT="$(cd "$CLEAN_WT" && run_with_timeout 60 bash "$ABORT_BRANCH" --session f2920-ab 2>&1 </dev/null)"
    RC=$?
    if [ "$(calls)" = "check 11,abandon 11,check 12,abandon 12,check 13,abandon 13," ]; then pass "abort-branch: abandons every closes_issues issue, past the exit-1 one"
    else fail "abort-branch: abandons every closes_issues issue, past the exit-1 one" "calls=$(calls) out=$OUT"; fi
    if [ "$RC" -eq 0 ]; then pass "abort-branch: a clean worktree completes (a wip-state exit 1 does not fail it)"
    else fail "abort-branch: a clean worktree completes (a wip-state exit 1 does not fail it)" "rc=$RC out=$OUT"; fi
    if printf '%s' "$OUT" | grep -qiE 'warn.*#?11([^0-9]|$)'; then pass "abort-branch: the exit-1 issue is reported as a warning"
    else fail "abort-branch: the exit-1 issue is reported as a warning" "out=$OUT"; fi
    if [ "$(grep -c '^check [0-9]* --session-id f2920-ab$' "$STUB_ARGV_LOG")" -eq 3 ]; then pass "abort-branch: each check names this session (--session-id)"
    else fail "abort-branch: each check names this session (--session-id)" "argv=$(tr '\n' ',' < "$STUB_ARGV_LOG")"; fi
fi
case_end

case_begin "abort-branch-abandons-only-own-wip" "skills/worktree-end/scripts/abort-branch.sh"
if [ ! -f "$ABORT_BRANCH" ]; then
    fail "abort-branch: script exists (ownership case)" "$ABORT_BRANCH is missing"
else
    seed_state "f2920-own" "[61, 62, 63, 64]"
    : > "$STUB_LOG"
    export STUB_ANSWERS="check@61:0:other check@62:0:none check@63:2: check@64:0:same"
    OUT="$(cd "$CLEAN_WT" && run_with_timeout 60 bash "$ABORT_BRANCH" --session f2920-own 2>&1 </dev/null)"
    RC=$?
    if [ "$(calls)" = "check 61,check 62,check 63,check 64,abandon 64," ]; then pass "abort-branch: other/none/check-failure marks are not abandoned; same is"
    else fail "abort-branch: other/none/check-failure marks are not abandoned; same is" "calls=$(calls) out=$OUT"; fi
    if [ "$RC" -eq 0 ]; then pass "abort-branch: a not-own mark does not fail the cleanup"
    else fail "abort-branch: a not-own mark does not fail the cleanup" "rc=$RC out=$OUT"; fi
    missing=""
    for n in 61 62 63; do printf '%s' "$OUT" | grep -qiE "warn.*#$n([^0-9]|$)" || missing="$missing $n"; done
    if [ -z "$missing" ]; then pass "abort-branch: each skipped mark is reported as a warning"
    else fail "abort-branch: each skipped mark is reported as a warning" "no warning for:$missing out=$OUT"; fi
fi
case_end

case_begin "abort-branch-refuses-uncommitted-changes" "skills/worktree-end/scripts/abort-branch.sh"
if [ ! -f "$ABORT_BRANCH" ]; then
    fail "abort-branch: script exists (dirty case)" "$ABORT_BRANCH is missing"
else
    seed_state "f2920-dirty" "[41]"
    : > "$STUB_LOG"
    export STUB_ANSWERS=""
    OUT="$(cd "$DIRTY_WT" && run_with_timeout 60 bash "$ABORT_BRANCH" --session f2920-dirty 2>&1 </dev/null)"
    RC=$?
    if [ "$RC" -ne 0 ]; then pass "abort-branch: uncommitted changes make it exit non-zero"
    else fail "abort-branch: uncommitted changes make it exit non-zero" "rc=$RC out=$OUT"; fi
    if printf '%s' "$OUT" | grep -qiE 'uncommitted|unstaged|未コミット|file\.txt'; then pass "abort-branch: the refusal names the uncommitted change"
    else fail "abort-branch: the refusal names the uncommitted change" "out=$OUT"; fi
    if [ -z "$(calls)" ]; then pass "abort-branch: a refused run abandons no WIP mark"
    else fail "abort-branch: a refused run abandons no WIP mark" "calls=$(calls)"; fi
    if [ "$(git -C "$DIRTY_WT" diff --stat | wc -l)" -gt 0 ]; then pass "abort-branch: the uncommitted change is left in place"
    else fail "abort-branch: the uncommitted change is left in place" "the edit to file.txt is gone"; fi
fi
case_end

# has_line <file> <ere> — some line of <file> matches <ere>.
has_line() { grep -qE "$2" "$1"; }
case_begin "abort-branch-procedure-shape" "skills/worktree-end/scripts/abort-branch.md"
if [ ! -f "$ABORT_DOC" ] || [ ! -f "$ABORT_BRANCH" ]; then
    fail "abort-branch: procedure and script exist" "doc=$ABORT_DOC script=$ABORT_BRANCH"
else
    missing=""
    for id in WE-3 WE-5 WE-6 WE-7 WE-9 WE-9a; do has_line "$ABORT_DOC" "(^|[^0-9A-Za-z-])$id([^0-9a-z]|$)" || missing="$missing $id"; done
    has_line "$ABORT_DOC" '[Cc]ascade|カスケード' || missing="$missing cascade"
    if [ -z "$missing" ]; then pass "abort-branch.md keeps WE-3/5/6/7/9/9a and the cleanup cascade"
    else fail "abort-branch.md keeps WE-3/5/6/7/9/9a and the cleanup cascade" "missing:$missing"; fi
    unskipped=""
    for id in WE-4 WE-8 WE-17; do
        grep -E "(^|[^0-9A-Za-z-])$id([^0-9]|$)" "$ABORT_DOC" | grep -qiE 'skip|飛ばす|省く|しない' || unskipped="$unskipped $id"
    done
    grep -iE 'issue' "$ABORT_DOC" | grep -iE 'close' | grep -qiE 'skip|飛ばす|省く|しない' || unskipped="$unskipped issue-close"
    if [ -z "$unskipped" ]; then pass "abort-branch.md marks WE-4/8/17 and the issue close as skipped"
    else fail "abort-branch.md marks WE-4/8/17 and the issue close as skipped" "not marked skipped:$unskipped"; fi
    if has_line "$ABORT_DOC" 'branch -d' && ! has_line "$ABORT_DOC" 'branch -D'; then pass "abort-branch.md deletes the branch with -d, never -D"
    else fail "abort-branch.md deletes the branch with -d, never -D" "$(grep -nE 'branch -[dD]' "$ABORT_DOC")"; fi
    found="$(grep -nE 'pr-state|capture-env|doc-append|gh issue close|branch -D' "$ABORT_BRANCH")"
    if [ -z "$found" ]; then pass "abort-branch.sh runs none of the skipped steps"
    else fail "abort-branch.sh runs none of the skipped steps" "$found"; fi
    if has_line "$WE_DIR/SKILL.md" 'workflow-aborted-cleanup' && has_line "$WE_DIR/SKILL.md" 'abort-branch\.md'; then
        pass "worktree-end SKILL.md branches on workflow-aborted-cleanup into abort-branch.md"
    else fail "worktree-end SKILL.md branches on workflow-aborted-cleanup into abort-branch.md" "no REASON branch / pointer"; fi
fi
case_end

# The abort branch of SKILL.md: from its workflow-aborted-cleanup line to the next heading.
AWK_SECTION='function out(){ if (b ~ /workflow-aborted-cleanup/ && b ~ /abort-branch\.md/) printf "%s", b; b="" } /^#/{out()} {b=b $0 "\n"} END{out()}'
abort_block() { awk "$AWK_SECTION" "$WE_DIR/SKILL.md"; }
ids_of() { grep -oE 'WE-[0-9]+[a-z]?' | sort -u; }
case_begin "abort-branch-step-sets-wired" "skills/worktree-end/SKILL.md"
BLOCK="$(abort_block)"
if [ -z "$BLOCK" ]; then
    fail "SKILL.md: has a workflow-aborted-cleanup branch" "no section names both workflow-aborted-cleanup and abort-branch.md in $WE_DIR/SKILL.md"
else
    KEPT_LINE="$(printf '%s\n' "$BLOCK" | grep -iE 'keep|kept|残す')"
    SKIP_LINE="$(printf '%s\n' "$BLOCK" | grep -iE 'skip|飛ばす|省く')"
    KEPT="$(printf '%s\n' "$KEPT_LINE" | ids_of)"
    SKIPPED="$(printf '%s\n' "$SKIP_LINE" | ids_of)"
    if printf '%s\n' "$BLOCK" | grep -q 'abort-branch\.md'; then pass "SKILL.md: the abort branch points at abort-branch.md"
    else fail "SKILL.md: the abort branch points at abort-branch.md" "block=$BLOCK"; fi
    missing=""
    for id in WE-3 WE-5 WE-6 WE-7 WE-9 WE-9a; do printf '%s\n' "$KEPT" | grep -qx "$id" || missing="$missing $id"; done
    printf '%s\n' "$KEPT_LINE" | grep -qiE 'cascade|カスケード|WE-11' || missing="$missing cascade"
    if [ -z "$missing" ]; then pass "SKILL.md: the kept set lists WE-3/5/6/7/9/9a and the cascade"
    else fail "SKILL.md: the kept set lists WE-3/5/6/7/9/9a and the cascade" "missing:$missing kept-line=$KEPT_LINE"; fi
    missing=""
    for id in WE-4 WE-8 WE-17; do printf '%s\n' "$SKIPPED" | grep -qx "$id" || missing="$missing $id"; done
    if [ -z "$missing" ]; then pass "SKILL.md: the skipped set lists WE-4/8/17"
    else fail "SKILL.md: the skipped set lists WE-4/8/17" "missing:$missing skip-line=$SKIP_LINE"; fi
    both="$(comm -12 <(printf '%s\n' "$KEPT") <(printf '%s\n' "$SKIPPED") | grep -v '^$')"
    if [ -n "$KEPT" ] && [ -n "$SKIPPED" ] && [ -z "$both" ]; then pass "SKILL.md: the kept and skipped sets are disjoint"
    else fail "SKILL.md: the kept and skipped sets are disjoint" "in both:${both:-<empty set>} kept=$KEPT skipped=$SKIPPED"; fi
    # Every named ID must be a step heading of the normal path (SKILL.md or cleanup-cascade.md).
    REAL="$(grep -hE '^#{2,3} WE-' "$WE_DIR/SKILL.md" "$WE_DIR/scripts/cleanup-cascade.md" | ids_of)"
    unknown=""
    for id in $KEPT $SKIPPED; do printf '%s\n' "$REAL" | grep -qx "$id" || unknown="$unknown $id"; done
    if [ -n "$KEPT$SKIPPED" ] && [ -z "$unknown" ]; then pass "SKILL.md: every kept/skipped ID is a real step of the normal path"
    else fail "SKILL.md: every kept/skipped ID is a real step of the normal path" "unknown:${unknown:- <no IDs named>}"; fi
fi
case_end

# mk_branches <repo> — feat-merged (at HEAD) and feat-unmerged (one extra commit); HEAD stays put.
mk_branches() {
    git -C "$1" branch feat-merged
    git -C "$1" checkout -qb feat-unmerged
    echo extra >> "$1/file.txt"
    git -C "$1" -c user.name=t -c user.email=t@example.invalid commit -qam extra
    git -C "$1" checkout -q -
}
MAIN_REPO="$_ISOLATION_TMP_ROOT/main-repo"; mk_worktree "$MAIN_REPO"; mk_branches "$MAIN_REPO"
case_begin "abort-branch-deletes-branch-with-d" "skills/worktree-end/scripts/abort-branch.sh"
if [ ! -f "$ABORT_BRANCH" ]; then
    fail "abort-branch: script exists (branch delete)" "$ABORT_BRANCH is missing"
else
    OUT="$(cd "$MAIN_REPO" && run_with_timeout 60 bash "$ABORT_BRANCH" --delete-branch feat-merged --main "$(np "$MAIN_REPO")" 2>&1 </dev/null)"
    RC=$?
    if [ "$RC" -eq 0 ] && ! git -C "$MAIN_REPO" rev-parse -q --verify refs/heads/feat-merged >/dev/null; then
        pass "abort-branch: a merged branch is deleted"
    else fail "abort-branch: a merged branch is deleted" "rc=$RC out=$OUT"; fi
    OUT="$(cd "$MAIN_REPO" && run_with_timeout 60 bash "$ABORT_BRANCH" --delete-branch feat-unmerged --main "$(np "$MAIN_REPO")" 2>&1 </dev/null)"
    RC=$?
    if git -C "$MAIN_REPO" rev-parse -q --verify refs/heads/feat-unmerged >/dev/null; then
        pass "abort-branch: an unmerged branch survives (-d, never -D)"
    else fail "abort-branch: an unmerged branch survives (-d, never -D)" "feat-unmerged was deleted; out=$OUT"; fi
    if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qiE 'warn.*feat-unmerged|feat-unmerged.*(warn|unmerged|not fully merged|未 ?merge)'; then
        pass "abort-branch: the surviving branch is warned about without failing"
    else fail "abort-branch: the surviving branch is warned about without failing" "rc=$RC out=$OUT"; fi
fi
case_end

# The script resolves its own REPO_ROOT, so an AGENTS_MAIN_ROOT stub cannot observe a call: pin the
# skipped steps by the script's text (no reference to them) and by its observable calls (wip-state only).
case_begin "abort-branch-never-runs-skipped-steps" "skills/worktree-end/scripts/abort-branch.sh"
if [ ! -f "$ABORT_BRANCH" ]; then
    fail "abort-branch: script exists (skipped steps)" "$ABORT_BRANCH is missing"
else
    if ! grep -qE 'pr-state|capture-env|compose-doc-append-entry' "$ABORT_BRANCH"; then
        pass "abort-branch: the script references no pr-state / capture-env / doc-append"
    else fail "abort-branch: the script references no pr-state / capture-env / doc-append" "$(grep -nE 'pr-state|capture-env|compose-doc-append-entry' "$ABORT_BRANCH")"; fi
    seed_state "f2920-skip" "[51]"
    : > "$STUB_LOG"
    export STUB_ANSWERS="check@51:0:same"
    # A copy of the script under a fake root: its REPO_ROOT (from SCRIPT_DIR) then holds logging stubs for the
    # skipped steps, so a call to one of them is observable. read-abort-issues.js is a shim onto the real one.
    FAKE_ROOT="$_ISOLATION_TMP_ROOT/fake-root"; FAKE_SCRIPTS="$FAKE_ROOT/skills/worktree-end/scripts"
    SKIP_LOG="$_ISOLATION_TMP_ROOT/skipped-step-calls.log"; : > "$SKIP_LOG"; export SKIP_LOG
    mkdir -p "$FAKE_SCRIPTS" "$FAKE_ROOT/bin/workflow" "$FAKE_ROOT/bin/github-issues"
    cp "$ABORT_BRANCH" "$FAKE_SCRIPTS/abort-branch.sh"
    printf 'require("%s");\n' "$(np "$WE_DIR/scripts/read-abort-issues.js")" > "$FAKE_SCRIPTS/read-abort-issues.js"
    for stub in "$FAKE_SCRIPTS/capture-env.sh" "$FAKE_ROOT/bin/workflow/pr-state" "$FAKE_ROOT/bin/compose-doc-append-entry" "$FAKE_ROOT/bin/github-issues/wip-state.sh"; do
        printf '#!/usr/bin/env bash\necho "%s $*" >> "$SKIP_LOG"\n' "$(basename "$stub")" > "$stub"; chmod +x "$stub"
    done
    OUT="$(cd "$CLEAN_WT" && run_with_timeout 60 bash "$FAKE_SCRIPTS/abort-branch.sh" --session f2920-skip 2>&1 </dev/null)"
    RC=$?
    if [ "$RC" -eq 0 ] && [ "$(calls)" = "check 51,abandon 51," ]; then
        pass "abort-branch: a full run exits 0 and its only external calls are wip-state check/abandon"
    else fail "abort-branch: a full run exits 0 and its only external calls are wip-state check/abandon" "rc=$RC wip=$(calls) out=$OUT"; fi
    if [ "$(wc -c < "$SKIP_LOG")" -eq 0 ]; then pass "abort-branch: pr-state / capture-env / compose-doc-append-entry stubs under its REPO_ROOT are never called"
    else fail "abort-branch: pr-state / capture-env / compose-doc-append-entry stubs under its REPO_ROOT are never called" "called: $(tr '\n' ',' < "$SKIP_LOG")"; fi
    # Control: the stubs are reachable from that REPO_ROOT, so an empty log above means "not called", not "unreachable".
    bash "$FAKE_ROOT/bin/workflow/pr-state" probe; RC=$?
    if [ "$RC" -eq 0 ] && grep -q '^pr-state probe' "$SKIP_LOG"; then pass "abort-branch: control — a pr-state stub at the fake REPO_ROOT records its call"
    else fail "abort-branch: control — a pr-state stub at the fake REPO_ROOT records its call" "rc=$RC log=$(cat "$SKIP_LOG")"; fi
fi
case_end

case_begin "check-wip-owner-warns-only-on-other" "skills/issue-close-verified/scripts/check-wip-owner.sh"
if [ ! -f "$CHECK_OWNER" ]; then
    fail "check-wip-owner: script exists" "$CHECK_OWNER is missing"
else
    : > "$STUB_LOG"
    export STUB_ANSWERS="21:0:none 22:0:same 23:0:other"
    OUT="$(run_with_timeout 60 bash "$CHECK_OWNER" 21 22 23 2>&1 </dev/null)"
    RC=$?
    if [ "$(calls)" = "check 21,check 22,check 23," ]; then pass "check-wip-owner: runs wip-state check on each issue"
    else fail "check-wip-owner: runs wip-state check on each issue" "calls=$(calls)"; fi
    if [ "$RC" -eq 0 ]; then pass "check-wip-owner: exits 0 (a warning never blocks ICV-2)"
    else fail "check-wip-owner: exits 0 (a warning never blocks ICV-2)" "rc=$RC out=$OUT"; fi
    if printf '%s' "$OUT" | grep -qE '#?23([^0-9]|$)' && ! printf '%s' "$OUT" | grep -qE '#?2[12]([^0-9]|$)'; then
        pass "check-wip-owner: only the other-owned issue is warned about"
    else fail "check-wip-owner: only the other-owned issue is warned about" "out=$OUT"; fi
    : > "$STUB_LOG"
    export STUB_ANSWERS="31:0:none 32:0:same"
    OUT="$(run_with_timeout 60 bash "$CHECK_OWNER" 31 32 2>&1 </dev/null)"
    if [ -z "$OUT" ] && [ "$(calls)" = "check 31,check 32," ]; then pass "check-wip-owner: none/same print nothing"
    else fail "check-wip-owner: none/same print nothing" "out=$OUT calls=$(calls)"; fi
    : > "$STUB_LOG"
    export STUB_ANSWERS="41:2: 42:0:other 43:0:same"
    OUT="$(run_with_timeout 60 bash "$CHECK_OWNER" 41 42 43 2>&1 </dev/null)"
    RC=$?
    if [ "$RC" -eq 0 ] && [ "$(calls)" = "check 41,check 42,check 43," ]; then
        pass "check-wip-owner: a failing wip-state check does not stop later issues and exits 0"
    else fail "check-wip-owner: a failing wip-state check does not stop later issues and exits 0" "rc=$RC calls=$(calls) out=$OUT"; fi
    if printf '%s' "$OUT" | grep -qE '#41.*(failed|unknown)' && printf '%s' "$OUT" | grep -qE '#42.*another session'; then
        pass "check-wip-owner: a check failure warns 'owner unknown'; the later other-owned issue is still warned"
    else fail "check-wip-owner: a check failure warns 'owner unknown'; the later other-owned issue is still warned" "out=$OUT"; fi
fi
case_end

ICV_SKILL="$SCRIPT_CHECKOUT_ROOT/skills/issue-close-verified/SKILL.md"
case_begin "icv1-calls-check-wip-owner-before-icv2" "skills/issue-close-verified/SKILL.md"
if [ ! -f "$ICV_SKILL" ]; then
    fail "ICV SKILL.md exists" "$ICV_SKILL is missing"
else
    CALL_LN="$(grep -n 'scripts/check-wip-owner\.sh' "$ICV_SKILL" | head -n 1 | cut -d: -f1)"
    ICV2_LN="$(grep -nE '^ICV-2\.' "$ICV_SKILL" | head -n 1 | cut -d: -f1)"
    ICV1_LN="$(grep -nE '^ICV-1\.' "$ICV_SKILL" | head -n 1 | cut -d: -f1)"
    if [ -n "$CALL_LN" ] && [ -n "$ICV1_LN" ] && [ "$CALL_LN" -gt "$ICV1_LN" ]; then pass "SKILL.md: ICV-1 invokes scripts/check-wip-owner.sh"
    else fail "SKILL.md: ICV-1 invokes scripts/check-wip-owner.sh" "call=$CALL_LN icv1=$ICV1_LN"; fi
    if [ -n "$CALL_LN" ] && [ -n "$ICV2_LN" ] && [ "$CALL_LN" -lt "$ICV2_LN" ]; then pass "SKILL.md: check-wip-owner.sh call precedes the ICV-2 sentinel line"
    else fail "SKILL.md: check-wip-owner.sh call precedes the ICV-2 sentinel line" "call=$CALL_LN icv2=$ICV2_LN"; fi
fi
case_end

SHOW_STATE="$SCRIPT_CHECKOUT_ROOT/skills/workflow-abort-accepted/scripts/show-worktree-state.sh"
# mk_pushed <dir> — a fixture repo whose HEAD is pushed to a local bare remote (upstream set).
mk_pushed() {
    mk_worktree "$1"
    git init -q --bare "$1.git"
    git -C "$1" remote add origin "$(np "$1.git")"
    git -C "$1" push -q -u origin HEAD
}
case_begin "show-worktree-state-three-outputs" "skills/workflow-abort-accepted/scripts/show-worktree-state.sh"
if [ ! -f "$SHOW_STATE" ]; then
    fail "show-worktree-state: script exists" "$SHOW_STATE is missing"
else
    SW_CLEAN="$_ISOLATION_TMP_ROOT/sw-clean"; mk_pushed "$SW_CLEAN"
    OUT="$(cd "$SW_CLEAN" && run_with_timeout 60 bash "$SHOW_STATE" 2>&1 </dev/null)"; RC=$?
    if [ "$RC" -eq 0 ] && [ "$(printf '%s\n' "$OUT" | grep -c '^(none)$')" -eq 2 ]; then pass "show-worktree-state: a clean pushed repo reports (none) for both sections"
    else fail "show-worktree-state: a clean pushed repo reports (none) for both sections" "rc=$RC out=$OUT"; fi

    SW_DIRTY="$_ISOLATION_TMP_ROOT/sw-dirty"; mk_pushed "$SW_DIRTY"
    echo "tracked edit" >> "$SW_DIRTY/file.txt"
    OUT="$(cd "$SW_DIRTY" && run_with_timeout 60 bash "$SHOW_STATE" 2>&1 </dev/null)"; RC=$?
    UNCOMMITTED="$(printf '%s\n' "$OUT" | sed -n '/== uncommitted changes ==/,/== commits not on any remote branch ==/p')"
    if [ "$RC" -eq 0 ] && printf '%s' "$UNCOMMITTED" | grep -q 'file\.txt' && [ "$(printf '%s\n' "$OUT" | grep -c '^(none)$')" -eq 1 ]; then
        pass "show-worktree-state: an uncommitted tracked change is listed; no unpushed commits"
    else fail "show-worktree-state: an uncommitted tracked change is listed; no unpushed commits" "rc=$RC out=$OUT"; fi

    SW_AHEAD="$_ISOLATION_TMP_ROOT/sw-ahead"; mk_pushed "$SW_AHEAD"
    echo more >> "$SW_AHEAD/file.txt"
    git -C "$SW_AHEAD" -c user.name=t -c user.email=t@example.invalid commit -qam unpushed-commit
    OUT="$(cd "$SW_AHEAD" && run_with_timeout 60 bash "$SHOW_STATE" 2>&1 </dev/null)"; RC=$?
    UNPUSHED_SEC="$(printf '%s\n' "$OUT" | sed -n '/== commits not on any remote branch ==/,$p')"
    if [ "$RC" -eq 0 ] && printf '%s' "$UNPUSHED_SEC" | grep -q 'unpushed-commit' && [ "$(printf '%s\n' "$OUT" | grep -c '^(none)$')" -eq 1 ]; then
        pass "show-worktree-state: an unpushed commit is listed; no uncommitted changes"
    else fail "show-worktree-state: an unpushed commit is listed; no uncommitted changes" "rc=$RC out=$OUT"; fi
fi
case_end

WAV_SKILL="$SCRIPT_CHECKOUT_ROOT/skills/workflow-abort-accepted/SKILL.md"
case_begin "wav-skill-step-order" "skills/workflow-abort-accepted/SKILL.md"
if [ ! -f "$WAV_SKILL" ]; then
    fail "workflow-abort-accepted SKILL.md exists" "$WAV_SKILL is missing"
else
    WAV1_LN="$(grep -nE '^### WAV-1( |$)' "$WAV_SKILL" | head -n 1 | cut -d: -f1)"
    WAV2_LN="$(grep -nE '^### WAV-2( |$)' "$WAV_SKILL" | head -n 1 | cut -d: -f1)"
    SENT_LN="$(grep -n 'WORKFLOW_ABORT_ACCEPTED' "$WAV_SKILL" | grep -E 'echo' | head -n 1 | cut -d: -f1)"
    SHOW_LN="$(grep -n 'show-worktree-state\.sh' "$WAV_SKILL" | head -n 1 | cut -d: -f1)"
    if [ -n "$WAV1_LN" ] && [ -n "$WAV2_LN" ] && [ "$WAV1_LN" -lt "$WAV2_LN" ]; then pass "SKILL.md: WAV-1 precedes WAV-2"
    else fail "SKILL.md: WAV-1 precedes WAV-2" "wav1=$WAV1_LN wav2=$WAV2_LN"; fi
    if [ -n "$SHOW_LN" ] && [ -n "$SENT_LN" ] && [ -n "$WAV1_LN" ] && [ "$SHOW_LN" -gt "$WAV1_LN" ] && [ "$SHOW_LN" -lt "$SENT_LN" ]; then pass "SKILL.md: the show-worktree-state call sits in WAV-1, before the sentinel is emitted"
    else fail "SKILL.md: the show-worktree-state call sits in WAV-1, before the sentinel is emitted" "wav1=$WAV1_LN show=$SHOW_LN sentinel=$SENT_LN"; fi
    if grep -qE 'Never emit the sentinel on your own initiative — only when the user invoked this skill' "$WAV_SKILL"; then pass "SKILL.md: the sentinel is emitted only when the user invoked the skill"
    else fail "SKILL.md: the sentinel is emitted only when the user invoked the skill" "user-invocation-only condition wording is missing in $WAV_SKILL"; fi
fi
case_end

echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
