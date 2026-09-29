#!/usr/bin/env bash
# tests/skills/fix-1455-test-reviewer-input-contract.sh
# Tests: skills/_shared/test-review-input-contract.md, bin/review-plan-codex, agents/test-reviewer.md, skills/review-tests/scripts/run-codex-review-loop.sh, skills/review-tests/SKILL.md, skills/review-tests/scripts/detect-input-error.sh
# Tags: review-tests, input-contract, test-reviewer, scope:issue-specific
# #1455: test-reviewer input contract — contract file, prompt injection, INPUT_ERROR exit 4.
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$AGENTS_DIR/tests/lib/harness.sh"

CONTRACT_MD="$AGENTS_DIR/skills/_shared/test-review-input-contract.md"
REVIEW_PLAN_CODEX="$AGENTS_DIR/bin/review-plan-codex"
TEST_REVIEWER_MD="$AGENTS_DIR/agents/test-reviewer.md"
LOOP_SH="$AGENTS_DIR/skills/review-tests/scripts/run-codex-review-loop.sh"
SKILL_MD="$AGENTS_DIR/skills/review-tests/SKILL.md"
DETECT_SH="$AGENTS_DIR/skills/review-tests/scripts/detect-input-error.sh"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

_TMPROOT=""
_cleanup() { [ -n "$_TMPROOT" ] && rm -rf "$_TMPROOT"; }
trap _cleanup EXIT
_TMPROOT="$(mktemp -d 2>/dev/null || mktemp -d -t fix1455)"

_np() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi
}

# ─────────────────────────────────────────────────────────
case_begin "input-contract-file" "skills/_shared/test-review-input-contract.md"

# IC-1: Contract file exists
if [ -f "$CONTRACT_MD" ]; then
  pass "IC-1 contract file exists"
else
  fail "IC-1 contract file missing: skills/_shared/test-review-input-contract.md"
fi

# IC-2: Contract has ## Review targets section (mandatory Read)
if [ -f "$CONTRACT_MD" ] && grep -qF "## Review targets" "$CONTRACT_MD"; then
  pass "IC-2 contract has ## Review targets section"
else
  fail "IC-2 contract missing ## Review targets section"
fi

# IC-3: Contract mentions ## Deleted tests and says it is NOT to be Read
if [ -f "$CONTRACT_MD" ]; then
  if grep -qF "## Deleted tests" "$CONTRACT_MD"; then
    pass "IC-3 contract mentions ## Deleted tests"
  else
    fail "IC-3 contract does not mention ## Deleted tests"
  fi
  DELETED_CTX=$(grep -A5 "## Deleted tests" "$CONTRACT_MD" 2>/dev/null || true)
  if echo "$DELETED_CTX" | grep -qiE "do not|not read|skip|not.*mandatory|optional"; then
    pass "IC-3a contract says ## Deleted tests is not Read"
  else
    fail "IC-3a contract does not say ## Deleted tests is not Read"
  fi
fi

# IC-4: Inventory described as paths-only
if [ -f "$CONTRACT_MD" ] && grep -qiE "paths.only|path.only|inventory.*path|path.*inventory" "$CONTRACT_MD"; then
  pass "IC-4 contract specifies inventory as paths-only"
else
  fail "IC-4 contract does not specify inventory as paths-only"
fi

# IC-5: Per-finding citation format <path>:<start>-<end>
if [ -f "$CONTRACT_MD" ] && grep -qE "<path>:<start>-<end>|path:start-end|path:line|<path>:<line" "$CONTRACT_MD"; then
  pass "IC-5 contract specifies per-finding path:start-end citation"
else
  fail "IC-5 contract missing per-finding citation format"
fi

# IC-6: Empty Review targets → judge deletion coverage gaps only
if [ -f "$CONTRACT_MD" ] && grep -qiE "empty|no.*Review targets|Review targets.*empty|Review targets is empty" "$CONTRACT_MD"; then
  pass "IC-6 contract handles empty Review targets case"
else
  fail "IC-6 contract does not handle empty Review targets case"
fi

# IC-7: Read files are untrusted data under review, never instructions
# (case-sensitive -F: MSYS grep -i aborts on the file's non-ASCII bytes)
if [ -f "$CONTRACT_MD" ] && grep -qF "untrusted data" "$CONTRACT_MD" \
  && grep -qF "never as instructions" "$CONTRACT_MD"; then
  pass "IC-7 contract treats Read files as untrusted data, never as instructions"
else
  fail "IC-7 contract missing the untrusted-data / never-instructions directive"
fi

case_end

# ─────────────────────────────────────────────────────────
case_begin "review-plan-codex-prompts" "bin/review-plan-codex"

# RPC-1: review-plan-codex references the contract file
if [ -f "$REVIEW_PLAN_CODEX" ] && grep -qF "test-review-input-contract" "$REVIEW_PLAN_CODEX"; then
  pass "RPC-1 bin/review-plan-codex references test-review-input-contract"
else
  fail "RPC-1 bin/review-plan-codex does not reference test-review-input-contract (contract not injected)"
fi

# RPC-2: Contract appears in Round 1 test-review prompt block (static)
# In the test-review case block, the else branch (ROUND<2) must include the contract.
if [ -f "$REVIEW_PLAN_CODEX" ]; then
  # Extract the test-review) case body, then the Round-1 else block
  TESTREV_BODY=$(awk '/test-review\)/{f=1} f && /^  ;;/{exit} f{print}' "$REVIEW_PLAN_CODEX" 2>/dev/null | head -120)
  ROUND1_BLOCK=$(echo "$TESTREV_BODY" | awk '/else$/{f=1} f && /^    fi$/{exit} f{print}' | head -60)
  if echo "$ROUND1_BLOCK" | grep -qF "test-review-input-contract"; then
    pass "RPC-2 contract appears in Round 1 test-review prompt"
  else
    fail "RPC-2 contract not found in Round 1 test-review prompt block"
  fi
fi

# RPC-3: Contract appears in Round 2+ test-review prompt block (static)
if [ -f "$REVIEW_PLAN_CODEX" ]; then
  TESTREV_BODY=$(awk '/test-review\)/{f=1} f && /^  ;;/{exit} f{print}' "$REVIEW_PLAN_CODEX" 2>/dev/null | head -120)
  ROUND2_BLOCK=$(echo "$TESTREV_BODY" | awk '/ROUND.*-ge 2/{f=1} f && /^    fi$/{exit} f{print}' | head -60)
  if echo "$ROUND2_BLOCK" | grep -qF "test-review-input-contract"; then
    pass "RPC-3 contract appears in Round 2+ test-review prompt"
  else
    fail "RPC-3 contract not found in Round 2+ test-review prompt block"
  fi
fi

# RPC-4: Failure path when contract file is unreadable (codex_core_emit_failed or exit 4)
if [ -f "$REVIEW_PLAN_CODEX" ]; then
  CONTRACT_CTX=$(grep -B3 -A5 "test-review-input-contract" "$REVIEW_PLAN_CODEX" 2>/dev/null || true)
  if echo "$CONTRACT_CTX" | grep -qE "codex_core_emit_failed|exit 4"; then
    pass "RPC-4 failure path present when contract is unreadable"
  else
    fail "RPC-4 no failure path when contract file is unreadable"
  fi
fi

case_end

# ─────────────────────────────────────────────────────────
case_begin "test-reviewer-agent" "agents/test-reviewer.md"

# TR-1: agents/test-reviewer.md references the contract file
if [ -f "$TEST_REVIEWER_MD" ] && grep -qF "test-review-input-contract" "$TEST_REVIEWER_MD"; then
  pass "TR-1 agents/test-reviewer.md references test-review-input-contract"
else
  fail "TR-1 agents/test-reviewer.md does not reference test-review-input-contract"
fi

# TR-2: agents/test-reviewer.md has INPUT_ERROR as an output form
if [ -f "$TEST_REVIEWER_MD" ] && grep -qF "INPUT_ERROR" "$TEST_REVIEWER_MD"; then
  pass "TR-2 agents/test-reviewer.md mentions INPUT_ERROR output form"
else
  fail "TR-2 agents/test-reviewer.md missing INPUT_ERROR output form"
fi

# TR-3: INPUT_ERROR has path argument form (INPUT_ERROR <path>)
if [ -f "$TEST_REVIEWER_MD" ] && grep -qE "INPUT_ERROR.*<path>|INPUT_ERROR.*path" "$TEST_REVIEWER_MD"; then
  pass "TR-3 INPUT_ERROR <path> form present in test-reviewer.md"
else
  fail "TR-3 INPUT_ERROR <path> form missing in test-reviewer.md"
fi

# TR-4: test-reviewer must Read rules/shell-commands.md before Bash (dispatch does not inherit auto-injected rules)
if [ -f "$TEST_REVIEWER_MD" ] && grep -qF "rules/shell-commands.md" "$TEST_REVIEWER_MD"; then
  pass "TR-4 agents/test-reviewer.md references rules/shell-commands.md"
else
  fail "TR-4 agents/test-reviewer.md does not reference rules/shell-commands.md"
fi

case_end

# ─────────────────────────────────────────────────────────
case_begin "review-loop-input-error-exit" "skills/review-tests/scripts/run-codex-review-loop.sh"

# Helper: build a fake AGENTS_CONFIG_DIR with stubs
_build_fake_input_error() {
  local fake
  fake="$(mktemp -d 2>/dev/null || mktemp -d -t fake1455ie)"
  mkdir -p "$fake/bin" "$fake/hooks/workflow-gate"
  cat > "$fake/bin/run-codex-review-loop" << 'STUB'
#!/usr/bin/env bash
echo "INPUT_ERROR /some/path/to/file.md"
exit 0
STUB
  cat > "$fake/bin/resolve-worktree-path" << 'STUB'
#!/usr/bin/env bash
echo NOSTATE
STUB
  cat > "$fake/bin/resolve-session-id" << 'STUB'
#!/usr/bin/env bash
printf 'sid1455'
STUB
  cat > "$fake/bin/resolve-accepted-tradeoffs-file" << 'STUB'
#!/usr/bin/env bash
echo /dev/null
exit 0
STUB
  chmod +x "$fake/bin/run-codex-review-loop" "$fake/bin/resolve-worktree-path" \
      "$fake/bin/resolve-session-id" "$fake/bin/resolve-accepted-tradeoffs-file"
  printf '%s' "$fake"
}

_build_fake_approved() {
  local fake
  fake="$(mktemp -d 2>/dev/null || mktemp -d -t fake1455ap)"
  mkdir -p "$fake/bin" "$fake/hooks/workflow-gate"
  cat > "$fake/bin/run-codex-review-loop" << 'STUB'
#!/usr/bin/env bash
echo "APPROVED test coverage is adequate"
exit 0
STUB
  cat > "$fake/bin/resolve-worktree-path" << 'STUB'
#!/usr/bin/env bash
echo NOSTATE
STUB
  cat > "$fake/bin/resolve-session-id" << 'STUB'
#!/usr/bin/env bash
printf 'sid1455'
STUB
  cat > "$fake/bin/resolve-accepted-tradeoffs-file" << 'STUB'
#!/usr/bin/env bash
echo /dev/null
exit 0
STUB
  chmod +x "$fake/bin/run-codex-review-loop" "$fake/bin/resolve-worktree-path" \
      "$fake/bin/resolve-session-id" "$fake/bin/resolve-accepted-tradeoffs-file"
  printf '%s' "$fake"
}

_build_git_repo_1455() {
  local repo
  repo="$(mktemp -d 2>/dev/null || mktemp -d -t repo1455)"
  git -C "$repo" init -q 2>/dev/null
  git -C "$repo" config core.hooksPath /dev/null 2>/dev/null || true
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name Test
  mkdir -p "$repo/tests"
  printf 'echo hi\n' > "$repo/tests/foo.sh"
  git -C "$repo" add tests/foo.sh 2>/dev/null
  printf '%s' "$repo"
}

_run_loop_1455() {
  local plans="$1" fake="$2" repo="$3" ec=0
  # Capture the loop's exit code; `|| true` here would always yield 0.
  ( cd "$repo" && AGENTS_CONFIG_DIR="$fake" SESSION_ID="sid1455" PLANS_DIR="$plans" \
      CLAUDE_CODE_SESSION_ID="sid1455" CLAUDE_SESSION_ID="sid1455" \
      EXTENSIONS_USED=0 "$RWT" 40 bash "$LOOP_SH" >/dev/null 2>&1 ) || ec=$?
  printf '%s' "$ec"
}

if ! command -v git >/dev/null 2>&1; then
  skip "RL tests: git unavailable"
else

PLANS_RL1="$_TMPROOT/plans_rl1"
mkdir -p "$PLANS_RL1"
printf '# draft\n' > "$PLANS_RL1/sid1455-test-review.md"
printf '# outline\n' > "$PLANS_RL1/sid1455-outline.md"
FAKE_RL1="$(_build_fake_input_error)"
REPO_RL1="$(_build_git_repo_1455)"

# RL-1: INPUT_ERROR output from stub -> loop exits 4
RC_RL1="$(_run_loop_1455 "$PLANS_RL1" "$FAKE_RL1" "$REPO_RL1")"
if [ "$RC_RL1" = "4" ]; then
  pass "RL-1 INPUT_ERROR output -> loop exits 4"
else
  fail "RL-1 INPUT_ERROR output should exit 4, got: $RC_RL1"
fi

# RL-2: INPUT_ERROR path printed on stderr
PLANS_RL2="$_TMPROOT/plans_rl2"
mkdir -p "$PLANS_RL2"
printf '# draft\n' > "$PLANS_RL2/sid1455-test-review.md"
printf '# outline\n' > "$PLANS_RL2/sid1455-outline.md"
FAKE_RL2="$(_build_fake_input_error)"
REPO_RL2="$(_build_git_repo_1455)"
STDERR_RL2="$_TMPROOT/stderr_rl2.txt"
( cd "$REPO_RL2" && AGENTS_CONFIG_DIR="$FAKE_RL2" SESSION_ID="sid1455" PLANS_DIR="$PLANS_RL2" \
    CLAUDE_CODE_SESSION_ID="sid1455" CLAUDE_SESSION_ID="sid1455" \
    EXTENSIONS_USED=0 "$RWT" 40 bash "$LOOP_SH" >/dev/null 2>"$STDERR_RL2" ) || true
if [ -f "$STDERR_RL2" ] && grep -qiE "INPUT_ERROR|/some/path" "$STDERR_RL2"; then
  pass "RL-2 INPUT_ERROR path appears on stderr"
else
  fail "RL-2 INPUT_ERROR path not printed on stderr"
fi

# RL-3: INPUT_ERROR does NOT arm the terminal guard
PLANS_RL3="$_TMPROOT/plans_rl3"
mkdir -p "$PLANS_RL3"
printf '# draft\n' > "$PLANS_RL3/sid1455-test-review.md"
printf '# outline\n' > "$PLANS_RL3/sid1455-outline.md"
FAKE_RL3="$(_build_fake_input_error)"
REPO_RL3="$(_build_git_repo_1455)"
_run_loop_1455 "$PLANS_RL3" "$FAKE_RL3" "$REPO_RL3" >/dev/null 2>&1 || true
TERMINAL_MARKER_RL3="$PLANS_RL3/sid1455-test-review-terminal.txt"
if [ ! -f "$TERMINAL_MARKER_RL3" ]; then
  pass "RL-3 INPUT_ERROR does not arm terminal guard (no marker written)"
else
  fail "RL-3 INPUT_ERROR wrongly armed terminal guard (marker should not be written)"
fi

# RL-4: Negative — APPROVED output does NOT exit 4
PLANS_RL4="$_TMPROOT/plans_rl4"
mkdir -p "$PLANS_RL4"
printf '# draft\n' > "$PLANS_RL4/sid1455-test-review.md"
printf '# outline\n' > "$PLANS_RL4/sid1455-outline.md"
FAKE_RL4="$(_build_fake_approved)"
REPO_RL4="$(_build_git_repo_1455)"
RC_RL4="$(_run_loop_1455 "$PLANS_RL4" "$FAKE_RL4" "$REPO_RL4")"
if [ "$RC_RL4" != "4" ]; then
  pass "RL-4 negative: APPROVED output does not exit 4 (rc=$RC_RL4)"
else
  fail "RL-4 negative: APPROVED output must not exit 4"
fi

rm -rf "$FAKE_RL1" "$REPO_RL1" "$FAKE_RL2" "$REPO_RL2" \
       "$FAKE_RL3" "$REPO_RL3" "$FAKE_RL4" "$REPO_RL4" 2>/dev/null || true

fi # git available

case_end

# ─────────────────────────────────────────────────────────
case_begin "skill-rt2-rt3-sections" "skills/review-tests/SKILL.md"

# SK-1: SKILL.md RT-2 has ## Review targets section
if [ -f "$SKILL_MD" ] && grep -qF "## Review targets" "$SKILL_MD"; then
  pass "SK-1 SKILL.md has ## Review targets section"
else
  fail "SK-1 SKILL.md missing ## Review targets section"
fi

# SK-2: SKILL.md has ## Deleted tests section
if [ -f "$SKILL_MD" ] && grep -qF "## Deleted tests" "$SKILL_MD"; then
  pass "SK-2 SKILL.md has ## Deleted tests section"
else
  fail "SK-2 SKILL.md missing ## Deleted tests section"
fi

# SK-3: RT-3 CC fallback has INPUT_ERROR -> HALT
if [ -f "$SKILL_MD" ]; then
  RT3_BLOCK=$(awk '/^RT-3\./{f=1} f && /^RT-[0-9]/ && !/^RT-3/{exit} f{print}' "$SKILL_MD")
  if echo "$RT3_BLOCK" | grep -qF "INPUT_ERROR"; then
    pass "SK-3 RT-3 mentions INPUT_ERROR"
  else
    fail "SK-3 RT-3 missing INPUT_ERROR HALT guidance"
  fi
  if echo "$RT3_BLOCK" | grep -qiE "INPUT_ERROR.*HALT|HALT.*INPUT_ERROR|INPUT_ERROR.*halt"; then
    pass "SK-3a RT-3 has INPUT_ERROR -> HALT explicitly"
  else
    fail "SK-3a RT-3 INPUT_ERROR does not have explicit HALT"
  fi
fi

# SK-4 / SK-5: RT-3 exit-3 (CC fallback) text, from the "- exit 3" bullet up to "- exit 4"
if [ -f "$SKILL_MD" ]; then
  RT3_BLOCK=$(awk '/^RT-3\./{f=1} f && /^RT-[0-9]/ && !/^RT-3/{exit} f{print}' "$SKILL_MD")
  EXIT3_TEXT=$(echo "$RT3_BLOCK" | awk '/^- exit 3/{f=1} f && /^- exit 4/{exit} f{print}')
  if echo "$EXIT3_TEXT" | grep -qF "detect-input-error.sh"; then
    pass "SK-4 RT-3 exit 3 fallback runs detect-input-error.sh"
  else
    fail "SK-4 RT-3 exit 3 fallback does not reference detect-input-error.sh"
  fi
  if echo "$EXIT3_TEXT" | grep -qF -- "-test-review-fallback-raw.md"; then
    pass "SK-4a RT-3 exit 3 fallback saves output to -test-review-fallback-raw.md"
  else
    fail "SK-4a RT-3 exit 3 fallback missing -test-review-fallback-raw.md save path"
  fi
  if echo "$EXIT3_TEXT" | grep -qF "rules/shell-commands.md"; then
    pass "SK-5 RT-3 exit 3 fallback dispatch instructs reading rules/shell-commands.md"
  else
    fail "SK-5 RT-3 exit 3 fallback dispatch does not instruct reading rules/shell-commands.md"
  fi
fi

case_end

# ─────────────────────────────────────────────────────────
case_begin "detect-input-error-runner" "skills/review-tests/scripts/detect-input-error.sh"

# Runs detect-input-error.sh on <file> (or no arg when $1 is empty); echoes rc, stderr to $2.
_run_detect() {
  local file="$1" errf="$2" ec=0
  if [ -n "$file" ]; then
    "$RWT" 15 bash "$DETECT_SH" "$file" >/dev/null 2>"$errf" || ec=$?
  else
    "$RWT" 15 bash "$DETECT_SH" >/dev/null 2>"$errf" || ec=$?
  fi
  printf '%s' "$ec"
}

DI_DIR="$_TMPROOT/detect"
mkdir -p "$DI_DIR"

# DI-1: line-start INPUT_ERROR -> exit 4, offending line on stderr
printf 'Reviewing...\nINPUT_ERROR /x/y.md\n' > "$DI_DIR/di1.md"
RC_DI1="$(_run_detect "$DI_DIR/di1.md" "$DI_DIR/di1.err")"
if [ "$RC_DI1" = "4" ]; then
  pass "DI-1 line-start INPUT_ERROR -> exit 4"
else
  fail "DI-1 line-start INPUT_ERROR should exit 4, got: $RC_DI1"
fi
if grep -qF "/x/y.md" "$DI_DIR/di1.err" 2>/dev/null; then
  pass "DI-1a INPUT_ERROR path printed on stderr"
else
  fail "DI-1a INPUT_ERROR path not printed on stderr"
fi

# DI-2: APPROVED output -> exit 0 (non-targeted verdict)
printf 'APPROVED test coverage is adequate\n' > "$DI_DIR/di2.md"
RC_DI2="$(_run_detect "$DI_DIR/di2.md" "$DI_DIR/di2.err")"
if [ "$RC_DI2" = "0" ]; then
  pass "DI-2 APPROVED output -> exit 0"
else
  fail "DI-2 APPROVED output should exit 0, got: $RC_DI2"
fi

# DI-3: INPUT_ERROR only mid-line -> no match, exit 0
printf 'NEEDS_REVISION\n- the reviewer never emitted INPUT_ERROR /x/y.md here\n' > "$DI_DIR/di3.md"
RC_DI3="$(_run_detect "$DI_DIR/di3.md" "$DI_DIR/di3.err")"
if [ "$RC_DI3" = "0" ]; then
  pass "DI-3 mid-line INPUT_ERROR is not matched -> exit 0"
else
  fail "DI-3 mid-line INPUT_ERROR must not match (want exit 0), got: $RC_DI3"
fi

# DI-3b: empty reviewer output -> exit 0
: > "$DI_DIR/di3b.md"
RC_DI3B="$(_run_detect "$DI_DIR/di3b.md" "$DI_DIR/di3b.err")"
if [ "$RC_DI3B" = "0" ]; then
  pass "DI-3b empty output -> exit 0"
else
  fail "DI-3b empty output should exit 0, got: $RC_DI3B"
fi

# DI-4: missing file -> exit 2; no argument -> exit 2
RC_DI4="$(_run_detect "$DI_DIR/does-not-exist.md" "$DI_DIR/di4.err")"
if [ "$RC_DI4" = "2" ]; then
  pass "DI-4 missing file -> exit 2"
else
  fail "DI-4 missing file should exit 2, got: $RC_DI4"
fi
RC_DI4B="$(_run_detect "" "$DI_DIR/di4b.err")"
if [ "$RC_DI4B" = "2" ]; then
  pass "DI-4b no argument -> exit 2"
else
  fail "DI-4b no argument should exit 2, got: $RC_DI4B"
fi

# DI-5: CRLF line endings still detected
printf 'Reviewing...\r\nINPUT_ERROR /x\r\n' > "$DI_DIR/di5.md"
RC_DI5="$(_run_detect "$DI_DIR/di5.md" "$DI_DIR/di5.err")"
if [ "$RC_DI5" = "4" ]; then
  pass "DI-5 CRLF INPUT_ERROR line -> exit 4"
else
  fail "DI-5 CRLF INPUT_ERROR line should exit 4, got: $RC_DI5"
fi

# DI-6: symmetry — the codex loop uses the same SSOT detector as the CC fallback
if [ -f "$LOOP_SH" ] && grep -qF "detect-input-error.sh" "$LOOP_SH"; then
  pass "DI-6 run-codex-review-loop.sh references detect-input-error.sh"
else
  fail "DI-6 run-codex-review-loop.sh does not reference detect-input-error.sh"
fi

case_end

# ─────────────────────────────────────────────────────────

echo ""
echo "=== fix-1455-test-reviewer-input-contract: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
