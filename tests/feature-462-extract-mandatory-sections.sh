#!/usr/bin/env bash
# Integration tests for bin/extract-mandatory-sections (issue #462).
# Tests will FAIL until bin/extract-mandatory-sections is implemented.
# The wrapper test (#9) compares the existing bin/extract-accepted-tradeoffs
# output against a golden fixture captured at test-creation time; it will pass
# now (against the legacy implementation) and must continue to pass after the
# wrapper rewrite.
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$AGENTS_ROOT/bin/extract-mandatory-sections"
WRAPPER="$AGENTS_ROOT/bin/extract-accepted-tradeoffs"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

# ---------------------------------------------------------------------------
# (1) Executable bit
# ---------------------------------------------------------------------------
if [[ -x "$SCRIPT" ]]; then
    pass "(1) bin/extract-mandatory-sections is executable"
else
    fail "(1) bin/extract-mandatory-sections is not executable or missing: $SCRIPT"
fi

# ---------------------------------------------------------------------------
# Shared fixture for tests 2-5
# ---------------------------------------------------------------------------
FIXTURE1="$TMPDIR_BASE/fixture1.md"
cat > "$FIXTURE1" << 'EOF'
# Plan

## Issue

Issue body line.

## Accepted Tradeoffs

- tradeoff one
- tradeoff two

## Other Section

Other content.
EOF

# ---------------------------------------------------------------------------
# (2) body-only mode (no --with-headers)
# ---------------------------------------------------------------------------
OUT=$(run_with_timeout bash "$SCRIPT" "$FIXTURE1" --section "Accepted Tradeoffs" 2>&1) || true

if echo "$OUT" | grep -q "## Accepted Tradeoffs"; then
    fail "(2) body-only mode: header '## Accepted Tradeoffs' should NOT be in output. Output: $OUT"
else
    pass "(2) body-only mode: header line absent"
fi

if echo "$OUT" | grep -q "tradeoff one"; then
    pass "(2) body-only mode: body 'tradeoff one' present"
else
    fail "(2) body-only mode: body 'tradeoff one' missing. Output: $OUT"
fi

# ---------------------------------------------------------------------------
# (3) --with-headers mode
# ---------------------------------------------------------------------------
OUT=$(run_with_timeout bash "$SCRIPT" "$FIXTURE1" --section "Accepted Tradeoffs" --with-headers 2>&1) || true

if echo "$OUT" | grep -q "## Accepted Tradeoffs"; then
    pass "(3) --with-headers: '## Accepted Tradeoffs' header present"
else
    fail "(3) --with-headers: '## Accepted Tradeoffs' header missing. Output: $OUT"
fi

if echo "$OUT" | grep -q "tradeoff one"; then
    pass "(3) --with-headers: body 'tradeoff one' present"
else
    fail "(3) --with-headers: body 'tradeoff one' missing. Output: $OUT"
fi

# Bonus: header should be at/near the start of output
FIRST_LINE=$(echo "$OUT" | sed -n '1{/^[[:space:]]*$/d;p;}' | head -1)
# Skip leading blank lines: get the first non-blank line
FIRST_NONBLANK=$(echo "$OUT" | awk 'NF{print; exit}')
if echo "$FIRST_NONBLANK" | grep -q "^## Accepted Tradeoffs"; then
    pass "(3) --with-headers: first non-blank line is the section header"
else
    fail "(3) --with-headers: first non-blank line is not '## Accepted Tradeoffs'. Got: '$FIRST_NONBLANK'"
fi

# ---------------------------------------------------------------------------
# (4) multiple --section args
# ---------------------------------------------------------------------------
FIXTURE_MULTI="$TMPDIR_BASE/fixture-multi.md"
cat > "$FIXTURE_MULTI" << 'EOF'
# Outline Plan

## Issue

Issue body for multi-section test.

## Class members

- member-A
- member-B

## Accepted Tradeoffs

- tradeoff-multi-one
- tradeoff-multi-two

## Delivery plan

Delivery plan body.
EOF

OUT=$(run_with_timeout bash "$SCRIPT" "$FIXTURE_MULTI" \
    --section Issue --section "Class members" --section "Accepted Tradeoffs" --with-headers 2>&1) || true

if echo "$OUT" | grep -q "^## Issue"; then
    pass "(4) multi-section: '## Issue' header present"
else
    fail "(4) multi-section: '## Issue' header missing. Output: $OUT"
fi
if echo "$OUT" | grep -q "^## Class members"; then
    pass "(4) multi-section: '## Class members' header present"
else
    fail "(4) multi-section: '## Class members' header missing. Output: $OUT"
fi
if echo "$OUT" | grep -q "^## Accepted Tradeoffs"; then
    pass "(4) multi-section: '## Accepted Tradeoffs' header present"
else
    fail "(4) multi-section: '## Accepted Tradeoffs' header missing. Output: $OUT"
fi

# ---------------------------------------------------------------------------
# (5) non-existent section → empty output + exit 0
# ---------------------------------------------------------------------------
EXIT_CODE=0
OUT=$(run_with_timeout bash "$SCRIPT" "$FIXTURE1" --section "Nonexistent Section" 2>&1) || EXIT_CODE=$?

if [[ "$EXIT_CODE" == "0" ]]; then
    pass "(5) non-existent section: exit 0"
else
    fail "(5) non-existent section: expected exit 0, got $EXIT_CODE. Output: $OUT"
fi

# Empty output (allow trailing newline / whitespace only)
if [[ -z "$(echo "$OUT" | tr -d '[:space:]')" ]]; then
    pass "(5) non-existent section: empty output"
else
    fail "(5) non-existent section: expected empty output. Got: $OUT"
fi

# ---------------------------------------------------------------------------
# (6) file not found → exit 2
# ---------------------------------------------------------------------------
EXIT_CODE=0
OUT=$(run_with_timeout bash "$SCRIPT" "$TMPDIR_BASE/no-such-file.md" --section Issue 2>&1) || EXIT_CODE=$?

if [[ "$EXIT_CODE" == "2" ]]; then
    pass "(6) file not found: exit 2"
else
    fail "(6) file not found: expected exit 2, got $EXIT_CODE. Output: $OUT"
fi

# ---------------------------------------------------------------------------
# (7) fence-aware: ## header inside ``` code fence is NOT extracted
# ---------------------------------------------------------------------------
FIXTURE_FENCE="$TMPDIR_BASE/fixture-fence.md"
cat > "$FIXTURE_FENCE" << 'EOF'
# Fence test

## Accepted Tradeoffs

Normal tradeoff.

## Other

Here is an example:

```markdown
## Class members
Inside fence — should NOT be extracted as a section boundary.
```

End of other section.
EOF

EXIT_CODE=0
OUT=$(run_with_timeout bash "$SCRIPT" "$FIXTURE_FENCE" --section "Class members" 2>&1) || EXIT_CODE=$?

if [[ "$EXIT_CODE" == "0" ]]; then
    pass '(7) fence-aware backtick-fence: exit 0'
else
    fail "(7) fence-aware backtick-fence: expected exit 0, got $EXIT_CODE. Output: $OUT"
fi

if [[ -z "$(echo "$OUT" | tr -d '[:space:]')" ]]; then
    pass '(7) fence-aware backtick-fence: empty output (fenced header ignored)'
else
    fail "(7) fence-aware backtick-fence: expected empty output (fenced header must be ignored). Got: $OUT"
fi

# ---------------------------------------------------------------------------
# (8) fence-aware with ~~~ style fences
# ---------------------------------------------------------------------------
FIXTURE_FENCE_TILDE="$TMPDIR_BASE/fixture-fence-tilde.md"
cat > "$FIXTURE_FENCE_TILDE" << 'EOF'
# Tilde fence test

## Accepted Tradeoffs

Normal tradeoff body.

## Other

Tilde example:

~~~markdown
## Class members
Inside tilde fence — should NOT be extracted as a section boundary.
~~~

End.
EOF

EXIT_CODE=0
OUT=$(run_with_timeout bash "$SCRIPT" "$FIXTURE_FENCE_TILDE" --section "Class members" 2>&1) || EXIT_CODE=$?

if [[ "$EXIT_CODE" == "0" ]]; then
    pass "(8) fence-aware ~~~ : exit 0"
else
    fail "(8) fence-aware ~~~ : expected exit 0, got $EXIT_CODE. Output: $OUT"
fi

if [[ -z "$(echo "$OUT" | tr -d '[:space:]')" ]]; then
    pass "(8) fence-aware ~~~ : empty output (fenced header ignored)"
else
    fail "(8) fence-aware ~~~ : expected empty output (fenced header must be ignored). Got: $OUT"
fi

# ---------------------------------------------------------------------------
# (9) wrapper byte-identical with golden fixture
#     The golden fixture was captured at test-creation time by running the
#     current bin/extract-accepted-tradeoffs against the input fixture.
#     This test passes today (legacy implementation) and must continue to
#     pass after the wrapper rewrite (delegating to extract-mandatory-sections).
# ---------------------------------------------------------------------------
INPUT_FIXTURE="$AGENTS_ROOT/tests/fixtures/extract-accepted-tradeoffs-input.md"
GOLDEN_FIXTURE="$AGENTS_ROOT/tests/fixtures/extract-accepted-tradeoffs-golden.txt"

if [[ ! -f "$INPUT_FIXTURE" ]]; then
    fail "(9) wrapper golden: input fixture missing: $INPUT_FIXTURE"
elif [[ ! -f "$GOLDEN_FIXTURE" ]]; then
    fail "(9) wrapper golden: golden fixture missing: $GOLDEN_FIXTURE"
elif [[ ! -x "$WRAPPER" ]]; then
    fail "(9) wrapper golden: wrapper not executable: $WRAPPER"
else
    ACTUAL_OUT="$TMPDIR_BASE/wrapper-actual.txt"
    EXIT_CODE=0
    run_with_timeout bash "$WRAPPER" "$INPUT_FIXTURE" > "$ACTUAL_OUT" 2>&1 || EXIT_CODE=$?
    if [[ "$EXIT_CODE" != "0" ]]; then
        fail "(9) wrapper golden: wrapper exited $EXIT_CODE. Output: $(cat "$ACTUAL_OUT")"
    elif diff -q "$GOLDEN_FIXTURE" "$ACTUAL_OUT" >/dev/null 2>&1; then
        pass "(9) wrapper golden: extract-accepted-tradeoffs output matches golden byte-for-byte"
    else
        fail "(9) wrapper golden: output differs from golden. Diff:
$(diff "$GOLDEN_FIXTURE" "$ACTUAL_OUT" 2>&1 | head -40)"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ $ERRORS -eq 0 ]]; then
    echo "All tests passed."
    exit 0
else
    echo "$ERRORS test(s) failed."
    exit 1
fi
