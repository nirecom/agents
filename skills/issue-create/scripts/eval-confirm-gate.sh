#!/usr/bin/env bash
# eval-confirm-gate.sh <final-json> <provenance> <severity-label>
#
# Decide whether /issue-create must stop and ask the user before creating.
# The gate is the logical OR of four independent conditions:
#
#   G1  the final verdict touches EXISTING issues            destructive / restructuring
#       (`reopen`, `make-parent`, `sub-of`, `bulk-sub-of`)
#   G2  the review stage replaced the survey verdict         two graders disagreed
#   G3  the request was not an explicit user ask, and the    no one asked for this issue
#       severity is not high
#   G4  the review did not produce a usable second opinion   the verdict is unverified
#
# stdout:  line 1  "confirm: yes" | "confirm: no"
#          line 2  "reasons: G1,G3"   (no reason fires → "reasons: ")
# exit:    always 0 — this script classifies, the caller decides.
#
# Every failure mode (missing argument, unreadable artifact, a provenance value the
# classifier never produced) lands on `confirm: yes`. Asking one extra question is
# recoverable; creating or reopening an issue nobody asked for is not.

set -uo pipefail

GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVENANCE_CLI="$(cd "$GATE_DIR/../../.." && pwd)/bin/github-issues/issue-provenance"

emit() {  # <yes|no> <reasons-csv>
    printf 'confirm: %s\n' "$1"
    printf 'reasons: %s\n' "$2"
    exit 0
}

FINAL_JSON="${1:-}"
PROVENANCE="${2:-}"
SEVERITY="${3:-}"

# A missing artifact or provenance argument means the pipeline before this point
# did not complete. Nothing can be classified, so everything is confirmed.
[[ -n "$FINAL_JSON" && -f "$FINAL_JSON" ]] || emit yes "G3"
[[ $# -ge 3 ]] || emit yes "G3"

# Read the two switches the artifact owns. Anything unparseable → "unreadable",
# which the reasoning below treats as every gate firing that can fire.
FIELDS=$(node -e '
try {
  const fs = require("fs");
  const a = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const verdict = typeof a.verdict === "string" ? a.verdict : "";
  const survey = a.survey && typeof a.survey.verdict === "string" ? a.survey.verdict : "";
  const status = a.review && typeof a.review.status === "string" ? a.review.status : "";
  process.stdout.write([verdict, survey, status].join("\t"));
} catch (e) {
  process.stdout.write("\tunreadable\t");
}' "$FINAL_JSON" 2>/dev/null) || FIELDS=$'\tunreadable\t'

VERDICT="$(printf '%s' "$FIELDS" | cut -f1)"
SURVEY_VERDICT="$(printf '%s' "$FIELDS" | cut -f2)"
REVIEW_STATUS="$(printf '%s' "$FIELDS" | cut -f3)"

[[ "$SURVEY_VERDICT" == "unreadable" ]] && emit yes "G3"

REASONS=()

# G1 — the verdict itself changes existing issues rather than only adding one.
# `sub-of` and `bulk-sub-of` belong here with `reopen` and `make-parent` (CPR-5): they
# re-parent an existing issue and can reopen every closed ancestor of the parent chain.
case "$VERDICT" in
    reopen|make-parent|sub-of|bulk-sub-of) REASONS+=("G1") ;;
esac

# G2 — the independent reviewer did not reach the survey's conclusion.
if [[ "$REVIEW_STATUS" == "replaced" || ( -n "$SURVEY_VERDICT" && "$SURVEY_VERDICT" != "$VERDICT" ) ]]; then
    REASONS+=("G2")
fi

# G3 — only the exact string `user-explicit` earns silence. Every other value,
# including an empty one and any error text the classifier may have emitted,
# is "we do not know who asked", which is the case the gate exists for.
#
# The argument alone cannot decide this. It reaches the gate through the model, and
# the one thing G3 exists to detect is the model deciding to file an issue by itself —
# so a gate that believed the argument would be asking the suspect for an alibi. The
# classifier's own record is re-read here and the two are combined at MINIMUM
# privilege: the argument can only lower the answer, never raise it. An absent,
# expired or unreadable record reads mid-workflow, so a gate that cannot verify
# never grants silence.
PROV_TRIMMED="$(printf '%s' "$PROVENANCE" | tr -d '[:space:]')"
PROV_REPLAY="mid-workflow"
if [[ -f "$PROVENANCE_CLI" ]]; then
    PROV_REPLAY="$(bash "$PROVENANCE_CLI" --result 2>/dev/null | head -n 1 | tr -d '[:space:]')"
    [[ "$PROV_REPLAY" == "user-explicit" ]] || PROV_REPLAY="mid-workflow"
fi

if [[ "$PROV_TRIMMED" == "user-explicit" && "$PROV_REPLAY" == "user-explicit" ]]; then
    :  # both observers agree the user asked for this
elif [[ "$SEVERITY" == "severity:high" ]] &&
     [[ "$PROV_TRIMMED" == "mid-workflow" || "$PROV_TRIMMED" == "user-explicit" ]]; then
    # A high-severity finding is worth an issue on its own. The carve-out stays narrow:
    # it needs a value the classifier can actually emit, so an unusable provenance
    # (empty, typo, error text) is never rescued by severity.
    :
else
    REASONS+=("G3")
fi

# G4 — the review never produced a usable second opinion. Stated as an allowlist, not
# a denylist: `upheld` and `replaced` are the only two statuses a completed review can
# leave behind, so an absent, empty or unrecognised one means no review happened —
# which is exactly what G4 is for.
case "$REVIEW_STATUS" in
    upheld|replaced) ;;
    *) REASONS+=("G4") ;;
esac

if [[ ${#REASONS[@]} -eq 0 ]]; then
    emit no ""
fi

emit yes "$(IFS=,; printf '%s' "${REASONS[*]}")"
