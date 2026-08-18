#!/usr/bin/env bash
# Tests: skills/make-detail-plan/SKILL.md, skills/make-outline-plan/SKILL.md, skills/review-plan-security/SKILL.md, skills/review-tests/SKILL.md, skills/_shared/codex-review-loop.md
# Tags: codex-review-loop, raw-persistence, static-protocol, table-driven, scope:issue-specific, pwsh-not-required
#
# #2068 (P4-2): the wrapper emits the terminal round's codex output, but only the
# four orchestrators can persist it. They are declarative documents, so their
# contract is checked statically — each must name the RAW file for its own format
# with the round as a placeholder, read that round from the file that still
# exists at that exit, and never derive it by subtracting one.
# TL3 gap: whether a real session writes the file (checked at the USER_VERIFIED preflight).
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
assert_contains() {
    if printf '%s' "$3" | grep -Fq -- "$2"; then pass "$1"
    else echo "FAIL: $1 — expected to find $(printf '%q' "$2")"; FAIL=$((FAIL + 1)); fi
}
assert_not_contains() {
    if printf '%s' "$3" | grep -Fq -- "$2"; then
        echo "FAIL: $1 — still contains $(printf '%q' "$2")"; FAIL=$((FAIL + 1))
    else pass "$1"; fi
}
assert_eq() {
    if [ "$2" = "$3" ]; then pass "$1"
    else echo "FAIL: $1 — want=$(printf '%q' "$2") got=$(printf '%q' "$3")"; FAIL=$((FAIL + 1)); fi
}

# win <file> <anchor-regex> — the anchor line plus the nine that follow it, which
# is the block a reader treats as one instruction.
win() { grep -m1 -A 9 -E -- "$2" "$1" 2>/dev/null; }

file_state() { if [ -f "$1" ]; then printf 'present'; else printf 'missing'; fi; }

SHARED="$AGENTS_ROOT/skills/_shared/codex-review-loop.md"

# ---------------------------------------------------------------------------
# 1. Each orchestrator names the RAW file for its own format. The four names are
#    irregular by history, so a row per format is the only honest check: a
#    generic "mentions raw.md" would pass on the wrong filename (CPR-ORTH).
# ---------------------------------------------------------------------------
echo ""
echo "--- 2068-raw-1: the four RAW names, one per orchestrator ---"

while IFS='|' read -r FMT SKILL_PATH RAW_SHAPE; do
    case "$FMT" in ''|\#*) continue ;; esac

    SKILL_FULL="$AGENTS_ROOT/$SKILL_PATH"
    assert_eq "1 ($FMT): the orchestrator is present to check" "present" "$(file_state "$SKILL_FULL")"
    BODY="$(cat "$SKILL_FULL" 2>/dev/null)"

    assert_contains "1 ($FMT): names its RAW file with the round left as a placeholder" \
        "$RAW_SHAPE" "$BODY"
    # The round is no longer derivable by arithmetic: at a terminal the counter
    # is gone, so "current minus one" has nothing to read.
    assert_not_contains "1 ($FMT): no longer derives the round by subtracting one" \
        "round_number-1" "$BODY"
    assert_not_contains "1 ($FMT): and carries no leftover subtraction expression" \
        "- 1 ))" "$BODY"
    assert_not_contains "1 ($FMT): nor pins the RAW name to round 1" \
        "-codex-round-1-raw.md" "$BODY"
    # LAND is gone as a verdict, so no orchestrator may still route on it.
    assert_not_contains "1 ($FMT): and no longer mentions the removed LAND verdict" \
        "LAND" "$BODY"
done <<'FORMATS'
detail-plan|skills/make-detail-plan/SKILL.md|<session-id>-codex-round-<N>-raw.md
outline-plan|skills/make-outline-plan/SKILL.md|<session-id>-outline-codex-round-<N>-raw.md
security-plan|skills/review-plan-security/SKILL.md|<session-id>-security-plan-codex-round-<N>-raw.md
test-review|skills/review-tests/SKILL.md|<session-id>-test-review-codex-round-<N>-raw.md
FORMATS

# ---------------------------------------------------------------------------
# 2. Where the round number comes from at each exit. A terminal deletes the
#    counter and writes last-round.txt; a continuation keeps the counter. Reading
#    the wrong one is how the terminal RAW ends up named for a round that has no
#    output — so the source is pinned per exit, not per document.
# ---------------------------------------------------------------------------
echo ""
echo "--- 2068-raw-2: which file the round number is read from, per exit ---"

while IFS='|' read -r FMT SKILL_PATH ANCHOR SOURCE_FILE WHAT; do
    case "$FMT" in ''|\#*) continue ;; esac

    SKILL_FULL="$AGENTS_ROOT/$SKILL_PATH"
    BLOCK="$(win "$SKILL_FULL" "$ANCHOR")"

    assert_contains "2 ($FMT/$WHAT): the exit is documented at all" "exit" "$BLOCK"
    assert_contains "2 ($FMT/$WHAT): its block tells the orchestrator to save the raw output" \
        "raw.md" "$BLOCK"
    assert_contains "2 ($FMT/$WHAT): and takes the round from $SOURCE_FILE" \
        "$SOURCE_FILE" "$BLOCK"
done <<'EXITS'
detail-plan|skills/make-detail-plan/SKILL.md|exit 6|last-round.txt|terminal
detail-plan|skills/make-detail-plan/SKILL.md|exit 1|round-number.txt|continuation
outline-plan|skills/make-outline-plan/SKILL.md|exit 6|last-round.txt|terminal
outline-plan|skills/make-outline-plan/SKILL.md|exit 1|round-number.txt|continuation
security-plan|skills/review-plan-security/SKILL.md|exit 6|last-round.txt|terminal
security-plan|skills/review-plan-security/SKILL.md|exit 1|last-round.txt|single-round terminal
test-review|skills/review-tests/SKILL.md|exit 6|last-round.txt|terminal
test-review|skills/review-tests/SKILL.md|exit 1|last-round.txt|single-round terminal
EXITS

# ---------------------------------------------------------------------------
# 3. ESCALATE persists its raw output too. Exit 2 and exit 6 are both terminals
#    that end on unresolved findings; only one of them being saved would lose the
#    evidence for the other (CPR-ORTH).
# ---------------------------------------------------------------------------
echo ""
echo "--- 2068-raw-3: the escalate terminal saves its output as well ---"

while IFS='|' read -r FMT SKILL_PATH; do
    case "$FMT" in ''|\#*) continue ;; esac
    BLOCK="$(win "$AGENTS_ROOT/$SKILL_PATH" "exit 2")"
    assert_contains "3 ($FMT): the escalate block saves the raw output too" "raw.md" "$BLOCK"
    assert_contains "3 ($FMT): from the same last-round.txt the other terminal uses" \
        "last-round.txt" "$BLOCK"
done <<'ESCALATE'
detail-plan|skills/make-detail-plan/SKILL.md
outline-plan|skills/make-outline-plan/SKILL.md
security-plan|skills/review-plan-security/SKILL.md
test-review|skills/review-tests/SKILL.md
ESCALATE

# ---------------------------------------------------------------------------
# 4. The shared contract these four documents follow. It is the SSOT: the RAW
#    table, the no-overwrite rule and the exit map live here, and the per-skill
#    text above is a reference to it rather than a fifth copy.
# ---------------------------------------------------------------------------
echo ""
echo "--- 2068-raw-4: the shared codex-review-loop contract ---"

assert_eq "4: the shared contract document is present" "present" "$(file_state "$SHARED")"
SHARED_BODY="$(cat "$SHARED" 2>/dev/null)"

assert_contains "4: exit 6 is documented as the HIGH_UNRESOLVED terminal" \
    "HIGH_UNRESOLVED" "$SHARED_BODY"
assert_not_contains "4: and the silent LAND verdict it replaced is gone" "LAND" "$SHARED_BODY"
assert_contains "4: the terminal round number is published in last-round.txt" \
    "last-round.txt" "$SHARED_BODY"
assert_contains "4: the counter is owned by the shared wrapper" \
    "run-codex-review-loop" "$SHARED_BODY"
assert_not_contains "4: not by the per-stage wrapper any more" \
    "The per-stage wrapper script maintains" "$SHARED_BODY"
assert_contains "4: an existing RAW file for a round is never overwritten" \
    "overwrite" "$SHARED_BODY"
assert_contains "4: --force-round is documented as recovery and test use only" \
    "--force-round" "$SHARED_BODY"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed."
    exit 0
fi
exit 1
