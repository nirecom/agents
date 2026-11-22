#!/usr/bin/env bash
# eval-confirm-gate.sh <final-json> [--finding-key <k>]
#
# List which verdict checks fire before /issue-create creates; CC then decides whether it
# agrees or must ask (#1926). Gate = OR of G0..G4. Definitions: SKILL.md "Phase 3" (SSOT).
# G0 (#2019) is bin/finding-filing-gate: session from CLAUDE_CODE_SESSION_ID, claim = the file at `review.artifact_path`.
# stdout: "confirm: yes|no", "reasons: G0,G3" (none → "reasons: "), the info line
#         "worth_filing: true|false|unknown" (never used for gating), and "defer: yes" when G0 defers.
# exit:   0 whenever it classifies; 2 ONLY on a wrong argument shape.
# Every classifiable failure lands on `confirm: yes` — fail-closed by construction.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORTH_FILING="unknown"
DEFER="no"

emit() {  # <yes|no> <reasons-csv>
    printf 'confirm: %s\n' "$1"
    printf 'reasons: %s\n' "$2"
    printf 'worth_filing: %s\n' "$WORTH_FILING"
    [[ "$DEFER" == "yes" ]] && printf 'defer: yes\n'
    exit 0
}

# Arity is a hard error, not something to fail-safe around: an un-migrated caller still
# passing the retired severity label (#1926) must fail loudly, not be read as one argument.
FINDING_KEY=""
if [[ $# -eq 3 && "$2" == "--finding-key" && -n "$3" ]]; then
    FINDING_KEY="$3"
elif [[ $# -ne 1 ]]; then
    echo "ERROR: eval-confirm-gate.sh takes <final-json> [--finding-key <k>] (got $# arguments)" >&2
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

# G0 — the filing approval (#2019). Runs last-in-effect: it may consume one approval record.
# The claim is the reviewed survey artifact itself (`review.artifact_path`), handed over unread:
# the gate hashes the bytes it parses against `review.proposal_sha256` — the one comparison.
# No artifact_path (or no such file) → no claim, so G0 can only consume an approval (fail-closed).
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
G0_ARGS=(--session "${CLAUDE_CODE_SESSION_ID:-}" --review "$(node_path "$FINAL_JSON")")
CLAIM_SRC="$(node -e 'const fs=require("fs");const a=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));const p=a.review&&typeof a.review.artifact_path==="string"?a.review.artifact_path:"";if(p&&fs.existsSync(p))process.stdout.write(p);' "$(node_path "$FINAL_JSON")" 2>/dev/null)"
[[ -n "$CLAIM_SRC" ]] && G0_ARGS+=(--claim "$CLAIM_SRC")
[[ -n "$FINDING_KEY" ]] && G0_ARGS+=(--finding-key "$FINDING_KEY")
G0="$(node "$(node_path "$SCRIPT_CHECKOUT_ROOT/bin/finding-filing-gate")" "${G0_ARGS[@]}" 2>/dev/null | sed -n 's/^g0: //p' | head -n 1)"
case "$G0" in
    pass) ;;
    defer) DEFER="yes" ;;
    *) REASONS+=("G0") ;;
esac

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
