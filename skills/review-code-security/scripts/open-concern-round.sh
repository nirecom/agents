#!/usr/bin/env bash
# Open this invocation's concern-ledger round for the shared code review.

# Why a script and not four CLI calls in the SKILL: the round number is one
# fact that four later steps (stage, reduce, finalize, check-finalized) all
# have to agree on, and the two producers of the round — the codex reviewer and
# the security scanner — must be handed the SAME prior concerns. Resolving that
# once, here, is what keeps a re-run of the skill from minting a second numbering
# the author has never seen.
#
# Contract: key=value lines on stdout, then the prior-concern block the scanner
# receives verbatim. ROUND=0 means the ledger is unavailable this run; the
# reason is on the NOT-STAGED line and the review still proceeds unnumbered.
set -uo pipefail

FORMAT="review-security-shared"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${AGENTS_CONFIG_DIR:-$(cd "$SELF_DIR/../../.." && pwd)}"
CLI="$ROOT/bin/concern-ledger"

SID="${SESSION_ID:-${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}}"
PLANS="${PLANS_DIR:-${WORKFLOW_PLANS_DIR:-${HOME:-}/.workflow-plans}}"

unavailable() {
    printf 'ROUND=0\n'
    printf '## Concern Ledger: NOT-STAGED — %s\n' "$1"
    exit 0
}

[ -n "$SID" ] || unavailable "no session id in the environment"
[ -r "$CLI" ] || unavailable "the concern-ledger CLI is not readable at bin/concern-ledger"
mkdir -p "$PLANS" 2>/dev/null || unavailable "the plans directory could not be created: $PLANS"

LEDGER="$PLANS/$SID-$FORMAT-concern-ledger.txt"
ROUND_FILE="$PLANS/$SID-$FORMAT-round-number.txt"

# A live ledger plus a recorded round means this session has already reviewed:
# advance. A live ledger with no recorded round is the previous cycle's residue,
# so round 1 opens a fresh cycle rather than colliding with its IDs.
ROUND=1
PREV=""
[ -s "$ROUND_FILE" ] && PREV="$(tr -cd '0-9' < "$ROUND_FILE")"
if [ -s "$LEDGER" ] && [ -n "$PREV" ] && [ "$PREV" -ge 1 ]; then
    ROUND=$((PREV + 1))
elif [ -s "$LEDGER" ]; then
    bash "$CLI" begin-round --plans-dir "$PLANS" --session-id "$SID" \
        --format "$FORMAT" --round 1 >/dev/null 2>&1 || true
fi
printf '%s\n' "$ROUND" > "$ROUND_FILE" 2>/dev/null || true

printf 'ROUND=%s\n' "$ROUND"
printf 'PLANS_DIR=%s\n' "$PLANS"
printf 'SESSION_ID=%s\n' "$SID"

# The block is emitted only when there is something in it: an empty
# [PRIOR CONCERNS START]/[PRIOR CONCERNS END] pair reads to a scanner as
# "nothing is open", which is a claim this script has no basis to make on
# round 1.
if [ "$ROUND" -ge 2 ] && [ -s "$LEDGER" ]; then
    PRIOR="$(bash "$CLI" render-prior --plans-dir "$PLANS" --session-id "$SID" \
        --format "$FORMAT" 2>/dev/null)"
    if [ -n "${PRIOR//[[:space:]]/}" ]; then
        printf '[PRIOR CONCERNS START]\n%s\n[PRIOR CONCERNS END]\n' "$PRIOR"
    fi
fi
exit 0
