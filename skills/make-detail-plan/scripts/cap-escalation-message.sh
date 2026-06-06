#!/bin/bash
# Emit the cap-reach escalation message structure for make-detail-plan.
set -euo pipefail
cat <<'TEMPLATE'
Cap-reach escalation message order:
1. Loop status — which counter/cap was hit and how many rounds occurred.
2. The planner's current plan — paste or closely summarize.
3. Blocking issues — unresolved reviewer concerns or the pending research question.
TEMPLATE
