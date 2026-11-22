#!/bin/bash
# skills/review-tests/scripts/run-fallback-review.sh — the CC-fallback round of review-tests
# (#2478 S3-3), run after the wrapper ends exit 3 (codex unusable). Both uses go through the
# same wrapper, so the round counter, the 2+1 cap and the terminal guard apply unchanged.
#   --brief    print FALLBACK_ROUND=<n> (and the prior for round >= 2); counts nothing
#   <report>   the test-reviewer report, run as one prestaged ADVANCE (one counted round)
# Output and exit code are the wrapper's (RT-3 table). Caller env: SESSION_ID PLANS_DIR EXTENSIONS_USED.
set -uo pipefail
WRAPPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-codex-review-loop.sh"

if [[ $# -ne 1 || -z "${1:-}" ]]; then
  echo "usage: run-fallback-review.sh --brief | <report>" >&2
  exit 4
fi
if [[ "$1" == "--brief" ]]; then
  exec bash "$WRAPPER" --fallback-brief
fi
exec bash "$WRAPPER" --prestaged-report "$1" --prestaged-producer test-reviewer --prestaged-exec PERFORMED
