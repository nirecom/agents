#!/usr/bin/env bash
# eval-confirm-gate.sh <final-json>
#
# List which verdict checks fire before /issue-create creates; CC then decides whether it
# agrees or must ask (#1926). Gate = OR of G1..G4. Definitions: SKILL.md "Phase 3" (SSOT).
#
# stdout: "confirm: yes|no", "reasons: G1,G3" (none → "reasons: "), then the info line
#         "worth_filing: true|false|unknown" — reported, never used for gating.
# exit:   0 whenever it classifies; non-zero ONLY on wrong argument count.
# Every classifiable failure lands on `confirm: yes` — fail-closed by construction; `yes` hands
# the decision to Phase 3's CC-agreement check (SKILL.md 3f/3g), where G3 always asks.

set -uo pipefail

WORTH_FILING="unknown"

emit() {  # <yes|no> <reasons-csv>
    printf 'confirm: %s\n' "$1"
    printf 'reasons: %s\n' "$2"
    printf 'worth_filing: %s\n' "$WORTH_FILING"
    exit 0
}

# Arity is a hard error, not something to fail-safe around: an un-migrated caller still
# passing the retired severity label (#1926) must fail loudly, not be read as one argument.
if [[ $# -ne 1 ]]; then
    echo "ERROR: eval-confirm-gate.sh takes exactly 1 argument: <final-json> (got $#)" >&2
    exit 2
fi

FINAL_JSON="$1"

# G3 — the final artifact is missing or unreadable: the pipeline before this point did
# not complete, so nothing below can be trusted.
[[ -n "$FINAL_JSON" && -f "$FINAL_JSON" ]] || emit yes "G3"

FIELDS=$(node -e '
try {
  const fs = require("fs");
  const a = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const verdict = typeof a.verdict === "string" ? a.verdict : "";
  const survey = a.survey && typeof a.survey.verdict === "string" ? a.survey.verdict : "";
  const status = a.review && typeof a.review.status === "string" ? a.review.status : "";
  const worth = a.review && typeof a.review.worth_filing === "boolean" ? String(a.review.worth_filing) : "unknown";
  process.stdout.write([verdict, survey, status, worth].join("\t"));
} catch (e) {
  process.stdout.write("\tunreadable\t\tunknown");
}' "$FINAL_JSON" 2>/dev/null) || FIELDS=$'\tunreadable\t\tunknown'

VERDICT="$(printf '%s' "$FIELDS" | cut -f1)"
SURVEY_VERDICT="$(printf '%s' "$FIELDS" | cut -f2)"
REVIEW_STATUS="$(printf '%s' "$FIELDS" | cut -f3)"
WORTH_FILING="$(printf '%s' "$FIELDS" | cut -f4)"
[[ "$WORTH_FILING" == "true" || "$WORTH_FILING" == "false" ]] || WORTH_FILING="unknown"

[[ "$SURVEY_VERDICT" == "unreadable" ]] && emit yes "G3"

REASONS=()

# G1 — the verdict itself changes existing issues rather than only adding one.
# `sub-of` and `bulk-sub-of` belong here with `reopen` and `make-parent` (CPR-ORTH): they
# re-parent an existing issue and can reopen every closed ancestor of the parent chain.
case "$VERDICT" in
    reopen|make-parent|sub-of|bulk-sub-of) REASONS+=("G1") ;;
esac

# G2 — the independent reviewer disputed the survey, or survey and final verdicts differ.
if [[ "$REVIEW_STATUS" == "disputed" || ( -n "$SURVEY_VERDICT" && "$SURVEY_VERDICT" != "$VERDICT" ) ]]; then
    REASONS+=("G2")
fi

# G4 — the review never produced a usable second opinion. Stated as an allowlist, not
# a denylist: `upheld` and `disputed` are the only two statuses a completed review can
# leave behind, so an absent, empty or unrecognised one means no review happened.
case "$REVIEW_STATUS" in
    upheld|disputed) ;;
    *) REASONS+=("G4") ;;
esac

if [[ ${#REASONS[@]} -eq 0 ]]; then
    emit no ""
fi

emit yes "$(IFS=,; printf '%s' "${REASONS[*]}")"
