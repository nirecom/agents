# Tests: bin/review-plan-codex, bin/run-codex-review-loop, skills/_shared/codex-review-loop.md, skills/make-detail-plan/SKILL.md, skills/make-outline-plan/SKILL.md
# Tags: outline, planning, detail, codex, review, scope:common
# ===========================================================================
# SKILL.md wiring: run-codex-review-loop invocation, exit-4 rule, flat ~/.workflow-plans/ paths
# ===========================================================================

# ---------------------------------------------------------------------------
# 27. make-detail-plan SKILL.md invokes run-codex-review-loop; shim has context strings
# ---------------------------------------------------------------------------
DETAIL_SKILL="$AGENTS_ROOT/skills/make-detail-plan/SKILL.md"
SHARED_LOOP="$AGENTS_ROOT/skills/_shared/codex-review-loop.md"
EXIT_CODES_DOC="$AGENTS_ROOT/skills/_shared/codex-review-loop/exit-codes.md"
ERRS27=0

check_shared() {
  local pattern="$1"
  if ! grep -qF -- "$pattern" "$SHARED_LOOP"; then
    fail "codex-review-loop.md missing: $pattern"
    ERRS27=$((ERRS27 + 1))
  fi
}

check_exit_codes() {
  local pattern="$1"
  if ! grep -qF -- "$pattern" "$EXIT_CODES_DOC"; then
    fail "codex-review-loop/exit-codes.md missing: $pattern"
    ERRS27=$((ERRS27 + 1))
  fi
}

check_shared "## Section 1: Intent (User Requirements)"
check_shared "## Section 2: Outline (Design Proposal)"
check_shared "If only the intent file exists"
check_shared "If only the outline file exists"
check_shared "If neither exists"
check_shared 'Source: <PLANS_DIR>/<session-id>-intent.md'
check_shared 'Source: <PLANS_DIR>/<session-id>-outline.md'
check_exit_codes "HALT with blocking error"
check_exit_codes "Do **NOT** fall back"

if ! grep -qF 'run-codex-review-loop' "$DETAIL_SKILL"; then
  fail "make-detail-plan SKILL.md: must invoke bin/run-codex-review-loop"
  ERRS27=$((ERRS27 + 1))
fi

if ! grep -qF 'Exit 4 must NOT trigger' "$DETAIL_SKILL"; then
  fail "make-detail-plan SKILL.md: must state exit 4 no-fallback rule"
  ERRS27=$((ERRS27 + 1))
fi

if grep -qF '| Exit | Meaning |' "$DETAIL_SKILL"; then
  fail "make-detail-plan SKILL.md: must not duplicate exit-code mapping table"
  ERRS27=$((ERRS27 + 1))
fi

if [[ $ERRS27 -eq 0 ]]; then
  pass "make-detail-plan SKILL.md + shared loop: context wiring, wrapper invoked, exit-4 rule, no duplication"
fi

# ---------------------------------------------------------------------------
# 28. SKILL.md files use flat ~/.workflow-plans/ paths (#866 — no drafts/)
# ---------------------------------------------------------------------------
OUTLINE_SKILL="$AGENTS_ROOT/skills/make-outline-plan/SKILL.md"
ERRS28=0

# make-outline-plan: must contain flat root path and must NOT contain %TEMP%, /tmp/,
# or any drafts/ subdir reference.
if ! grep -qF '$PLANS_DIR/$SESSION_ID-outline.md' "$OUTLINE_SKILL"; then
  fail "make-outline-plan SKILL.md: missing \$PLANS_DIR/\$SESSION_ID-outline.md (flat path)"
  ERRS28=$((ERRS28 + 1))
fi
if grep -qF '%TEMP%' "$OUTLINE_SKILL"; then
  fail "make-outline-plan SKILL.md: still contains %TEMP% reference"
  ERRS28=$((ERRS28 + 1))
fi
if grep -qE '/tmp/[^/]*-outline-draft' "$OUTLINE_SKILL"; then
  fail "make-outline-plan SKILL.md: still contains /tmp/<session-id>-outline-draft reference"
  ERRS28=$((ERRS28 + 1))
fi
if grep -qF '~/.workflow-plans/drafts/' "$OUTLINE_SKILL"; then
  fail "make-outline-plan SKILL.md: still contains drafts/ subdir reference (removed in #866)"
  ERRS28=$((ERRS28 + 1))
fi

# make-detail-plan: must contain flat root path and must NOT contain %TEMP%, /tmp/,
# or any drafts/ subdir reference.
if ! grep -qF '$PLANS_DIR/$SESSION_ID-detail.md' "$DETAIL_SKILL"; then
  fail "make-detail-plan SKILL.md: missing \$PLANS_DIR/\$SESSION_ID-detail.md (flat path)"
  ERRS28=$((ERRS28 + 1))
fi
if grep -qF '%TEMP%' "$DETAIL_SKILL"; then
  fail "make-detail-plan SKILL.md: still contains %TEMP% reference"
  ERRS28=$((ERRS28 + 1))
fi
if grep -qE '/tmp/[^/]*-detail-draft' "$DETAIL_SKILL"; then
  fail "make-detail-plan SKILL.md: still contains /tmp/<session-id>-detail-draft reference"
  ERRS28=$((ERRS28 + 1))
fi
if grep -qF '~/.workflow-plans/drafts/' "$DETAIL_SKILL"; then
  fail "make-detail-plan SKILL.md: still contains drafts/ subdir reference (removed in #866)"
  ERRS28=$((ERRS28 + 1))
fi

if [[ $ERRS28 -eq 0 ]]; then
  pass "SKILL.md files: both use flat ~/.workflow-plans/ paths (no drafts/, %TEMP%, /tmp/)"
fi

# ---------------------------------------------------------------------------
# 29. make-outline-plan SKILL.md invokes run-codex-review-loop; exit-4 rule present
# ---------------------------------------------------------------------------
ERRS29=0

if ! grep -qF 'run-codex-review-loop' "$OUTLINE_SKILL"; then
  fail "make-outline-plan SKILL.md: must invoke bin/run-codex-review-loop"
  ERRS29=$((ERRS29 + 1))
fi

if ! grep -qF 'Exit 4 must NOT trigger' "$OUTLINE_SKILL"; then
  fail "make-outline-plan SKILL.md: must state exit 4 no-fallback rule"
  ERRS29=$((ERRS29 + 1))
fi

if grep -qF '| Exit | Meaning |' "$OUTLINE_SKILL"; then
  fail "make-outline-plan SKILL.md: must not duplicate exit-code mapping table"
  ERRS29=$((ERRS29 + 1))
fi

if ! grep -qF '<PLANS_DIR>/<session-id>-codex-context.md' "$SHARED_LOOP"; then
  fail "shared loop: missing <session-id>-codex-context.md reference (flat path, renamed per #866)"
  ERRS29=$((ERRS29 + 1))
fi

if [[ $ERRS29 -eq 0 ]]; then
  pass "make-outline-plan + shared loop: wrapper invoked, exit-4 rule, no duplication, context ref"
fi

