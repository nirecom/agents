#!/usr/bin/env bash
# Stage the round's producer delta, reduce the ledger, finalize, and verify
# the finalized artifact — the four bin/concern-ledger calls that always run
# together once both RCS-2 producers (security-scanner, quality gates) have
# finished this round.

# Why one script and not four inline SKILL.md steps: rules/prompt.md §1.3
# caps an inline procedure at 3 steps. stage/reduce/finalize/check-finalized
# is one atomic close-out the caller never wants split mid-sequence, and a
# failed check-finalized needs a same-script retry of finalize rather than a
# second round-trip through the orchestrator.

# Usage: close-concern-round.sh <round> <plans-dir> <session-id> <producer> <exec-label> <report-path>
# Stdout contract: the finalize artifact path, then `UNRESOLVED=<tally line>`,
# then `CHECK=ok` or `CHECK=FINALIZE-FAILED`.
# Exit 0 on a verified finalize, 1 when check-finalized still fails after one retry.
set -uo pipefail

FORMAT="review-security-shared"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${AGENTS_CONFIG_DIR:-$(cd "$SELF_DIR/../../.." && pwd)}"
CLI="$ROOT/bin/concern-ledger"

ROUND="${1:?round required}"
PLANS="${2:?plans-dir required}"
SID="${3:?session-id required}"
PRODUCER="${4:?producer required}"
EXEC="${5:?exec label required}"
REPORT="${6:?from-report path required}"

bash "$CLI" stage --plans-dir "$PLANS" --session-id "$SID" --format "$FORMAT" \
    --round "$ROUND" --producer "$PRODUCER" --exec "$EXEC" --from-report "$REPORT"
bash "$CLI" reduce --plans-dir "$PLANS" --session-id "$SID" --format "$FORMAT" --round "$ROUND"

finalize_and_check() {
    bash "$CLI" finalize --plans-dir "$PLANS" --session-id "$SID" --format "$FORMAT" \
        --mode terminal --reason "security review round $ROUND ended" --round "$ROUND"
    bash "$CLI" check-finalized --plans-dir "$PLANS" --session-id "$SID" --format "$FORMAT" --round "$ROUND"
}

if finalize_and_check; then
    printf 'UNRESOLVED=%s\n' "$(bash "$CLI" tally --plans-dir "$PLANS" --session-id "$SID" --format "$FORMAT")"
    printf 'CHECK=ok\n'
    exit 0
fi

# One retry: finalize is idempotent (bin/lib/concern-ledger/finalize.sh), so a
# second attempt recovers from a transient write/read race without the
# caller having to re-derive round/plans/session state.
if finalize_and_check; then
    printf 'UNRESOLVED=%s\n' "$(bash "$CLI" tally --plans-dir "$PLANS" --session-id "$SID" --format "$FORMAT")"
    printf 'CHECK=ok\n'
    exit 0
fi

printf 'CHECK=FINALIZE-FAILED\n'
exit 1
