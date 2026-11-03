#!/usr/bin/env bash
# record-confirm-decision.sh <plans-dir> <session-id> <auto|asked> <reasons> <rationale>
#
# Append one Phase 3 confirm decision to <plans-dir>/<session-id>-issue-create-confirm.log
# as "<UTC time>\t<auto|asked>\t<reasons>\t<rationale>", so a decision CC took without
# asking can be traced afterwards (#1926).
# exit: 0 = line appended; 1 = plans dir not creatable or append failed; 2 = bad arguments
#       (nothing written). Non-zero makes Phase 3 fall back to asking the user (3g); it never
#       blocks the filing itself, only the self-approval.

set -uo pipefail

RCD_PLANS_DIR="${1:-}"
RCD_SID="${2:-}"
RCD_DECISION="${3:-}"
RCD_REASONS="${4:-}"
RCD_RATIONALE="${5:-}"

if [[ -z "$RCD_PLANS_DIR" || ! "$RCD_SID" =~ ^[A-Za-z0-9-]+$ || ( "$RCD_DECISION" != "auto" && "$RCD_DECISION" != "asked" ) ]]; then
    echo "WARN: record-confirm-decision.sh needs <plans-dir>, <session-id> ([A-Za-z0-9-]+) and auto|asked; nothing recorded" >&2
    exit 2
fi

# One record per line: a tab or newline inside a field would split it into a false column or row.
flatten() { printf '%s' "$1" | tr '\t\r\n' '   '; }

mkdir -p "$RCD_PLANS_DIR" 2>/dev/null || { echo "WARN: cannot create $RCD_PLANS_DIR; nothing recorded" >&2; exit 1; }
printf '%s\t%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(flatten "$RCD_DECISION")" \
    "$(flatten "$RCD_REASONS")" "$(flatten "$RCD_RATIONALE")" \
    >> "$RCD_PLANS_DIR/$RCD_SID-issue-create-confirm.log" 2>/dev/null \
    || { echo "WARN: cannot append to $RCD_PLANS_DIR/$RCD_SID-issue-create-confirm.log" >&2; exit 1; }
exit 0
