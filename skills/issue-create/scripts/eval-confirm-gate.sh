#!/usr/bin/env bash
# eval-confirm-gate.sh <final-json> <severity-label>
#
# Decide whether /issue-create must stop and ask the user before creating.
# Gate = OR of G1..G5; only `severity:high` + codex-affirmed `worth_filing`
# files unattended (#1973 inflow brake). Definitions: SKILL.md "Phase 3" (SSOT).
#
# stdout: "confirm: yes|no" then "reasons: G1,G3" (none → "reasons: ")
# exit:   0 whenever it classifies; non-zero ONLY on wrong argument count.
# Every classifiable failure lands on `confirm: yes` — fail-closed by construction.

set -uo pipefail

emit() {  # <yes|no> <reasons-csv>
    printf 'confirm: %s\n' "$1"
    printf 'reasons: %s\n' "$2"
    exit 0
}

# Arity is a hard error, not something to fail-safe around. The gate previously took
# three arguments (<final-json> <provenance> <severity>); an un-migrated caller would
# hand the retired provenance value to $2, which is now the severity label.
if [[ $# -ne 2 ]]; then
    echo "ERROR: eval-confirm-gate.sh takes exactly 2 arguments: <final-json> <severity-label> (got $#)" >&2
    exit 2
fi

FINAL_JSON="$1"
SEVERITY="$2"

# A missing artifact means the pipeline before this point did not complete.
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
# counts as the reviewer affirming this issue is worth filing. Every other value —
# absent, null, the STRING "true", a number — means the answer did not reach us.
# The former `severity:high` carve-out for a MISSING affirmation is retired (#1973):
# high severity now gates on its own axis (G5) and no longer substitutes for review.
if [[ "$WORTH_FILING" != "true" ]]; then
    REASONS+=("G3")
fi

# G4 — the review never produced a usable second opinion. Stated as an allowlist, not
# a denylist: `upheld` and `replaced` are the only two statuses a completed review can
# leave behind, so an absent, empty or unrecognised one means no review happened.
case "$REVIEW_STATUS" in
    upheld|replaced) ;;
    *) REASONS+=("G4") ;;
esac

# G5 — severity below the autonomous-filing bar. `severity:low` (cosmetic / deferrable)
# and no-label (normal) both require the user's approval; only `severity:high` may file
# unattended, and only when G1..G4 are all clear.
if [[ "$SEVERITY" != "severity:high" ]]; then
    REASONS+=("G5")
fi

if [[ ${#REASONS[@]} -eq 0 ]]; then
    emit no ""
fi

emit yes "$(IFS=,; printf '%s' "${REASONS[*]}")"
