#!/usr/bin/env bash
# Integration tests for skills/_shared/assemble-mandatory.sh (issue #462).
# Tests will FAIL until skills/_shared/assemble-mandatory.sh is implemented
# and SKILL.md files are updated.
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSEMBLE="$AGENTS_ROOT/skills/_shared/assemble-mandatory.sh"
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
# (a) Executable bit
# ---------------------------------------------------------------------------
if [[ -x "$ASSEMBLE" ]]; then
    pass "(a) skills/_shared/assemble-mandatory.sh is executable"
else
    fail "(a) skills/_shared/assemble-mandatory.sh is not executable or missing: $ASSEMBLE"
fi

# ---------------------------------------------------------------------------
# (b-c) Setup fixtures and run assembly
# ---------------------------------------------------------------------------
INTENT_FIXTURE="$TMPDIR_BASE/intent-fixture.md"
cat > "$INTENT_FIXTURE" << 'EOF'
# Outline Plan — test

## Issue

#462: test issue for assembly

## Class members

- member-A: first member — disposition: fix in scope
- member-B: second member — disposition: track separately

## Accepted Tradeoffs

1. Best-effort only.
2. No 100% coverage guarantee.

## Background

Some background not in mandatory sections.
EOF

PLANNER_FIXTURE="$TMPDIR_BASE/planner-output-fixture.md"
cat > "$PLANNER_FIXTURE" << 'EOF'
# Outline Plan — test

## Issue

#462: PLANNER_AUTHORED_ISSUE_MARKER — this should be stripped

## Class members

PLANNER_AUTHORED_CLASSMEMBERS_MARKER — this should be stripped

## Accepted Tradeoffs

PLANNER_AUTHORED_TRADEOFFS_MARKER — this should be stripped

## Delivery plan

Here is the real planner content.
UNIQUE_PLANNER_MARKER_XYZ_12345

### Step 1

Do the work.

## Risks

Some risks.
EOF

OUT_FILE="$TMPDIR_BASE/assembled.md"
EXIT_CODE=0
ASSEMBLE_OUT=$(run_with_timeout bash "$ASSEMBLE" "$INTENT_FIXTURE" "$PLANNER_FIXTURE" "$OUT_FILE" 2>&1) || EXIT_CODE=$?

if [[ "$EXIT_CODE" == "0" ]]; then
    pass "(b) assemble-mandatory.sh: exit 0 on valid input"
else
    fail "(b) assemble-mandatory.sh: expected exit 0, got $EXIT_CODE. Stderr: $ASSEMBLE_OUT"
fi

if [[ -f "$OUT_FILE" ]]; then
    pass "(c) assemble-mandatory.sh: output file created"
else
    fail "(c) assemble-mandatory.sh: output file not created: $OUT_FILE"
fi

# ---------------------------------------------------------------------------
# (d) count assertion — each mandatory section appears exactly once
# ---------------------------------------------------------------------------
if [[ -f "$OUT_FILE" ]]; then
    c_issue=$(grep -c '^## Issue$' "$OUT_FILE" 2>/dev/null || echo 0)
    c_class=$(grep -c '^## Class members$' "$OUT_FILE" 2>/dev/null || echo 0)
    c_trade=$(grep -c '^## Accepted Tradeoffs$' "$OUT_FILE" 2>/dev/null || echo 0)

    if [[ "$c_issue" -eq 1 ]]; then
        pass "(d) count: '## Issue' appears exactly once"
    else
        fail "(d) count: '## Issue' expected 1, got $c_issue"
    fi
    if [[ "$c_class" -eq 1 ]]; then
        pass "(d) count: '## Class members' appears exactly once"
    else
        fail "(d) count: '## Class members' expected 1, got $c_class"
    fi
    if [[ "$c_trade" -eq 1 ]]; then
        pass "(d) count: '## Accepted Tradeoffs' appears exactly once"
    else
        fail "(d) count: '## Accepted Tradeoffs' expected 1, got $c_trade"
    fi
else
    fail "(d) count: skipped — output file missing"
fi

# ---------------------------------------------------------------------------
# (e) order assertion — H1 line 1, then Issue < Class members < Accepted Tradeoffs < Delivery plan
# ---------------------------------------------------------------------------
if [[ -f "$OUT_FILE" ]]; then
    ln_h1=$(awk '/^# /{print NR; exit}' "$OUT_FILE")
    ln_issue=$(awk '/^## Issue$/{print NR; exit}' "$OUT_FILE")
    ln_class=$(awk '/^## Class members$/{print NR; exit}' "$OUT_FILE")
    ln_trade=$(awk '/^## Accepted Tradeoffs$/{print NR; exit}' "$OUT_FILE")
    ln_delivery=$(awk '/^## Delivery plan$/{print NR; exit}' "$OUT_FILE")

    # H1 at or very near top
    if [[ -n "$ln_h1" && "$ln_h1" -le 3 ]]; then
        pass "(e) order: H1 at or near top (line $ln_h1)"
    else
        fail "(e) order: H1 expected within first 3 lines, got line='$ln_h1'"
    fi

    if [[ -n "$ln_issue" && -n "$ln_class" && -n "$ln_trade" && -n "$ln_delivery" ]] && \
       [[ "$ln_issue" -lt "$ln_class" ]] && \
       [[ "$ln_class" -lt "$ln_trade" ]] && \
       [[ "$ln_trade" -lt "$ln_delivery" ]]; then
        pass "(e) order: Issue($ln_issue) < Class members($ln_class) < Accepted Tradeoffs($ln_trade) < Delivery plan($ln_delivery)"
    else
        fail "(e) order: expected Issue<Class<Tradeoffs<Delivery. Got issue=$ln_issue class=$ln_class trade=$ln_trade delivery=$ln_delivery"
    fi
else
    fail "(e) order: skipped — output file missing"
fi

# ---------------------------------------------------------------------------
# (f) verbatim assertion — Accepted Tradeoffs body from intent equals
#     Accepted Tradeoffs body in assembled output
# ---------------------------------------------------------------------------
if [[ -f "$OUT_FILE" ]]; then
    INTENT_TRADE_BODY="$TMPDIR_BASE/intent-trade-body.txt"
    OUT_TRADE_BODY="$TMPDIR_BASE/out-trade-body.txt"

    awk '
      BEGIN { inside=0 }
      /^## Accepted Tradeoffs[[:space:]]*$/ { inside=1; next }
      inside && /^## / { inside=0 }
      inside { print }
    ' "$INTENT_FIXTURE" > "$INTENT_TRADE_BODY"

    awk '
      BEGIN { inside=0 }
      /^## Accepted Tradeoffs[[:space:]]*$/ { inside=1; next }
      inside && /^## / { inside=0 }
      inside { print }
    ' "$OUT_FILE" > "$OUT_TRADE_BODY"

    if diff -q "$INTENT_TRADE_BODY" "$OUT_TRADE_BODY" >/dev/null 2>&1; then
        pass "(f) verbatim: '## Accepted Tradeoffs' body matches intent fixture"
    else
        fail "(f) verbatim: body mismatch. Diff:
$(diff "$INTENT_TRADE_BODY" "$OUT_TRADE_BODY" 2>&1 | head -20)"
    fi
else
    fail "(f) verbatim: skipped — output file missing"
fi

# ---------------------------------------------------------------------------
# (g) planner duplicate strip — planner-authored mandatory markers NOT in output
# ---------------------------------------------------------------------------
if [[ -f "$OUT_FILE" ]]; then
    if grep -q "PLANNER_AUTHORED_ISSUE_MARKER" "$OUT_FILE"; then
        fail "(g) strip: PLANNER_AUTHORED_ISSUE_MARKER still present (planner duplicate not stripped)"
    else
        pass "(g) strip: PLANNER_AUTHORED_ISSUE_MARKER removed"
    fi
    if grep -q "PLANNER_AUTHORED_CLASSMEMBERS_MARKER" "$OUT_FILE"; then
        fail "(g) strip: PLANNER_AUTHORED_CLASSMEMBERS_MARKER still present"
    else
        pass "(g) strip: PLANNER_AUTHORED_CLASSMEMBERS_MARKER removed"
    fi
    if grep -q "PLANNER_AUTHORED_TRADEOFFS_MARKER" "$OUT_FILE"; then
        fail "(g) strip: PLANNER_AUTHORED_TRADEOFFS_MARKER still present"
    else
        pass "(g) strip: PLANNER_AUTHORED_TRADEOFFS_MARKER removed"
    fi
    # Sanity: planner's non-mandatory content (UNIQUE_PLANNER_MARKER_XYZ_12345) must remain
    if grep -q "UNIQUE_PLANNER_MARKER_XYZ_12345" "$OUT_FILE"; then
        pass "(g) strip: planner's non-mandatory content preserved (UNIQUE_PLANNER_MARKER_XYZ_12345)"
    else
        fail "(g) strip: planner's non-mandatory content lost — UNIQUE_PLANNER_MARKER_XYZ_12345 missing"
    fi
else
    fail "(g) strip: skipped — output file missing"
fi

# ---------------------------------------------------------------------------
# (h) single H1 assertion
# ---------------------------------------------------------------------------
if [[ -f "$OUT_FILE" ]]; then
    h1_count=$(grep -c '^# ' "$OUT_FILE" 2>/dev/null || echo 0)
    if [[ "$h1_count" -eq 1 ]]; then
        pass "(h) single H1: exactly 1 H1 line in output"
    else
        fail "(h) single H1: expected 1, got $h1_count"
    fi
else
    fail "(h) single H1: skipped — output file missing"
fi

# ---------------------------------------------------------------------------
# (i) SINGLE_APPROACH_JUSTIFIED parity — both normal path and
#     SINGLE_APPROACH_JUSTIFIED path call assemble-mandatory.sh
# ---------------------------------------------------------------------------
OUTLINE_SKILL="$AGENTS_ROOT/skills/make-outline-plan/SKILL.md"
if [[ -f "$OUTLINE_SKILL" ]]; then
    if grep -q "assemble-mandatory" "$OUTLINE_SKILL"; then
        pass "(i) parity: assemble-mandatory referenced in make-outline-plan/SKILL.md"
    else
        fail "(i) parity: assemble-mandatory NOT referenced in make-outline-plan/SKILL.md"
    fi
    if grep -q "SINGLE_APPROACH_JUSTIFIED" "$OUTLINE_SKILL" && grep -q "assemble-mandatory" "$OUTLINE_SKILL"; then
        pass "(i) parity: SINGLE_APPROACH_JUSTIFIED and assemble-mandatory both present in SKILL.md"
    else
        fail "(i) parity: SINGLE_APPROACH_JUSTIFIED or assemble-mandatory missing — both paths must use assemble-mandatory"
    fi
else
    fail "(i) parity: make-outline-plan/SKILL.md not found: $OUTLINE_SKILL"
fi

# ---------------------------------------------------------------------------
# (j) fence-aware fixture — code block content preserved after strip
# ---------------------------------------------------------------------------
INTENT_FENCE="$TMPDIR_BASE/intent-with-fence.md"
cat > "$INTENT_FENCE" << 'EOF'
# Test fence intent

## Issue

#462: fence-aware test

## Class members

- member-X: just a member

## Accepted Tradeoffs

- real tradeoff
EOF

FENCE_PLANNER="$TMPDIR_BASE/fence-planner.md"
cat > "$FENCE_PLANNER" << 'PLANNER_FENCE_EOF'
# Test fence

## Delivery plan

Here is the plan. Example code:

```markdown
## Issue
This is inside a fence — should NOT be stripped.
## Accepted Tradeoffs
Also inside fence.
```

End of delivery plan.
PLANNER_FENCE_EOF

OUT_FENCE="$TMPDIR_BASE/out-fence.md"
EXIT_CODE=0
ERR_FENCE=$(run_with_timeout bash "$ASSEMBLE" "$INTENT_FENCE" "$FENCE_PLANNER" "$OUT_FENCE" 2>&1) || EXIT_CODE=$?

if [[ "$EXIT_CODE" == "0" && -f "$OUT_FENCE" ]]; then
    if grep -q "This is inside a fence — should NOT be stripped." "$OUT_FENCE"; then
        pass "(j) fence-aware: fenced content preserved in output"
    else
        fail "(j) fence-aware: fenced content lost. Output:
$(cat "$OUT_FENCE" 2>/dev/null | head -40)"
    fi
else
    fail "(j) fence-aware: assemble failed (exit=$EXIT_CODE). Stderr: $ERR_FENCE"
fi

# ---------------------------------------------------------------------------
# (k) legacy soft-fail (intent.md kind) — missing ## Class members
# ---------------------------------------------------------------------------
LEGACY_INTENT="$TMPDIR_BASE/legacy-intent.md"
cat > "$LEGACY_INTENT" << 'EOF'
# Legacy intent (pre-#462)

## Issue

Old issue body.

## Accepted Tradeoffs

- legacy tradeoff
EOF

OUT_LEGACY="$TMPDIR_BASE/out-legacy.md"
EXIT_CODE=0
ERR_LEGACY=$(run_with_timeout bash "$ASSEMBLE" --source-kind intent \
    "$LEGACY_INTENT" "$PLANNER_FIXTURE" "$OUT_LEGACY" 2>&1) || EXIT_CODE=$?

if [[ "$EXIT_CODE" == "0" ]]; then
    pass "(k) legacy soft-fail: exit 0 for intent-kind missing Class members"
else
    fail "(k) legacy soft-fail: expected exit 0, got $EXIT_CODE. Stderr: $ERR_LEGACY"
fi

if [[ -f "$OUT_LEGACY" ]]; then
    if grep -q "none — legacy intent.md, pre-#462" "$OUT_LEGACY"; then
        pass "(k) legacy soft-fail: placeholder 'none — legacy intent.md, pre-#462' present"
    else
        fail "(k) legacy soft-fail: expected placeholder missing. Output:
$(cat "$OUT_LEGACY" 2>/dev/null | head -30)"
    fi
else
    fail "(k) legacy soft-fail: output file not created"
fi

# ---------------------------------------------------------------------------
# (l) legacy hard-fail (outline.md kind) — missing ## Class members → non-zero exit
# ---------------------------------------------------------------------------
OUT_BAD="$TMPDIR_BASE/out-bad.md"
ERR_FILE="$TMPDIR_BASE/legacy-outline-err.txt"
EXIT_CODE=0
run_with_timeout bash "$ASSEMBLE" --source-kind outline \
    "$LEGACY_INTENT" "$PLANNER_FIXTURE" "$OUT_BAD" 2>"$ERR_FILE" >/dev/null || EXIT_CODE=$?

if [[ "$EXIT_CODE" != "0" ]]; then
    pass "(l) legacy hard-fail: non-zero exit ($EXIT_CODE) for outline-kind missing Class members"
else
    fail "(l) legacy hard-fail: expected non-zero exit, got 0"
fi

if grep -qiE "contract violation" "$ERR_FILE" 2>/dev/null; then
    pass "(l) legacy hard-fail: stderr contains 'contract violation' (case-insensitive)"
else
    fail "(l) legacy hard-fail: stderr missing 'contract violation'. Stderr:
$(cat "$ERR_FILE" 2>/dev/null | head -20)"
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
