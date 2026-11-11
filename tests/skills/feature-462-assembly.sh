#!/usr/bin/env bash
# Tests: skills/_shared/assemble-mandatory.sh, skills/make-outline-plan/SKILL.md
# Tags: outline, planning, skill, bin, env, scope:issue-specific
# lang-check: ignore — the assertions match plan-language marker values and plan text the code under test emits (functional data).
# Integration tests for skills/_shared/assemble-mandatory.sh (issue #462), on the current
# contract: only `## Issues` is injected (#2228 dropped Class members) and each planner writes
# its own `## Accepted Tradeoffs (<stage>)` (#2924).
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
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

## Accepted Tradeoffs (outline)

OWN_OUTLINE_TRADEOFF_MARKER — the planner's own stage, kept
EOF

OUT_FILE="$TMPDIR_BASE/assembled.md"
EXIT_CODE=0
ASSEMBLE_OUT=$(run_with_timeout bash "$ASSEMBLE" --source-kind intent "$INTENT_FIXTURE" "$PLANNER_FIXTURE" "$OUT_FILE" 2>&1) || EXIT_CODE=$?

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
# (d) count — Issues once, the own `(outline)` section once, no Class members, no legacy copy
# ---------------------------------------------------------------------------
cnt() { grep -c "^## $1\$" "$OUT_FILE" 2>/dev/null || true; }
if [[ -f "$OUT_FILE" ]]; then
    for row in "Issues=1" "Class members=0" "Accepted Tradeoffs=0" "Accepted Tradeoffs (outline)=1"; do
        h="${row%=*}"; want="${row##*=}"; got="$(cnt "$h")"
        [[ "$got" -eq "$want" ]] && pass "(d) count: '## $h' appears $want time(s)" \
            || fail "(d) count: '## $h' expected $want, got $got"
    done
else
    fail "(d) count: skipped — output file missing"
fi

# ---------------------------------------------------------------------------
# (e) order — H1 near the top, then Issues < Delivery plan
# ---------------------------------------------------------------------------
if [[ -f "$OUT_FILE" ]]; then
    ln_h1=$(awk '/^# /{print NR; exit}' "$OUT_FILE")
    ln_issue=$(awk '/^## Issues$/{print NR; exit}' "$OUT_FILE")
    ln_delivery=$(awk '/^## Delivery plan$/{print NR; exit}' "$OUT_FILE")
    [[ -n "$ln_h1" && "$ln_h1" -le 3 ]] && pass "(e) order: H1 at or near top (line $ln_h1)" \
        || fail "(e) order: H1 expected within first 3 lines, got line='$ln_h1'"
    [[ -n "$ln_issue" && -n "$ln_delivery" && "$ln_issue" -lt "$ln_delivery" ]] \
        && pass "(e) order: Issues($ln_issue) < Delivery plan($ln_delivery)" \
        || fail "(e) order: expected Issues<Delivery. Got issues=$ln_issue delivery=$ln_delivery"
else
    fail "(e) order: skipped — output file missing"
fi

# ---------------------------------------------------------------------------
# (f) no carry — the intent's Accepted Tradeoffs body is not copied; the planner's own stays
# ---------------------------------------------------------------------------
if [[ -f "$OUT_FILE" ]] && ! grep -qF "Best-effort only." "$OUT_FILE" \
    && grep -qF "OWN_OUTLINE_TRADEOFF_MARKER" "$OUT_FILE"; then
    pass "(f) no carry: intent tradeoffs not copied, planner's own '(outline)' body kept"
else
    fail "(f) no carry: intent tradeoffs copied or own '(outline)' body lost"
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

## Accepted Tradeoffs (outline)

なし
PLANNER_FENCE_EOF

OUT_FENCE="$TMPDIR_BASE/out-fence.md"
EXIT_CODE=0
ERR_FENCE=$(run_with_timeout bash "$ASSEMBLE" --source-kind intent "$INTENT_FENCE" "$FENCE_PLANNER" "$OUT_FENCE" 2>&1) || EXIT_CODE=$?

if [[ "$EXIT_CODE" == "0" && -f "$OUT_FENCE" ]] && grep -q "This is inside a fence — should NOT be stripped." "$OUT_FENCE"; then
    pass "(j) fence-aware: fenced content preserved in output"
else
    fail "(j) fence-aware: assemble failed or fenced content lost (exit=$EXIT_CODE). Stderr: $ERR_FENCE"
fi

# ---------------------------------------------------------------------------
# (k) legacy intent — `## Issue` (singular), no Class members: assembles, Issues normalized,
#     and the legacy `## Accepted Tradeoffs` is not copied (#2924)
# ---------------------------------------------------------------------------
LEGACY_INTENT="$TMPDIR_BASE/legacy-intent.md"
printf '%s\n' "# Legacy intent (pre-#462)" "" "## Issue" "" "Old issue body." "" \
    "## Accepted Tradeoffs" "" "- legacy tradeoff" > "$LEGACY_INTENT"
OUT_LEGACY="$TMPDIR_BASE/out-legacy.md"
EXIT_CODE=0
ERR_LEGACY=$(run_with_timeout bash "$ASSEMBLE" --source-kind intent \
    "$LEGACY_INTENT" "$PLANNER_FIXTURE" "$OUT_LEGACY" 2>&1) || EXIT_CODE=$?
if [[ "$EXIT_CODE" == "0" && -f "$OUT_LEGACY" ]] && grep -q '^## Issues$' "$OUT_LEGACY" \
    && ! grep -qF "legacy tradeoff" "$OUT_LEGACY"; then
    pass "(k) legacy intent: exit 0, '## Issue' normalized, legacy tradeoffs not copied"
else
    fail "(k) legacy intent: expected exit 0 with Issues and no legacy copy (exit=$EXIT_CODE). Stderr: $ERR_LEGACY"
fi

# ---------------------------------------------------------------------------
# (l) --source-kind outline makes the own stage `detail`: a planner with only `(outline)` fails
# ---------------------------------------------------------------------------
OUT_BAD="$TMPDIR_BASE/out-bad-detail.md"
EXIT_CODE=0
ERR_BAD=$(run_with_timeout bash "$ASSEMBLE" --source-kind outline \
    "$LEGACY_INTENT" "$PLANNER_FIXTURE" "$OUT_BAD" 2>&1) || EXIT_CODE=$?
if [[ "$EXIT_CODE" == "4" && ! -f "$OUT_BAD" ]]; then
    pass "(l) own stage: outline-kind source with no '(detail)' section → exit 4, no output"
else
    fail "(l) own stage: expected exit 4 and no output, got $EXIT_CODE. Stderr: $ERR_BAD"
fi

# (l2) an unknown --source-kind value is a usage error: exit 2, stderr names it, no output
OUT_KIND="$TMPDIR_BASE/out-bad-kind.md"
EXIT_CODE=0
ERR_KIND=$(run_with_timeout bash "$ASSEMBLE" --source-kind detail \
    "$LEGACY_INTENT" "$PLANNER_FIXTURE" "$OUT_KIND" 2>&1) || EXIT_CODE=$?
if [[ "$EXIT_CODE" == "2" && ! -f "$OUT_KIND" && "$ERR_KIND" == *"invalid --source-kind 'detail'"* ]]; then
    pass "(l2) --source-kind detail → exit 2, reason on stderr, no output"
else
    fail "(l2) invalid --source-kind: expected exit 2 + reason + no output, got $EXIT_CODE. Stderr: $ERR_KIND"
fi

# ---------------------------------------------------------------------------
# (m) output-path constraint — $OUT must resolve under an ALLOWED ROOT
#
# The third positional is the destination of both `mktemp -d -p "$(dirname "$OUT")"` and the
# final `mv -f`, so an unconstrained one is an arbitrary-file-overwrite primitive. The allowed
# destinations are the workflow plans directory and the system temp roots -- where every real
# caller already writes -- so the constraint costs nothing and removes the primitive. The
# refusal must precede every write: "it errored" and "it errored without touching the
# destination" are two claims, and only the second is the security one.
# ---------------------------------------------------------------------------
M_ROOTS="$TMPDIR_BASE/m-temp-root"
M_PLANS="$TMPDIR_BASE/m-plans-root"
M_ELSEWHERE="$TMPDIR_BASE/m-elsewhere"
mkdir -p "$M_ROOTS" "$M_PLANS" "$M_ELSEWHERE"

# The child's roots are PINNED to fixture directories and the escape path is a sibling of both,
# which is what makes "outside every allowed root" reproducible on a host whose real temp root
# contains this harness -- and it keeps a regression from writing anywhere the EXIT trap does
# not already remove. TMPDIR, TMP and TEMP are all pinned because the guard consults
# `${TMPDIR:-/tmp}` AND node's os.tmpdir(), and on Windows node reads TEMP/TMP, not TMPDIR.
m_assemble() { # <out> <err-file> -> exit code on stdout
    local code=0
    run_with_timeout env TMPDIR="$M_ROOTS" TMP="$M_ROOTS" TEMP="$M_ROOTS" \
        WORKFLOW_PLANS_DIR="$M_PLANS" \
        bash "$ASSEMBLE" --source-kind intent "$INTENT_FIXTURE" "$PLANNER_FIXTURE" "$1" \
        2>"$2" >/dev/null || code=$?
    printf '%s' "$code"
}

# (m1) the workflow plans directory — where every real caller writes its artifact
OUT_M_PLANS="$M_PLANS/out-m-plans.md"
EXIT_CODE=$(m_assemble "$OUT_M_PLANS" "$TMPDIR_BASE/m-plans-err.txt")

if [[ "$EXIT_CODE" == "0" && -f "$OUT_M_PLANS" ]]; then
    pass "(m) out-path: an output under the workflow plans directory is accepted and written (exit 0)"
else
    fail "(m) out-path: expected exit 0 with the file created, got exit=$EXIT_CODE. Stderr:
$(head -20 "$TMPDIR_BASE/m-plans-err.txt" 2>/dev/null)"
fi

# (m1b) a system temp root — the OTHER allowed root, and the one every test scratch file uses.
# Without this row the plans dir alone would satisfy the suite, and a guard that admitted only
# it would break every mktemp-based caller silently.
OUT_M_TEMP="$M_ROOTS/out-m-temp.md"
EXIT_CODE=$(m_assemble "$OUT_M_TEMP" "$TMPDIR_BASE/m-temp-err.txt")

if [[ "$EXIT_CODE" == "0" && -f "$OUT_M_TEMP" ]]; then
    pass "(m) out-path: an output under a system temp root is accepted too -- both allowed roots, not just one"
else
    fail "(m) out-path: expected exit 0 under the temp root, got exit=$EXIT_CODE. Stderr:
$(head -20 "$TMPDIR_BASE/m-temp-err.txt" 2>/dev/null)"
fi

# (m2) outside every allowed root — refused, and nothing created there
OUT_M_ESCAPE="$M_ELSEWHERE/out-m-escape.md"
ERR_M_FILE="$TMPDIR_BASE/m-escape-err.txt"
EXIT_CODE=$(m_assemble "$OUT_M_ESCAPE" "$ERR_M_FILE")

if [[ "$EXIT_CODE" == "2" ]]; then
    pass "(m) out-path: an output under NEITHER allowed root is refused with exit 2"
else
    fail "(m) out-path: expected exit 2 for an out-of-tree destination, got $EXIT_CODE. Stderr:
$(head -20 "$ERR_M_FILE" 2>/dev/null)"
fi

if grep -qiE "plans directory|temp root" "$ERR_M_FILE" 2>/dev/null; then
    pass "(m) out-path: stderr names the allowed destinations, so the caller can fix the call"
else
    fail "(m) out-path: stderr does not name the allowed destinations. Stderr:
$(head -20 "$ERR_M_FILE" 2>/dev/null)"
fi

if [[ ! -e "$OUT_M_ESCAPE" ]]; then
    pass "(m) out-path: nothing was created at the refused destination"
else
    fail "(m) out-path: the refused destination WAS created: $OUT_M_ESCAPE"
fi

# (m3) the same refusal with a file ALREADY at the destination — the overwrite case.
# (m2) only proves nothing was created; a `mv -f` that lands on an existing file destroys
# content instead of creating it, and that is the damage the constraint exists to prevent.
M_VICTIM="$M_ELSEWHERE/victim.md"
printf 'DO-NOT-OVERWRITE-THIS-LINE\n' > "$M_VICTIM"
M_VICTIM_BEFORE=$(cksum < "$M_VICTIM")
EXIT_CODE=$(m_assemble "$M_VICTIM" "$TMPDIR_BASE/m-victim-err.txt")
M_VICTIM_AFTER=$(cksum < "$M_VICTIM")

if [[ "$EXIT_CODE" == "2" ]]; then
    pass "(m) out-path: an EXISTING file outside every allowed root is refused with exit 2 too"
else
    fail "(m) out-path: expected exit 2 for an existing out-of-tree destination, got $EXIT_CODE. Stderr:
$(head -20 "$TMPDIR_BASE/m-victim-err.txt" 2>/dev/null)"
fi

if [[ "$M_VICTIM_BEFORE" == "$M_VICTIM_AFTER" ]]; then
    pass "(m) out-path: and that file is byte-identical afterwards -- the refusal precedes every write"
else
    fail "(m) out-path: the existing file was MODIFIED ($M_VICTIM_BEFORE -> $M_VICTIM_AFTER)"
fi

# (m4) in-place mode: arg2 and arg3 are the same file, inside an allowed root. The shape
# tests/skills/feature-866-flatten-drafts.sh depends on -- the constraint must not break it.
M_INPLACE="$M_PLANS/m-inplace.md"
cp "$PLANNER_FIXTURE" "$M_INPLACE"
EXIT_CODE=0
ERR_M_INPLACE=$(run_with_timeout env TMPDIR="$M_ROOTS" TMP="$M_ROOTS" TEMP="$M_ROOTS" \
    WORKFLOW_PLANS_DIR="$M_PLANS" \
    bash "$ASSEMBLE" --source-kind intent "$INTENT_FIXTURE" "$M_INPLACE" "$M_INPLACE" 2>&1) || EXIT_CODE=$?

if [[ "$EXIT_CODE" == "0" && -f "$M_INPLACE" ]]; then
    pass "(m) out-path: in-place mode (arg2 == arg3) still exits 0 -- the constraint is on the destination root, not on distinctness"
else
    fail "(m) out-path: in-place mode broke (exit=$EXIT_CODE). Stderr: $ERR_M_INPLACE"
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
