#!/bin/bash
# tests/feature-review-env-example/real-env-example-cases.sh
# Tests: bin/review-env-example, .env.example, docs/parallel-sessions.md
# Tags: env-example, bin, style-check, regression-guard, docs, scope:common
# Sourced by ../feature-review-env-example.sh — helpers come from there.
# Regression guards on the SHIPPED files rather than on fixtures.

# ---------------------------------------------------------------------------
# real-env-example-clean: `--all` from the repo root (audit mode, always exit 0)
# must produce NO `HARD:` line naming .env.example and a 0-HARD summary — the
# guard that the shipped file stays compliant with rules/docs/env-example.md.
# ---------------------------------------------------------------------------
EXIT_CODE=0
OUTPUT=$(cd "$AGENTS_ROOT" && run_with_timeout bash "$SCRIPT" --all 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "real-env-example-clean: expected exit 0 (--all audit mode), got $EXIT_CODE. Output: $OUTPUT"
else
    pass "real-env-example-clean: --all exits 0"
fi

# Finding lines start with `HARD:` (the "HARD findings block the workflow" header
# note has no colon, so `^HARD:` does not match it).
if echo "$OUTPUT" | grep -qE '^HARD:.*\.env\.example'; then
    fail "real-env-example-clean: real .env.example produced a HARD finding. Output: $OUTPUT"
else
    pass "real-env-example-clean: no HARD finding for .env.example"
fi

if echo "$OUTPUT" | grep -qE '^## Env-example Review: [0-9]+ HARD'; then
    fail "real-env-example-clean: summary reports HARD findings. Output: $OUTPUT"
else
    pass "real-env-example-clean: summary reports 0 HARD findings"
fi

# ---------------------------------------------------------------------------
# Case staged-real-env-example-no-exclude-violation: copy the worktree's
# actual .env.example into a temp repo, stage it, and run --all. Assert:
#   1. Exit code 0 (--all is audit mode, never blocks).
#   2. Output does NOT contain "ENFORCE_WORKTREE_EXCLUDE" as a variable
#      violation finding (i.e. the new var entries are compliant).
# This is distinct from real-env-example-clean above which runs from
# AGENTS_ROOT directly — this case explicitly exercises the staged-file path
# by committing the file to a feature branch and using --base main.
# ---------------------------------------------------------------------------
REPO_C2=$(make_repo)
git -C "$REPO_C2" checkout -q -b staged-env-example-check

# Copy the actual .env.example from the worktree source
REAL_ENV_EXAMPLE="$AGENTS_ROOT/.env.example"
if [[ ! -f "$REAL_ENV_EXAMPLE" ]]; then
    fail "staged-real-env-example-no-exclude-violation: .env.example not found at $REAL_ENV_EXAMPLE"
else
    cp "$REAL_ENV_EXAMPLE" "$REPO_C2/.env.example"
    git -C "$REPO_C2" add ".env.example"
    git -C "$REPO_C2" commit -q -m "add real .env.example for review check"

    EXIT_CODE=0
    OUTPUT=$(cd "$REPO_C2" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

    if [[ $EXIT_CODE -ne 0 ]]; then
        fail "staged-real-env-example-no-exclude-violation: expected exit 0 (--base main), got $EXIT_CODE. Output: $OUTPUT"
    else
        pass "staged-real-env-example-no-exclude-violation: exits 0 with real .env.example"
    fi

    # A variable-violation finding line for ENFORCE_WORKTREE_EXCLUDE would look like:
    # "HARD: .env.example ... ENFORCE_WORKTREE_EXCLUDE ..."
    if echo "$OUTPUT" | grep -qE 'HARD:.*ENFORCE_WORKTREE_EXCLUDE|ENFORCE_WORKTREE_EXCLUDE.*HARD:'; then
        fail "staged-real-env-example-no-exclude-violation: ENFORCE_WORKTREE_EXCLUDE produced a HARD finding. Output: $OUTPUT"
    else
        pass "staged-real-env-example-no-exclude-violation: no HARD finding for ENFORCE_WORKTREE_EXCLUDE"
    fi
fi

# ---------------------------------------------------------------------------
# C2: Static grep on .env.example — required vars present, deprecated absent
# ---------------------------------------------------------------------------

# Use the worktree's actual .env.example (same file as AGENTS_ROOT/.env.example).
ENV_EXAMPLE="$AGENTS_ROOT/.env.example"

# C2a: ENFORCE_WORKTREE_ADDITIONAL_REPOS must be present
if grep -q 'ENFORCE_WORKTREE_ADDITIONAL_REPOS' "$ENV_EXAMPLE" 2>/dev/null; then
    pass "env-example-has-required-vars-no-deprecated: ENFORCE_WORKTREE_ADDITIONAL_REPOS present"
else
    fail "env-example-has-required-vars-no-deprecated: ENFORCE_WORKTREE_ADDITIONAL_REPOS absent from .env.example"
fi

# C2b: ENFORCE_WORKTREE_EXCLUDE must appear inside an #@if block.
# Use -A10 to cover up to 10 lines after each #@if (comment blocks can be up to 5
# lines plus the variable line itself, so -A5 is insufficient when comments fill 5 lines).
if grep -A10 '#@if' "$ENV_EXAMPLE" 2>/dev/null | grep -q 'ENFORCE_WORKTREE_EXCLUDE'; then
    pass "env-example-has-required-vars-no-deprecated: ENFORCE_WORKTREE_EXCLUDE appears in #@if block"
else
    fail "env-example-has-required-vars-no-deprecated: ENFORCE_WORKTREE_EXCLUDE not found in #@if block in .env.example"
fi

# C2c: ENFORCE_WORKTREE_EXCLUDE_REPOS must NOT appear as a variable declaration
# (a line like ENFORCE_WORKTREE_EXCLUDE_REPOS= outside a comment is deprecated and should not be present)
if grep -v '^[[:space:]]*#' "$ENV_EXAMPLE" 2>/dev/null | grep -q 'ENFORCE_WORKTREE_EXCLUDE_REPOS='; then
    fail "env-example-has-required-vars-no-deprecated: ENFORCE_WORKTREE_EXCLUDE_REPOS= found as variable declaration (deprecated, must be absent)"
else
    pass "env-example-has-required-vars-no-deprecated: ENFORCE_WORKTREE_EXCLUDE_REPOS= not present as variable declaration"
fi

# C2d: ENFORCE_WORKTREE_EXTRA_REPOS must NOT appear as a variable declaration
if grep -v '^[[:space:]]*#' "$ENV_EXAMPLE" 2>/dev/null | grep -q 'ENFORCE_WORKTREE_EXTRA_REPOS='; then
    fail "env-example-has-required-vars-no-deprecated: ENFORCE_WORKTREE_EXTRA_REPOS= found as variable declaration (deprecated, must be absent)"
else
    pass "env-example-has-required-vars-no-deprecated: ENFORCE_WORKTREE_EXTRA_REPOS= not present as variable declaration"
fi

# C2e/C2f: the #2153 rename. bin/review-plan-codex reads CODEX_REVIEW_MAX_PLAN_LINES
# only, so a .env.example still advertising CODEX_REVIEW_PLAN_MAX_LINES would hand
# the user a key nothing reads — silently, since an unread key never errors.
if grep -q 'CODEX_REVIEW_MAX_PLAN_LINES' "$ENV_EXAMPLE" 2>/dev/null; then
    pass "env-example-codex-plan-lines-rename: CODEX_REVIEW_MAX_PLAN_LINES present"
else
    fail "env-example-codex-plan-lines-rename: CODEX_REVIEW_MAX_PLAN_LINES absent from .env.example"
fi

if grep -q 'CODEX_REVIEW_PLAN_MAX_LINES' "$ENV_EXAMPLE" 2>/dev/null; then
    fail "env-example-codex-plan-lines-rename: retired CODEX_REVIEW_PLAN_MAX_LINES still present in .env.example"
else
    pass "env-example-codex-plan-lines-rename: retired CODEX_REVIEW_PLAN_MAX_LINES absent"
fi

# ---------------------------------------------------------------------------
# C3: Static grep on docs/parallel-sessions.md — new var names present, old absent as primary
# ---------------------------------------------------------------------------

PARALLEL_DOC="$AGENTS_ROOT/docs/parallel-sessions.md"

if [[ ! -f "$PARALLEL_DOC" ]]; then
    fail "parallel-sessions-doc-has-new-names: docs/parallel-sessions.md not found at $PARALLEL_DOC"
else
    # C3a: ENFORCE_WORKTREE_ADDITIONAL_REPOS must be present
    if grep -q 'ENFORCE_WORKTREE_ADDITIONAL_REPOS' "$PARALLEL_DOC" 2>/dev/null; then
        pass "parallel-sessions-doc-has-new-names: ENFORCE_WORKTREE_ADDITIONAL_REPOS found in parallel-sessions.md"
    else
        fail "parallel-sessions-doc-has-new-names: ENFORCE_WORKTREE_ADDITIONAL_REPOS absent from docs/parallel-sessions.md"
    fi

    # C3b: ENFORCE_WORKTREE_EXCLUDE must be present
    if grep -q 'ENFORCE_WORKTREE_EXCLUDE' "$PARALLEL_DOC" 2>/dev/null; then
        pass "parallel-sessions-doc-has-new-names: ENFORCE_WORKTREE_EXCLUDE found in parallel-sessions.md"
    else
        fail "parallel-sessions-doc-has-new-names: ENFORCE_WORKTREE_EXCLUDE absent from docs/parallel-sessions.md"
    fi

    # C3c: ENFORCE_WORKTREE_EXTRA_REPOS must not appear as a primary variable name.
    # It may appear in migration/deprecation context (e.g. "(formerly `ENFORCE_WORKTREE_EXTRA_REPOS`)")
    # but must not appear as a standalone `ENFORCE_WORKTREE_EXTRA_REPOS=` assignment or
    # as the primary subject of a documentation section.
    # We check: if it appears, it must be accompanied on the same or adjacent line by
    # migration keywords (formerly, deprecated, alias, migration) OR be a code reference
    # within a parenthetical — grep for the pattern that indicates non-primary use.
    # Strategy: count lines containing ENFORCE_WORKTREE_EXTRA_REPOS; if any line does NOT
    # also contain a migration keyword AND does NOT contain a "(" (parenthetical reference),
    # that is a primary usage.
    primary_lines=0
    while IFS= read -r line; do
        case "$line" in
            *deprecated*|*alias*|*migration*|*formerly*|*'(formerly'*|*'EXTRA_REPOS)'*) ;;
            *'#'*) ;;
            *'ENFORCE_WORKTREE_EXTRA_REPOS='*) primary_lines=$((primary_lines + 1)) ;;
            *'`ENFORCE_WORKTREE_EXTRA_REPOS`)'*) ;;
            *) ;;
        esac
    done < <(grep 'ENFORCE_WORKTREE_EXTRA_REPOS' "$PARALLEL_DOC" 2>/dev/null)
    if [ "$primary_lines" -gt 0 ]; then
        fail "parallel-sessions-doc-has-new-names: ENFORCE_WORKTREE_EXTRA_REPOS appears as a primary var assignment in parallel-sessions.md"
    else
        pass "parallel-sessions-doc-has-new-names: ENFORCE_WORKTREE_EXTRA_REPOS not a primary var (only in migration/parenthetical context if at all)"
    fi
fi
