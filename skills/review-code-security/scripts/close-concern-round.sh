#!/usr/bin/env bash
# close-concern-round.sh — stage + check-staged + reduce + finalize + verify for one RCS-2 round.
# Usage: <round> <plans-dir> <session-id> <producer> <exec-label> <report-path>
# Stdout: finalize artifact path, UNRESOLVED=<tally>, CHECK=ok|FINALIZE-FAILED|NOT-STAGED.
# Exit 0 on verified finalize; 1 on check-staged gate failure or finalize failure after retry.
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

if ! bash "$CLI" stage --plans-dir "$PLANS" --session-id "$SID" --format "$FORMAT" \
        --round "$ROUND" --producer "$PRODUCER" --exec "$EXEC" --from-report "$REPORT"; then
    printf 'CHECK=NOT-STAGED — this round was not staged; refusing to close it as verified\n'
    exit 1
fi
if ! MISSING="$(bash "$CLI" check-staged --plans-dir "$PLANS" --session-id "$SID" \
                    --format "$FORMAT" --round "$ROUND" 2>/dev/null)"; then
    printf 'CHECK=NOT-STAGED — round %s is not complete: %s\n' "$ROUND" "${MISSING:-unknown}"
    exit 1
fi
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
