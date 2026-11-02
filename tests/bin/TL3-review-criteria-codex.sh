#!/bin/bash
# tests/bin/TL3-review-criteria-codex.sh
# Tests: bin/review-plan-codex, skills/_shared/review-criteria.md
# Tags: review-criteria, codex, bin, tl3, scope:common
# T9 (#2814): real codex judges three detail fixtures against one intent/outline pair.

# Skip gates — evaluated before set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v codex >/dev/null 2>&1 || exit 77
[ -x "$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" ] || exit 77
"$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" --is-off RUN_TL3 off && exit 77
[ -x "$SCRIPT_CHECKOUT_ROOT/bin/review-plan-codex" ] || exit 77

# TL3 gap:
# - The TL2 siblings (feature-2814-review-criteria-block.sh / -wiring.sh) pin the
#   prompt bytes with a mock codex; only this file checks that a real model
#   actually applies the criteria (forbidden behavior, copied section, clean plan).
# - Model output is non-deterministic: one run per fixture, no retry. A flaky
#   verdict here is a signal about the criteria wording, not a harness bug.

set -uo pipefail

. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP_ROOT="$(make_tmp)"
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT"
unset CLAUDE_CODE_SESSION_ID PROJECT_NFR CODEX_REVIEW_MAX_DIFF_LINES CODEX_NFR_MAX_LINES CODEX_NFR_MAX_BYTES
export PLAN_LANG=english CONV_LANG=english
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMP_ROOT/transcripts"
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR"

FX="$SCRIPT_CHECKOUT_ROOT/tests/bin/TL3-review-criteria-codex"
BIN="$SCRIPT_CHECKOUT_ROOT/bin/review-plan-codex"

# Pinned config root: empty .env so no ambient PROJECT_NFR or codex knobs leak in.
CFG="$TMP_ROOT/cfg"
mkdir -p "$CFG"
: > "$CFG/.env"
PROJ="$TMP_ROOT/proj"
mkdir -p "$PROJ"

# review <fixture> <outfile>: one real codex review of a detail fixture.
review() {
  local rc=0
  (cd "$TMP_ROOT" && AGENTS_MAIN_ROOT="$CFG" run_with_timeout 600 "$BIN" \
    --input "$FX/$1" --format detail-plan --round 1 \
    --context "$FX/intent.md" --context "$FX/outline.md" \
    --project-root "$PROJ" --no-log) > "$2" 2>&1 || rc=$?
  echo "$rc"
}

# body <outfile>: the codex output between the untrusted-content markers.
body() {
  awk '/^<!-- begin-codex-output/{f=1; next} /^<!-- end-codex-output/{f=0} f' "$1"
}

performed() {
  grep -q '^## Codex Review: PERFORMED' "$1"
}

approved() {
  body "$1" | awk 'NF{print; exit}' | grep -q '^APPROVED'
}

case_begin "forbidden-behavior-not-approved" "bin/review-plan-codex"
OUT_A="$TMP_ROOT/a.txt"
rc=$(review detail-adds-forbidden.md "$OUT_A")
if performed "$OUT_A"; then
  pass "(a) codex review performed (rc=$rc)"
  if approved "$OUT_A"; then
    fail "(a) plan adding an outline-forbidden retry was APPROVED"
  else
    pass "(a) plan adding an outline-forbidden retry is not APPROVED"
  fi
  if body "$OUT_A" | grep -q -i -E 'retr(y|ies)'; then
    pass "(a) a concern names the forbidden retry"
  else
    fail "(a) no concern mentions the retry"
  fi
else
  fail "(a) codex review not performed: $(head -3 "$OUT_A")"
fi
case_end

case_begin "copied-outline-section-flagged" "bin/review-plan-codex"
OUT_B="$TMP_ROOT/b.txt"
rc=$(review detail-copies-outline.md "$OUT_B")
if performed "$OUT_B"; then
  pass "(b) codex review performed (rc=$rc)"
  if approved "$OUT_B"; then
    fail "(b) plan copying the outline Stop Policy section was APPROVED"
  else
    pass "(b) plan copying an outline section is not APPROVED"
  fi
  if body "$OUT_B" | grep -q -i -E 'stop policy'; then
    pass "(b) a concern names the copied section heading (Stop Policy)"
  else
    fail "(b) no concern names the copied section heading"
  fi
else
  fail "(b) codex review not performed: $(head -3 "$OUT_B")"
fi
case_end

case_begin "clean-reference-plan-approved" "bin/review-plan-codex"
OUT_C="$TMP_ROOT/c.txt"
rc=$(review detail-reference-only.md "$OUT_C")
if performed "$OUT_C"; then
  pass "(c) codex review performed (rc=$rc)"
  if approved "$OUT_C"; then
    pass "(c) clean plan with a one-line outline reference is APPROVED"
  else
    fail "(c) clean plan not APPROVED: $(body "$OUT_C" | head -5)"
  fi
else
  fail "(c) codex review not performed: $(head -3 "$OUT_C")"
fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
