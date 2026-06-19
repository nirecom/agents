#!/bin/bash
# Tests: bin/review-step-numbers, skills/workflow-init/SKILL.md, skills/worktree-end/SKILL.md, skills/issue-close-finalize/SKILL.md, skills/make-detail-plan/SKILL.md, skills/clarify-intent/SKILL.md, skills/make-outline-plan/SKILL.md, skills/session-close/SKILL.md, agents/issue-close-finalize-worker.md
# Tags: renumber, step-rename, sweep, issue-614, issue-971, scope:issue-specific
# Verifies renumber sweep tool exists and new step labels appear in SKILL.md files.

# L3 gap: These tests invoke `bash bin/review-step-numbers` directly in
# constructed temp git repos (L2 broad integration). The workflow gate path
# (PostToolUse → workflow-gate.js calling review-step-numbers as a WF-CODE-6
# parallel step) is only exercised end-to-end in a live workflow session (L3).
# An L3 test would need `claude -p` with a real commit containing a decimal
# step label and assertion that the commit is blocked.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# R1: bin/review-step-numbers exists
SWEEP_SCRIPT="$AGENTS_DIR/bin/review-step-numbers"
if [ -f "$SWEEP_SCRIPT" ]; then
    pass "R1: bin/review-step-numbers exists"
else
    fail "R1: bin/review-step-numbers missing"
fi

# R2: bin/review-step-numbers exits 0 in --all mode (no legacy patterns in repo)
if [ -f "$SWEEP_SCRIPT" ]; then
    if ( cd "$AGENTS_DIR" && bash bin/review-step-numbers --all ) >/dev/null 2>&1; then
        pass "R2: bin/review-step-numbers --all exits 0 (no decimal step labels present)"
    else
        fail "R2: bin/review-step-numbers --all exited non-zero (decimal step labels still present)"
    fi
else
    fail "R2: bin/review-step-numbers not runnable (missing)"
fi

# Helper for literal grep check
check_literal() {
    local label="$1"
    local literal="$2"
    local rel="$3"
    local path="$AGENTS_DIR/$rel"
    if [ ! -f "$path" ]; then
        fail "$label: $rel missing"
        return
    fi
    if grep -qF "$literal" "$path"; then
        pass "$label: '$literal' appears in $rel"
    else
        fail "$label: '$literal' not found in $rel"
    fi
}

# Helper for absence check
check_absent() {
    local label="$1"
    local literal="$2"
    local rel="$3"
    local path="$AGENTS_DIR/$rel"
    if [ ! -f "$path" ]; then
        fail "$label: $rel missing"
        return
    fi
    if grep -qF "$literal" "$path"; then
        fail "$label: '$literal' still present in $rel (should be absent)"
    else
        pass "$label: '$literal' absent from $rel"
    fi
}

# R3: "WI-11" in workflow-init/SKILL.md (post-#968 renumber: WI-11 = post-check)
check_literal "R3" "WI-11" "skills/workflow-init/SKILL.md"

# R4: "WE-20" in worktree-end/scripts/cleanup-cascade.sh (canonical spec for WE-15..WE-22)
check_literal "R4" "WE-20" "skills/worktree-end/scripts/cleanup-cascade.sh"

# R4a: WE-15 and WE-22 both present in cleanup-cascade.sh (renumber boundary check)
check_literal "R4a" "WE-15" "skills/worktree-end/scripts/cleanup-cascade.sh"
check_literal "R4b" "WE-22" "skills/worktree-end/scripts/cleanup-cascade.sh"

# R5: "ICF-A" in issue-close-finalize/SKILL.md
check_literal "R5" "ICF-A" "skills/issue-close-finalize/SKILL.md"

# R6: "MDP-5" in make-detail-plan/SKILL.md
check_literal "R6" "MDP-5" "skills/make-detail-plan/SKILL.md"

# R7: "CI-1" in clarify-intent/SKILL.md
check_literal "R7" "CI-1" "skills/clarify-intent/SKILL.md"

# R8: "MOP-0" in make-outline-plan/SKILL.md
check_literal "R8" "MOP-0" "skills/make-outline-plan/SKILL.md"

# R9: "SC-1" in session-close/SKILL.md
check_literal "R9" "SC-1" "skills/session-close/SKILL.md"

# R10: "written_by_step_6h" literal preserved in agents/issue-close-finalize-worker.md
check_literal "R10" "written_by_step_6h" "agents/issue-close-finalize-worker.md"

# --- New assertions for #971 (step numbering rule + review-step-numbers) ---

# R11: No WE-4.5 decimal label in non-test tracked files (mirrors lint Tier 2 exclusion)
R11_HITS=$(cd "$AGENTS_DIR" && git ls-files -- '*.md' '*.sh' | \
    grep -v '^tests/' | grep -v '^docs/history' | grep -v '^CHANGELOG' | \
    xargs grep -lF 'WE-4.5' 2>/dev/null || true)
if [ -z "$R11_HITS" ]; then
    pass "R11: No WE-4.5 decimal label in tracked files"
else
    fail "R11: WE-4.5 decimal label found: $R11_HITS"
fi

# R12: WE-2.5 absent from skills/worktree-end/SKILL.md (post-renumber)
check_absent "R12" "WE-2.5" "skills/worktree-end/SKILL.md"

# R13: SC-3.5 and SC-3.6 absent from skills/session-close/SKILL.md (post-renumber)
check_absent "R13a" "SC-3.5" "skills/session-close/SKILL.md"
check_absent "R13b" "SC-3.6" "skills/session-close/SKILL.md"

# R14: "Step 6.5" absent from skills/_shared/survey-artifact-valid.md (post-update)
check_absent "R14" "Step 6.5" "skills/_shared/survey-artifact-valid.md"

# R15: review-step-numbers wired into CLAUDE.md WF-CODE-6
check_literal "R15" "review-step-numbers" "CLAUDE.md"

# R16: review-step-numbers present in both installer scripts
check_literal "R16a" "review-step-numbers" "install/win/dotfileslink.ps1"
check_literal "R16b" "review-step-numbers" "install/linux/dotfileslink.sh"

# R17: SC-4 absent from architecture docs (renamed to SC-6 in Phase 3)
check_absent "R17a" "SC-4" "docs/architecture/claude-code.md"
check_absent "R17b" "SC-4" "docs/architecture/claude-code/workflow.md"

# R18: diff-mode HARD-finding exits 1
if command -v rg >/dev/null 2>&1; then
    _TMPGIT=$(mktemp -d)
    git -C "$_TMPGIT" init --quiet
    git -C "$_TMPGIT" config user.email "test@example.com"
    git -C "$_TMPGIT" config user.name "Test"
    git -C "$_TMPGIT" config core.hooksPath /dev/null
    printf '## Step WE-1\nSome content\n' > "$_TMPGIT/clean.md"
    git -C "$_TMPGIT" add . && git -C "$_TMPGIT" commit --quiet -m "baseline"
    _BASELINE=$(git -C "$_TMPGIT" rev-parse HEAD)
    printf '## WE-4.5: inserted step\n' > "$_TMPGIT/bad.md"
    git -C "$_TMPGIT" add . && git -C "$_TMPGIT" commit --quiet -m "add violation"
    _R18OUT=$(cd "$_TMPGIT" && bash "$AGENTS_DIR/bin/review-step-numbers" --base "$_BASELINE" 2>&1)
    _R18RC=$?
    rm -rf "$_TMPGIT"
    if [ "$_R18RC" -eq 1 ]; then
        pass "R18: diff-mode HARD-finding exits 1"
    else
        fail "R18: diff-mode HARD-finding should exit 1, got $_R18RC"
    fi
    if echo "$_R18OUT" | grep -q "^HARD:"; then
        pass "R18a: diff-mode HARD-finding output contains 'HARD:'"
    else
        fail "R18a: diff-mode HARD-finding output missing 'HARD:' — got: $_R18OUT"
    fi
else
    pass "R18: rg not in PATH — diff-mode HARD-finding test skipped (correct SKIP behaviour)"
    pass "R18a: rg not in PATH — diff-mode HARD-finding test skipped (correct SKIP behaviour)"
fi

# R19: SKIPPED when --base has no argument
_R19OUT=$(bash "$SWEEP_SCRIPT" --base 2>&1)
_R19RC=$?
if [ "$_R19RC" -eq 0 ] && echo "$_R19OUT" | grep -q "SKIPPED"; then
    pass "R19: --base missing argument → exit 0 + SKIPPED"
else
    fail "R19: --base missing argument should exit 0 with SKIPPED, got rc=$_R19RC out=$_R19OUT"
fi

# R20: SKIPPED when --all and --base are both given
_R20OUT=$(bash "$SWEEP_SCRIPT" --all --base origin/main 2>&1)
_R20RC=$?
if [ "$_R20RC" -eq 0 ] && echo "$_R20OUT" | grep -q "SKIPPED"; then
    pass "R20: --all --base mutually exclusive → exit 0 + SKIPPED"
else
    fail "R20: --all --base should exit 0 with SKIPPED, got rc=$_R20RC out=$_R20OUT"
fi

# R21: SKIPPED when merge-base cannot be resolved
_R21OUT=$(cd "$AGENTS_DIR" && bash bin/review-step-numbers --base totally-nonexistent-sha 2>&1)
_R21RC=$?
if [ "$_R21RC" -eq 0 ] && echo "$_R21OUT" | grep -q "SKIPPED"; then
    pass "R21: unresolvable --base → exit 0 + SKIPPED"
else
    fail "R21: unresolvable --base should exit 0 with SKIPPED, got rc=$_R21RC out=$_R21OUT"
fi

# R22: --all mode with HARD-finding exits 0 (discovery, not gate)
if command -v rg >/dev/null 2>&1; then
    _TMPALL=$(mktemp -d)
    git -C "$_TMPALL" init --quiet
    git -C "$_TMPALL" config user.email "test@example.com"
    git -C "$_TMPALL" config user.name "Test"
    git -C "$_TMPALL" config core.hooksPath /dev/null
    printf '## WE-4.5: violation\n' > "$_TMPALL/bad.md"
    git -C "$_TMPALL" add . && git -C "$_TMPALL" commit --quiet -m "violation"
    _R22OUT=$(cd "$_TMPALL" && bash "$AGENTS_DIR/bin/review-step-numbers" --all 2>&1)
    _R22RC=$?
    rm -rf "$_TMPALL"
    if [ "$_R22RC" -eq 0 ]; then
        pass "R22: --all mode with HARD-finding exits 0 (discovery asymmetry)"
    else
        fail "R22: --all mode with HARD-finding should exit 0, got $_R22RC"
    fi
    if echo "$_R22OUT" | grep -q "HARD:"; then
        pass "R22a: --all mode lists HARD-finding in output"
    else
        fail "R22a: --all mode should list HARD-finding, got: $_R22OUT"
    fi
else
    pass "R22: rg not in PATH — --all HARD-finding test skipped (correct SKIP behaviour)"
    pass "R22a: rg not in PATH — --all HARD-finding test skipped (correct SKIP behaviour)"
fi

# R23: unknown flag is ignored (stderr warning) — does not corrupt exit code
# Gated on rg: the rg guard at the top of the script exits before arg parsing when rg is absent
if command -v rg >/dev/null 2>&1; then
    _R23OUT=$(bash "$SWEEP_SCRIPT" --unknown-flag --all 2>&1)
    _R23RC=$?
    if [ "$_R23RC" -eq 0 ] && echo "$_R23OUT" | grep -q "Unknown argument"; then
        pass "R23: unknown flag → exit 0 + 'Unknown argument' in stderr"
    else
        fail "R23: unknown flag should exit 0 with 'Unknown argument' warning, got rc=$_R23RC out=$_R23OUT"
    fi
else
    pass "R23: rg not in PATH — unknown-flag test skipped (script exits before arg parsing)"
fi

# R24: diff mode "No diff-mode files to scan" path (all changed files excluded by tier)
# Gated on rg: the rg guard at the top of the script exits before diff mode when rg is absent
if command -v rg >/dev/null 2>&1; then
    _TMPHIST=$(mktemp -d)
    git -C "$_TMPHIST" init --quiet
    git -C "$_TMPHIST" config user.email "test@example.com"
    git -C "$_TMPHIST" config user.name "Test"
    git -C "$_TMPHIST" config core.hooksPath /dev/null
    mkdir -p "$_TMPHIST/docs"
    printf '### entry 1\nBackground: foo\n' > "$_TMPHIST/docs/history.md"
    git -C "$_TMPHIST" add . && git -C "$_TMPHIST" commit --quiet -m "baseline"
    _HIST_BASE=$(git -C "$_TMPHIST" rev-parse HEAD)
    printf '### entry 2\nBackground: bar\n' >> "$_TMPHIST/docs/history.md"
    git -C "$_TMPHIST" add . && git -C "$_TMPHIST" commit --quiet -m "append history"
    _R24OUT=$(cd "$_TMPHIST" && bash "$AGENTS_DIR/bin/review-step-numbers" --base "$_HIST_BASE" 2>&1)
    _R24RC=$?
    rm -rf "$_TMPHIST"
    if [ "$_R24RC" -eq 0 ] && echo "$_R24OUT" | grep -q "No diff-mode files to scan"; then
        pass "R24: excluded-only diff → exit 0 + 'No diff-mode files to scan'"
    else
        fail "R24: excluded-only diff should exit 0 with no-scan message, got rc=$_R24RC out=$_R24OUT"
    fi
else
    pass "R24: rg not in PATH — excluded-only diff test skipped (script exits before diff mode)"
fi

# R25: staged-only change (CHANGED_STAGED path) with HARD-finding exits 1
if command -v rg >/dev/null 2>&1; then
    _TMPSTG=$(mktemp -d)
    git -C "$_TMPSTG" init --quiet
    git -C "$_TMPSTG" config user.email "test@example.com"
    git -C "$_TMPSTG" config user.name "Test"
    git -C "$_TMPSTG" config core.hooksPath /dev/null
    printf '## clean\n' > "$_TMPSTG/clean.md"
    git -C "$_TMPSTG" add . && git -C "$_TMPSTG" commit --quiet -m "baseline"
    _STG_BASE=$(git -C "$_TMPSTG" rev-parse HEAD)
    printf '## WE-7.5: staged violation\n' > "$_TMPSTG/staged.md"
    git -C "$_TMPSTG" add staged.md
    _R25OUT=$(cd "$_TMPSTG" && bash "$AGENTS_DIR/bin/review-step-numbers" --base "$_STG_BASE" 2>&1)
    _R25RC=$?
    rm -rf "$_TMPSTG"
    if [ "$_R25RC" -eq 1 ]; then
        pass "R25: staged-only HARD-finding exits 1"
    else
        fail "R25: staged-only HARD-finding should exit 1, got $_R25RC out=$_R25OUT"
    fi
    if echo "$_R25OUT" | grep -q "^HARD:"; then
        pass "R25a: staged-only HARD-finding output contains 'HARD:'"
    else
        fail "R25a: staged-only HARD-finding output missing 'HARD:' — got: $_R25OUT"
    fi
else
    pass "R25: rg not in PATH — staged-only HARD-finding test skipped"
    pass "R25a: rg not in PATH — staged-only HARD-finding test skipped"
fi

# R26: run_targeted detects ### Step 0 in skills/clarify-intent/SKILL.md (--all mode)
if command -v rg >/dev/null 2>&1; then
    _TMPTGT=$(mktemp -d)
    mkdir -p "$_TMPTGT/skills/clarify-intent"
    printf '### Step 0: legacy heading\nSome content\n' > "$_TMPTGT/skills/clarify-intent/SKILL.md"
    _R26OUT=$(cd "$_TMPTGT" && bash "$AGENTS_DIR/bin/review-step-numbers" --all 2>&1)
    _R26RC=$?
    rm -rf "$_TMPTGT"
    if [ "$_R26RC" -eq 0 ]; then
        pass "R26: run_targeted in --all mode exits 0 (not a gate)"
    else
        fail "R26: run_targeted in --all mode should exit 0, got $_R26RC"
    fi
    if echo "$_R26OUT" | grep -q "HARD:"; then
        pass "R26a: run_targeted HARD detection reports finding in output"
    else
        fail "R26a: run_targeted should report HARD:, got: $_R26OUT"
    fi
else
    pass "R26: rg not in PATH — run_targeted detection test skipped"
    pass "R26a: rg not in PATH — run_targeted detection test skipped"
fi

# R27: unstaged working-tree change with HARD-finding exits 1
if command -v rg >/dev/null 2>&1; then
    _TMPWT=$(mktemp -d)
    git -C "$_TMPWT" init --quiet
    git -C "$_TMPWT" config user.email "test@example.com"
    git -C "$_TMPWT" config user.name "Test"
    git -C "$_TMPWT" config core.hooksPath /dev/null
    printf '## clean\n' > "$_TMPWT/clean.md"
    git -C "$_TMPWT" add . && git -C "$_TMPWT" commit --quiet -m "baseline"
    _WT_BASE=$(git -C "$_TMPWT" rev-parse HEAD)
    printf '## WE-9.5: unstaged violation\n' > "$_TMPWT/unstaged.md"
    _R27OUT=$(cd "$_TMPWT" && bash "$AGENTS_DIR/bin/review-step-numbers" --base "$_WT_BASE" 2>&1)
    _R27RC=$?
    rm -rf "$_TMPWT"
    if [ "$_R27RC" -eq 1 ]; then
        pass "R27: unstaged HARD-finding exits 1"
    else
        fail "R27: unstaged HARD-finding should exit 1, got $_R27RC out=$_R27OUT"
    fi
else
    pass "R27: rg not in PATH — unstaged HARD-finding test skipped"
fi

# R28: untracked file with HARD-finding exits 1
if command -v rg >/dev/null 2>&1; then
    _TMPUT=$(mktemp -d)
    git -C "$_TMPUT" init --quiet
    git -C "$_TMPUT" config user.email "test@example.com"
    git -C "$_TMPUT" config user.name "Test"
    git -C "$_TMPUT" config core.hooksPath /dev/null
    printf '## clean\n' > "$_TMPUT/clean.md"
    git -C "$_TMPUT" add . && git -C "$_TMPUT" commit --quiet -m "baseline"
    _UT_BASE=$(git -C "$_TMPUT" rev-parse HEAD)
    printf '## WE-11.5: untracked violation\n' > "$_TMPUT/untracked.md"
    _R28OUT=$(cd "$_TMPUT" && bash "$AGENTS_DIR/bin/review-step-numbers" --base "$_UT_BASE" 2>&1)
    _R28RC=$?
    rm -rf "$_TMPUT"
    if [ "$_R28RC" -eq 1 ]; then
        pass "R28: untracked file HARD-finding exits 1"
    else
        fail "R28: untracked file HARD-finding should exit 1, got $_R28RC out=$_R28OUT"
    fi
else
    pass "R28: rg not in PATH — untracked file HARD-finding test skipped"
fi

# R29: LEGACY_PATTERNS ("Step 6a") triggers HARD in diff mode
if command -v rg >/dev/null 2>&1; then
    _TMPLG=$(mktemp -d)
    git -C "$_TMPLG" init --quiet
    git -C "$_TMPLG" config user.email "test@example.com"
    git -C "$_TMPLG" config user.name "Test"
    git -C "$_TMPLG" config core.hooksPath /dev/null
    printf '## clean\n' > "$_TMPLG/clean.md"
    git -C "$_TMPLG" add . && git -C "$_TMPLG" commit --quiet -m "baseline"
    _LG_BASE=$(git -C "$_TMPLG" rev-parse HEAD)
    printf '### Step 6a: legacy step\n' > "$_TMPLG/legacy.md"
    git -C "$_TMPLG" add . && git -C "$_TMPLG" commit --quiet -m "add legacy"
    _R29OUT=$(cd "$_TMPLG" && bash "$AGENTS_DIR/bin/review-step-numbers" --base "$_LG_BASE" 2>&1)
    _R29RC=$?
    rm -rf "$_TMPLG"
    if [ "$_R29RC" -eq 1 ] && echo "$_R29OUT" | grep -q "^HARD:"; then
        pass "R29: LEGACY_PATTERNS (Step 6a) triggers HARD exit 1 in diff mode"
    else
        fail "R29: LEGACY_PATTERNS should exit 1 with HARD:, got rc=$_R29RC out=$_R29OUT"
    fi
else
    pass "R29: rg not in PATH — LEGACY_PATTERNS diff-mode test skipped"
fi

# R30: run_targeted detects ### Step 0 in make-outline-plan/SKILL.md
if command -v rg >/dev/null 2>&1; then
    _TMPMOP=$(mktemp -d)
    mkdir -p "$_TMPMOP/skills/make-outline-plan"
    printf '### Step 0: legacy heading\n' > "$_TMPMOP/skills/make-outline-plan/SKILL.md"
    _R30OUT=$(cd "$_TMPMOP" && bash "$AGENTS_DIR/bin/review-step-numbers" --all 2>&1)
    rm -rf "$_TMPMOP"
    if echo "$_R30OUT" | grep -q "HARD:"; then
        pass "R30: run_targeted detects ### Step 0 in make-outline-plan/SKILL.md"
    else
        fail "R30: run_targeted should report HARD: for make-outline-plan, got: $_R30OUT"
    fi
else
    pass "R30: rg not in PATH — make-outline-plan targeted test skipped"
fi

# R31: run_targeted detects ## Step [0-9] in session-close/SKILL.md
if command -v rg >/dev/null 2>&1; then
    _TMPSC=$(mktemp -d)
    mkdir -p "$_TMPSC/skills/session-close"
    printf '## Step 1: plain integer heading\n' > "$_TMPSC/skills/session-close/SKILL.md"
    _R31OUT=$(cd "$_TMPSC" && bash "$AGENTS_DIR/bin/review-step-numbers" --all 2>&1)
    rm -rf "$_TMPSC"
    if echo "$_R31OUT" | grep -q "HARD:"; then
        pass "R31: run_targeted detects ## Step [0-9] in session-close/SKILL.md"
    else
        fail "R31: run_targeted should report HARD: for session-close, got: $_R31OUT"
    fi
else
    pass "R31: rg not in PATH — session-close targeted test skipped"
fi

# R32: --all mode excludes docs/history.md even when it contains a decimal step label
if command -v rg >/dev/null 2>&1; then
    _TMPEX=$(mktemp -d)
    mkdir -p "$_TMPEX/docs"
    printf '### WE-4.5: historical entry (excluded)\n' > "$_TMPEX/docs/history.md"
    _R32OUT=$(cd "$_TMPEX" && bash "$AGENTS_DIR/bin/review-step-numbers" --all 2>&1)
    rm -rf "$_TMPEX"
    if echo "$_R32OUT" | grep -q "No decimal step-label violations found"; then
        pass "R32: --all mode excludes docs/history.md (Tier 1 exclusion)"
    else
        fail "R32: --all should skip docs/history.md, got: $_R32OUT"
    fi
else
    pass "R32: rg not in PATH — --all exclusion test skipped"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
