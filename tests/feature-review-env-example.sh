#!/bin/bash
# Tests: bin/review-env-example
# Tags: env-example, bin, style-check, scope:common
# Tests for bin/review-env-example
# Verifies: SKIPPED/PERFORMED status labels, HARD/WARN classification,
# _archived/ and node_modules/ exclusion, --base flag, --all flag,
# merge-base failure handling, real .env.example staged passes without
# ENFORCE_WORKTREE_EXCLUDE variable violations.
#
# L3 gap: the --all scan here runs bin/review-env-example as a subprocess
# against a copy of .env.example; it does NOT test review-env-example being
# invoked automatically by the pre-commit hook in a real git commit. That
# path requires a live hook-registration test (category: hook-registration).
set -euo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$AGENTS_ROOT/bin/review-env-example"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# Portable timeout wrapper (from rules/test/macos-timeout.md)
run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ---------------------------------------------------------------------------
# Helper: create a fresh isolated temp git repo with a main branch + initial commit
# Uses an empty hooksPath to avoid inheriting global git hooks (e.g. ENFORCE_WORKTREE).
# ---------------------------------------------------------------------------
EMPTY_HOOKS_DIR="$TMPDIR_BASE/no-hooks"
mkdir -p "$EMPTY_HOOKS_DIR"
EMPTY_EXCLUDES="$TMPDIR_BASE/empty-excludes"
: > "$EMPTY_EXCLUDES"

make_repo() {
    local repo
    repo=$(mktemp -d -p "$TMPDIR_BASE")
    git -C "$repo" init -q
    git -C "$repo" config core.hooksPath "$EMPTY_HOOKS_DIR"
    git -C "$repo" config core.excludesFile "$EMPTY_EXCLUDES"
    git -C "$repo" config core.autocrlf false
    git -C "$repo" checkout -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m "initial"
    echo "$repo"
}

# Helper: write a compliant .env.example entry (3 comment lines within 1-5 cap, no banned content)
write_compliant_entry() {
    local path="$1"
    cat > "$path" <<'EOF'
MYVAR=default
# What you can do: control widget display.
# What you can't do: affect server-side behavior.
# Format: 0 (off) or 1 (on). Default: 0.
EOF
}

# ---------------------------------------------------------------------------
# Case 1: SKIPPED — no .env.example in diff
# ---------------------------------------------------------------------------
REPO1=$(make_repo)
git -C "$REPO1" checkout -q -b feature1
echo "some unrelated content" > "$REPO1/other.txt"
git -C "$REPO1" add "$REPO1/other.txt"
git -C "$REPO1" commit -q -m "add unrelated file"

EXIT_CODE=0
OUTPUT=$(cd "$REPO1" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 1: expected exit 0, got $EXIT_CODE"
else
    pass "Case 1: exits 0 when no .env.example changed"
fi

if echo "$OUTPUT" | grep -q "## Env-example Review: SKIPPED"; then
    pass "Case 1: output contains SKIPPED"
else
    fail "Case 1: SKIPPED not found. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 2: HARD — variable-name heading repeat
# ---------------------------------------------------------------------------
REPO2=$(make_repo)
git -C "$REPO2" checkout -q -b feature2
cat > "$REPO2/.env.example" <<'EOF'
# MYVAR — controls widget display
# What you can do: turn it on or off.
# Format: 0 or 1.
MYVAR=0
EOF
git -C "$REPO2" add "$REPO2/.env.example"
git -C "$REPO2" commit -q -m "add .env.example with variable-name heading"

EXIT_CODE=0
OUTPUT=$(cd "$REPO2" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 1 ]]; then
    pass "Case 2: exits 1 for variable-name heading repeat"
else
    fail "Case 2: expected exit 1, got $EXIT_CODE. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "HARD"; then
    pass "Case 2: output contains HARD"
else
    fail "Case 2: HARD not found. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 3: HARD — issue reference (#123) in comment line
# ---------------------------------------------------------------------------
REPO3=$(make_repo)
git -C "$REPO3" checkout -q -b feature3
cat > "$REPO3/.env.example" <<'EOF'
# What you can do: enable widget mode (#123).
# What you can't do: affect anything else.
# Format: 0 or 1.
MYVAR=0
EOF
git -C "$REPO3" add "$REPO3/.env.example"
git -C "$REPO3" commit -q -m "add .env.example with issue reference"

EXIT_CODE=0
OUTPUT=$(cd "$REPO3" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 1 ]]; then
    pass "Case 3: exits 1 for issue reference (#123)"
else
    fail "Case 3: expected exit 1, got $EXIT_CODE. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "HARD"; then
    pass "Case 3: output contains HARD"
else
    fail "Case 3: HARD not found. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 4: HARD — internal implementation detail variants
#   (path with /, bare .js filename, hook event name, protocol term)
# ---------------------------------------------------------------------------
REPO4=$(make_repo)
git -C "$REPO4" checkout -q -b feature4
cat > "$REPO4/.env.example" <<'EOF'
# What you can do: enable widget mode (used by hooks/foo.js).
# Read by workflow-state.js at PostToolUse; orchestrator-injects this value.
# Format: 0 or 1.
MYVAR=0
EOF
git -C "$REPO4" add "$REPO4/.env.example"
git -C "$REPO4" commit -q -m "add .env.example with internal implementation detail patterns"

EXIT_CODE=0
OUTPUT=$(cd "$REPO4" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 1 ]]; then
    pass "Case 4: exits 1 for internal implementation detail"
else
    fail "Case 4: expected exit 1, got $EXIT_CODE. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "HARD"; then
    pass "Case 4: output contains HARD"
else
    fail "Case 4: HARD not found. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 8: HARD — redundant Example: line
# ---------------------------------------------------------------------------
REPO8=$(make_repo)
git -C "$REPO8" checkout -q -b feature8
cat > "$REPO8/.env.example" <<'EOF'
# What you can do: enable widget mode.
# What you can't do: affect anything else.
# Format: 0 or 1.
# Example: MYVAR=somevalue
MYVAR=0
EOF
git -C "$REPO8" add "$REPO8/.env.example"
git -C "$REPO8" commit -q -m "add .env.example with redundant Example: line"

EXIT_CODE=0
OUTPUT=$(cd "$REPO8" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 1 ]]; then
    pass "Case 8: exits 1 for redundant Example: line"
else
    fail "Case 8: expected exit 1, got $EXIT_CODE. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "HARD"; then
    pass "Case 8: output contains HARD"
else
    fail "Case 8: HARD not found. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 9: HARD — comment block exceeds 5 lines (6 # lines before VAR=)
# ---------------------------------------------------------------------------
REPO9=$(make_repo)
git -C "$REPO9" checkout -q -b feature9
cat > "$REPO9/.env.example" <<'EOF'
# Comment line 1
# Comment line 2
# Comment line 3
# Comment line 4
# Comment line 5
# Comment line 6
MYVAR=0
EOF
git -C "$REPO9" add "$REPO9/.env.example"
git -C "$REPO9" commit -q -m "add .env.example with 6-line comment block"

EXIT_CODE=0
OUTPUT=$(cd "$REPO9" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 1 ]]; then
    pass "Case 9: exits 1 for comment block > 5 lines"
else
    fail "Case 9: expected exit 1, got $EXIT_CODE. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "HARD"; then
    pass "Case 9: output contains HARD"
else
    fail "Case 9: HARD not found. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 10: WARN-only — architecture rationale phrase ("eliminates race condition")
# ---------------------------------------------------------------------------
REPO10=$(make_repo)
git -C "$REPO10" checkout -q -b feature10
cat > "$REPO10/.env.example" <<'EOF'
# What you can do: enable widget mode (eliminates race condition on startup).
# What you can't do: affect anything else.
# Format: 0 or 1.
MYVAR=0
EOF
git -C "$REPO10" add "$REPO10/.env.example"
git -C "$REPO10" commit -q -m "add .env.example with architecture rationale"

EXIT_CODE=0
OUTPUT=$(cd "$REPO10" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 10: expected exit 0 (WARN-only), got $EXIT_CODE. Output: $OUTPUT"
else
    pass "Case 10: exits 0 for WARN-only (architecture rationale)"
fi

if echo "$OUTPUT" | grep -q "WARN"; then
    pass "Case 10: output contains WARN"
else
    fail "Case 10: WARN not found. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 11: WARN-only — command reference ("Run bash")
# ---------------------------------------------------------------------------
REPO11=$(make_repo)
git -C "$REPO11" checkout -q -b feature11
cat > "$REPO11/.env.example" <<'EOF'
# What you can do: enable widget mode. Run bash to set this up.
# What you can't do: affect anything else.
# Format: 0 or 1.
MYVAR=0
EOF
git -C "$REPO11" add "$REPO11/.env.example"
git -C "$REPO11" commit -q -m "add .env.example with command reference"

EXIT_CODE=0
OUTPUT=$(cd "$REPO11" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 11: expected exit 0 (WARN-only), got $EXIT_CODE. Output: $OUTPUT"
else
    pass "Case 11: exits 0 for WARN-only (command reference)"
fi

if echo "$OUTPUT" | grep -q "WARN"; then
    pass "Case 11: output contains WARN"
else
    fail "Case 11: WARN not found. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 12: Clean compliant case — PERFORMED, exit 0
# ---------------------------------------------------------------------------
REPO12=$(make_repo)
git -C "$REPO12" checkout -q -b feature12
write_compliant_entry "$REPO12/.env.example"
git -C "$REPO12" add "$REPO12/.env.example"
git -C "$REPO12" commit -q -m "add compliant .env.example"

EXIT_CODE=0
OUTPUT=$(cd "$REPO12" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 12: expected exit 0 for clean compliant case, got $EXIT_CODE. Output: $OUTPUT"
else
    pass "Case 12: exits 0 for clean compliant case"
fi

if echo "$OUTPUT" | grep -q "## Env-example Review: PERFORMED"; then
    pass "Case 12: output contains PERFORMED header"
else
    fail "Case 12: PERFORMED header not found. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 13: _archived/ files excluded
# ---------------------------------------------------------------------------
REPO13=$(make_repo)
git -C "$REPO13" checkout -q -b feature13
mkdir -p "$REPO13/_archived"
cat > "$REPO13/_archived/.env.example" <<'EOF'
# MYVAR — controls widget display
# What you can do: turn it on or off (#123, hooks/foo.js).
# Format: 0 or 1.
# Example: MYVAR=somevalue
MYVAR=0
EOF
git -C "$REPO13" add "$REPO13/_archived/.env.example"
git -C "$REPO13" commit -q -m "add archived .env.example with violations"

EXIT_CODE=0
OUTPUT=$(cd "$REPO13" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 13: expected exit 0 for _archived/ exclusion, got $EXIT_CODE. Output: $OUTPUT"
else
    pass "Case 13: exits 0 (HARD violations in _archived/ excluded)"
fi

# ---------------------------------------------------------------------------
# Case 14: node_modules/ files excluded
# ---------------------------------------------------------------------------
REPO14=$(make_repo)
git -C "$REPO14" checkout -q -b feature14
mkdir -p "$REPO14/node_modules/some-package"
cat > "$REPO14/node_modules/some-package/.env.example" <<'EOF'
# MYVAR — controls widget display
# What you can do: turn it on or off (#123, hooks/foo.js).
# Format: 0 or 1.
# Example: MYVAR=somevalue
MYVAR=0
EOF
git -C "$REPO14" add "$REPO14/node_modules/some-package/.env.example"
git -C "$REPO14" commit -q -m "add node_modules .env.example with violations"

EXIT_CODE=0
OUTPUT=$(cd "$REPO14" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 14: expected exit 0 for node_modules/ exclusion, got $EXIT_CODE. Output: $OUTPUT"
else
    pass "Case 14: exits 0 (HARD violations in node_modules/ excluded)"
fi

# ---------------------------------------------------------------------------
# Case 15: --base <ref> explicit merge base works with explicit SHA
# ---------------------------------------------------------------------------
REPO15=$(make_repo)
BASE_SHA=$(git -C "$REPO15" rev-parse HEAD)
git -C "$REPO15" checkout -q -b feature15
write_compliant_entry "$REPO15/.env.example"
git -C "$REPO15" add "$REPO15/.env.example"
git -C "$REPO15" commit -q -m "add compliant .env.example on feature15"

EXIT_CODE=0
OUTPUT=$(cd "$REPO15" && run_with_timeout bash "$SCRIPT" --base "$BASE_SHA" 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 15: expected exit 0 with explicit SHA --base, got $EXIT_CODE. Output: $OUTPUT"
else
    pass "Case 15: exits 0 with explicit SHA --base"
fi

if echo "$OUTPUT" | grep -q "## Env-example Review: PERFORMED"; then
    pass "Case 15: output contains PERFORMED with explicit SHA --base"
else
    fail "Case 15: PERFORMED not found with explicit SHA --base. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 16: --all never exits 1 even with HARD violations (audit mode)
# ---------------------------------------------------------------------------
REPO16=$(make_repo)
git -C "$REPO16" checkout -q -b feature16
cat > "$REPO16/.env.example" <<'EOF'
# MYVAR — controls widget display
# What you can do: turn it on or off (#123, hooks/foo.js).
# Format: 0 or 1.
# Example: MYVAR=somevalue
MYVAR=0
EOF
git -C "$REPO16" add "$REPO16/.env.example"
git -C "$REPO16" commit -q -m "add .env.example with HARD violations"

EXIT_CODE=0
OUTPUT=$(cd "$REPO16" && run_with_timeout bash "$SCRIPT" --all 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 16: expected exit 0 with --all even on HARD, got $EXIT_CODE. Output: $OUTPUT"
else
    pass "Case 16: exits 0 with --all (audit mode never blocks)"
fi

# ---------------------------------------------------------------------------
# Case 17: merge-base resolution failure → SKIPPED gracefully (exit 0)
# ---------------------------------------------------------------------------
REPO17=$(make_repo)

EXIT_CODE=0
OUTPUT=$(cd "$REPO17" && run_with_timeout bash "$SCRIPT" --base nonexistent-xyz-ref-aaaaa 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 17: expected exit 0 when merge-base fails, got $EXIT_CODE"
else
    pass "Case 17: exits 0 when merge-base resolution fails"
fi

if echo "$OUTPUT" | grep -q "## Env-example Review: SKIPPED"; then
    pass "Case 17: output contains SKIPPED for bad base ref"
else
    fail "Case 17: SKIPPED not found. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case real-env-example-clean: the repo's real .env.example passes the checker.
# Runs `--all` from the repo root (audit mode, always exit 0) and asserts the
# real .env.example produces NO HARD finding — i.e. no `HARD:` finding line names
# .env.example, and the summary reports 0 HARD findings. This is the regression
# guard that the shipped .env.example stays compliant with rules/docs/env-example.md.
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

# ---------------------------------------------------------------------------
# Case 18: HARD — blank line immediately before #@endif
# ---------------------------------------------------------------------------
REPO18=$(make_repo)
git -C "$REPO18" checkout -q -b feature18
cat > "$REPO18/.env.example" <<'EOF'
#@if windows
# What you can do: control this on Windows.
# Format: path-style value.
MYVAR=C:\example

#@endif
EOF
git -C "$REPO18" add "$REPO18/.env.example"
git -C "$REPO18" commit -q -m "add .env.example with blank line before #@endif"

EXIT_CODE=0
OUTPUT=$(cd "$REPO18" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 1 ]]; then
    pass "Case 18: exits 1 for blank line before #@endif"
else
    fail "Case 18: expected exit 1, got $EXIT_CODE. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -qE '^HARD:'; then
    pass "Case 18: output contains a HARD: finding"
else
    fail "Case 18: no HARD: finding line found. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "blank line before #@endif"; then
    pass "Case 18: output contains 'blank line before #@endif'"
else
    fail "Case 18: 'blank line before #@endif' not found. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# Case 19: Clean path — #@endif with no blank line before it (no false positive)
# ---------------------------------------------------------------------------
REPO19=$(make_repo)
git -C "$REPO19" checkout -q -b feature19
cat > "$REPO19/.env.example" <<'EOF'
#@if windows
# What you can do: control this on Windows.
# Format: path-style value.
MYVAR=C:\example
#@endif
EOF
git -C "$REPO19" add "$REPO19/.env.example"
git -C "$REPO19" commit -q -m "add .env.example with #@endif and no blank line before it"

EXIT_CODE=0
OUTPUT=$(cd "$REPO19" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 19: expected exit 0 for clean #@endif (no blank before), got $EXIT_CODE. Output: $OUTPUT"
else
    pass "Case 19: exits 0 when no blank line before #@endif"
fi

if echo "$OUTPUT" | grep -q "blank line before #@endif"; then
    fail "Case 19: unexpected 'blank line before #@endif' in output. Output: $OUTPUT"
else
    pass "Case 19: output does not contain 'blank line before #@endif'"
fi

# ---------------------------------------------------------------------------
# Case 20: Edge — blank line before #@if (block separator) is allowed
# ---------------------------------------------------------------------------
REPO20=$(make_repo)
git -C "$REPO20" checkout -q -b feature20
cat > "$REPO20/.env.example" <<'EOF'
# What you can do: control widget display.
# What you can't do: affect server-side behavior.
# Format: 0 (off) or 1 (on). Default: 0.
MYVAR=default

#@if windows
# What you can do: control this on Windows.
# Format: path-style value.
MYVAR=C:\example
#@endif
EOF
git -C "$REPO20" add "$REPO20/.env.example"
git -C "$REPO20" commit -q -m "add .env.example with blank line before #@if (allowed)"

EXIT_CODE=0
OUTPUT=$(cd "$REPO20" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 20: expected exit 0 for blank before #@if (allowed), got $EXIT_CODE. Output: $OUTPUT"
else
    pass "Case 20: exits 0 when blank line is before #@if (not #@endif)"
fi

if echo "$OUTPUT" | grep -q "blank line before #@endif"; then
    fail "Case 20: unexpected 'blank line before #@endif' finding for blank-before-#@if case. Output: $OUTPUT"
else
    pass "Case 20: no false positive for blank line before #@if"
fi

# ---------------------------------------------------------------------------
# Case 21: Edge — file starts with #@endif as first line (prev_was_blank=0 init)
# ---------------------------------------------------------------------------
REPO21=$(make_repo)
git -C "$REPO21" checkout -q -b feature21
cat > "$REPO21/.env.example" <<'EOF'
#@endif
# What you can do: control widget display.
# What you can't do: affect server-side behavior.
# Format: 0 (off) or 1 (on).
MYVAR=default
EOF
git -C "$REPO21" add "$REPO21/.env.example"
git -C "$REPO21" commit -q -m "add .env.example with #@endif as first line"

EXIT_CODE=0
OUTPUT=$(cd "$REPO21" && run_with_timeout bash "$SCRIPT" --base main 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "Case 21: expected exit 0 for #@endif as first line (no false positive), got $EXIT_CODE. Output: $OUTPUT"
else
    pass "Case 21: exits 0 when #@endif is first line (prev_was_blank=0 initial value)"
fi

if echo "$OUTPUT" | grep -q "blank line before #@endif"; then
    fail "Case 21: unexpected 'blank line before #@endif' finding for first-line #@endif. Output: $OUTPUT"
else
    pass "Case 21: no false positive for #@endif as first line"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [[ $ERRORS -gt 0 ]]; then echo ""; echo "FAILED: $ERRORS test(s) failed"; exit 1; else echo ""; echo "All tests passed"; fi
