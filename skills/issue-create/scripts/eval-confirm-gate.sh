#!/usr/bin/env bash
# eval-confirm-gate.sh <final-json> <severity-label>
#
# Decide whether /issue-create must stop and ask the user before creating.
# The gate is the logical OR of four independent conditions:
#
#   G1  the final verdict touches EXISTING issues            destructive / restructuring
#       (`reopen`, `make-parent`, `sub-of`, `bulk-sub-of`)
#   G2  the review stage replaced the survey verdict         two graders disagreed
#   G3  the review did not confirm the proposal is worth      filing may be redundant
#       filing (`review.worth_filing` is not `true`), and
#       the severity is not high
#   G4  the review did not produce a usable second opinion   the verdict is unverified
#
# stdout:  line 1  "confirm: yes" | "confirm: no"
#          line 2  "reasons: G1,G3"   (no reason fires → "reasons: ")
# exit:    0 whenever it classifies — this script classifies, the caller decides.
#          non-zero ONLY on a wrong argument count.
#
# Every classifiable failure mode (unreadable artifact, an unusable worth_filing value)
# lands on `confirm: yes`. Asking one extra question is recoverable; creating or
# reopening an issue nobody asked for is not.

set -uo pipefail

emit() {  # <yes|no> <reasons-csv>
    printf 'confirm: %s\n' "$1"
    printf 'reasons: %s\n' "$2"
    exit 0
}

# Arity is a hard error, not something to fail-safe around. The gate previously took
# three arguments (<final-json> <provenance> <severity>); an un-migrated caller would
# hand the retired provenance value to $2, which is now the severity label, and every
# issue would be classified against a severity that is really "user-explicit". Silence
# would hide that mis-wiring for as long as the wrong answer happened to be `yes`.
if [[ $# -ne 2 ]]; then
    echo "ERROR: eval-confirm-gate.sh takes exactly 2 arguments: <final-json> <severity-label> (got $#)" >&2
    exit 2
fi

FINAL_JSON="$1"
SEVERITY="$2"

# A missing artifact means the pipeline before this point did not complete.
# Nothing can be classified, so everything is confirmed.
[[ -n "$FINAL_JSON" && -f "$FINAL_JSON" ]] || emit yes "G3"

# Read the switches the artifact owns. Anything unparseable → "unreadable",
# which the reasoning below treats as every gate firing that can fire.
FIELDS=$(node -e '
try {
  const fs = require("fs");
  const a = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const verdict = typeof a.verdict === "string" ? a.verdict : "";
  const survey = a.survey && typeof a.survey.verdict === "string" ? a.survey.verdict : "";
  const status = a.review && typeof a.review.status === "string" ? a.review.status : "";
  const worth = a.review && typeof a.review.worth_filing === "boolean" ? String(a.review.worth_filing) : "";
  process.stdout.write([verdict, survey, status, worth].join("\t"));
} catch (e) {
  process.stdout.write("\tunreadable\t\t");
}' "$FINAL_JSON" 2>/dev/null) || FIELDS=$'\tunreadable\t\t'

VERDICT="$(printf '%s' "$FIELDS" | cut -f1)"
SURVEY_VERDICT="$(printf '%s' "$FIELDS" | cut -f2)"
REVIEW_STATUS="$(printf '%s' "$FIELDS" | cut -f3)"
WORTH_FILING="$(printf '%s' "$FIELDS" | cut -f4)"

[[ "$SURVEY_VERDICT" == "unreadable" ]] && emit yes "G3"

REASONS=()

# G1 — the verdict itself changes existing issues rather than only adding one.
# `sub-of` and `bulk-sub-of` belong here with `reopen` and `make-parent` (CPR-ORTH): they
# re-parent an existing issue and can reopen every closed ancestor of the parent chain.
case "$VERDICT" in
    reopen|make-parent|sub-of|bulk-sub-of) REASONS+=("G1") ;;
esac

# G2 — the independent reviewer did not reach the survey's conclusion.
if [[ "$REVIEW_STATUS" == "replaced" || ( -n "$SURVEY_VERDICT" && "$SURVEY_VERDICT" != "$VERDICT" ) ]]; then
    REASONS+=("G2")
fi

# G3 — only the literal boolean `true`, extracted as such by the node reader above,
# counts as the reviewer affirming that this issue is worth filing. Every other value
# — absent, null, the STRING "true", a number — is "the reviewer's answer did not
# reach us", which is the case the gate exists for. Fail-closed by construction: the
# extractor emits the empty string for anything that is not a JSON boolean, so no
# stringified value can be mistaken for an affirmation.
#
# A high-severity finding is worth an issue on its own, so severity:high stands in for
# a MISSING affirmation — the same carve-out the old provenance-based G3 had. It must
# NOT stand in for an explicit "false": the reviewer already looked at the evidence and
# concluded filing is redundant, and a severity label cannot out-rank that conclusion.
if [[ "$WORTH_FILING" == "true" ]]; then
    :  # the reviewer confirmed this is not a duplicate and is worth filing
elif [[ "$SEVERITY" == "severity:high" && "$WORTH_FILING" != "false" ]]; then
    :  # worth_filing absent/unreadable — severity carve-out applies
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
