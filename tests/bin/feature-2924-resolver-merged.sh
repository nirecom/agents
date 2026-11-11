#!/usr/bin/env bash
# Tests: bin/resolve-accepted-tradeoffs-file, bin/lib/review-plan-codex/inputs.sh
# Tags: scope:issue-specific, TL2, accepted-tradeoffs, staged-heading, resolver, settled-decisions
# lang-check: ignore — the assertions match plan-language marker values and plan text the code under test emits (functional data).
# #2924: the resolver writes ONE merged file per suffix chain at
# <WORKFLOW_STATE_DIR>/<sid>.control/accepted-tradeoffs.<first suffix>.md and prints its path.
# Intent stage = `(intent)` or the legacy heading of the intent file; outline/detail stages =
# their own staged section. A legacy heading in outline/detail is a carried copy and is read
# only when the intent file is unreadable (rescue). Path-shape cases stay in feature-2154.

# TL3 gap: no live codex round shows the merged block is honoured as settled.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
TMPROOT="$(np "$(make_tmp)")"; readonly TMPROOT
trap 'cd /; rm -rf "$TMPROOT"' EXIT
harness_isolate "$TMPROOT"
cd "$TMPROOT" || exit 1

RESOLVER="$SCRIPT_CHECKOUT_ROOT/bin/resolve-accepted-tradeoffs-file"
EXTRACT="$SCRIPT_CHECKOUT_ROOT/bin/extract-mandatory-sections"
REVIEW_PLAN_CODEX="$SCRIPT_CHECKOUT_ROOT/bin/review-plan-codex"

check() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
# resolve <plans> <sid> <suffix>... → OUT (normalized) / RC / LINES
resolve() {
  local raw
  raw="$(run_with_timeout 90 bash "$RESOLVER" "$@" 2>/dev/null)"; RC=$?
  LINES="$(printf '%s' "$raw" | grep -c . || true)"
  OUT=""; [ -z "$raw" ] || OUT="$(np "$raw")"
}
want_path() { printf '%s/%s.control/accepted-tradeoffs.%s.md' "$WORKFLOW_STATE_DIR" "$1" "$2"; }
h2_count() { local n; n="$(grep -cx "## $2" "$1" 2>/dev/null || true)"; printf '%s' "${n:-0}"; }
# body_has <file> <heading> <marker> — the marker sits inside that section's body.
body_has() { "$EXTRACT" "$1" --section "$2" 2>/dev/null | grep -qF -- "$3"; }
lacks() { ! grep -qE -- "$2" "$1" 2>/dev/null; }
# plan <dir> <sid> <suffix> <lines...>
plan() { local d="$1" s="$2" x="$3"; shift 3; mkdir -p "$d"; printf '%s\n' "# $x plan" "" "$@" > "$d/$s-$x.md"; }

P1="$TMPROOT/p-m1"
plan "$P1" sidm1 intent "## Accepted Tradeoffs (intent)" "" "- M1_INTENT_MARK"
plan "$P1" sidm1 outline "## Issues" "" "- #1" "" "## Accepted Tradeoffs (outline)" "" "- M1_OUTLINE_MARK"
plan "$P1" sidm1 detail "## Accepted Tradeoffs (detail)" "" "- M1_DETAIL_MARK"

case_begin "merge-three-staged-files" "bin/resolve-accepted-tradeoffs-file"
resolve "$P1" sidm1 detail outline intent
check "M1: exit 0, single stdout line naming the merged control file" \
  test "$RC|$LINES|$OUT" = "0|1|$(want_path sidm1 detail)"
check "M1: each staged heading appears exactly once" \
  test "$(h2_count "$OUT" 'Accepted Tradeoffs (intent)')$(h2_count "$OUT" 'Accepted Tradeoffs (outline)')$(h2_count "$OUT" 'Accepted Tradeoffs (detail)')" = "111"
check "M1: the intent stage keeps its body" body_has "$OUT" "Accepted Tradeoffs (intent)" M1_INTENT_MARK
check "M1: the outline stage keeps its body" body_has "$OUT" "Accepted Tradeoffs (outline)" M1_OUTLINE_MARK
check "M1: the detail stage keeps its body" body_has "$OUT" "Accepted Tradeoffs (detail)" M1_DETAIL_MARK
check "M1: no legacy heading and no non-tradeoff section in the merged file" \
  test "$(h2_count "$OUT" 'Accepted Tradeoffs')$(h2_count "$OUT" 'Issues')" = "00"
case_end

case_begin "legacy-intent-transition" "bin/resolve-accepted-tradeoffs-file"
P="$TMPROOT/p-m2"
plan "$P" sidm2 intent "## Accepted Tradeoffs" "" "- M2_LEGACY_INTENT_MARK"
plan "$P" sidm2 outline "## Accepted Tradeoffs (outline)" "" "- M2_OUTLINE_MARK"
resolve "$P" sidm2 outline intent
check "M2: exit 0 and the outline-chain merged path" test "$RC|$OUT" = "0|$(want_path sidm2 outline)"
check "M2: the legacy intent body becomes the '(intent)' stage" body_has "$OUT" "Accepted Tradeoffs (intent)" M2_LEGACY_INTENT_MARK
check "M2: the outline stage is kept" body_has "$OUT" "Accepted Tradeoffs (outline)" M2_OUTLINE_MARK
case_end

case_begin "intent-staged-heading-wins-over-legacy" "bin/resolve-accepted-tradeoffs-file"
P="$TMPROOT/p-m2b"
plan "$P" sidm2b intent "## Accepted Tradeoffs" "" "- M2B_LEGACY_MARK" "" "## Accepted Tradeoffs (intent)" "" "- M2B_STAGED_MARK"
resolve "$P" sidm2b intent
check "M2b: exit 0 and the intent-chain merged path" test "$RC|$OUT" = "0|$(want_path sidm2b intent)"
check "M2b: the '(intent)' section is the intent stage" body_has "$OUT" "Accepted Tradeoffs (intent)" M2B_STAGED_MARK
check "M2b: the legacy section of the same file is not merged" lacks "$OUT" "M2B_LEGACY_MARK"
check "M2b: one '(intent)' heading, no legacy heading" test "$(h2_count "$OUT" 'Accepted Tradeoffs (intent)')$(h2_count "$OUT" 'Accepted Tradeoffs')" = "10"
case_end

case_begin "legacy-copy-in-downstream-ignored" "bin/resolve-accepted-tradeoffs-file"
P="$TMPROOT/p-m3"
plan "$P" sidm3 intent "## Accepted Tradeoffs (intent)" "" "- M3_INTENT_MARK"
plan "$P" sidm3 outline "## Accepted Tradeoffs" "" "- M3_OUTLINE_COPY_MARK" "" "## Accepted Tradeoffs (outline)" "" "- M3_OUTLINE_MARK"
plan "$P" sidm3 detail "## Accepted Tradeoffs" "" "- M3_DETAIL_COPY_MARK" "" "## Accepted Tradeoffs (detail)" "" "なし"
resolve "$P" sidm3 detail outline intent
check "M3: exit 0 and a merged file" test "$RC|$OUT" = "0|$(want_path sidm3 detail)"
check "M3: the legacy copies in outline/detail are not read" lacks "$OUT" "M3_(OUTLINE|DETAIL)_COPY_MARK"
check "M3: the intent stage comes from the intent file" body_has "$OUT" "Accepted Tradeoffs (intent)" M3_INTENT_MARK
check "M3: a 'なし' detail stage is carried as written" body_has "$OUT" "Accepted Tradeoffs (detail)" "なし"
case_end

case_begin "staged-copy-in-downstream-ignored" "bin/resolve-accepted-tradeoffs-file"
P="$TMPROOT/p-m3b"
plan "$P" sidm3b intent "## Accepted Tradeoffs (intent)" "" "- M3B_INTENT_MARK"
plan "$P" sidm3b outline "## Accepted Tradeoffs (intent)" "" "- M3B_INTENT_COPY_IN_OUTLINE" "" "## Accepted Tradeoffs (outline)" "" "- M3B_OUTLINE_MARK"
plan "$P" sidm3b detail "## Accepted Tradeoffs (outline)" "" "- M3B_OUTLINE_COPY_IN_DETAIL" "" "## Accepted Tradeoffs (detail)" "" "- M3B_DETAIL_MARK"
resolve "$P" sidm3b detail outline intent
check "M3b: exit 0 and a merged file" test "$RC|$OUT" = "0|$(want_path sidm3b detail)"
check "M3b: an upstream-stage heading copied downstream is not read" lacks "$OUT" "M3B_(INTENT_COPY_IN_OUTLINE|OUTLINE_COPY_IN_DETAIL)"
check "M3b: each stage comes from its own file" test "$(body_has "$OUT" "Accepted Tradeoffs (intent)" M3B_INTENT_MARK && body_has "$OUT" "Accepted Tradeoffs (outline)" M3B_OUTLINE_MARK && body_has "$OUT" "Accepted Tradeoffs (detail)" M3B_DETAIL_MARK && printf ok)" = "ok"
P="$TMPROOT/p-m3c"
plan "$P" sidm3c outline "## Accepted Tradeoffs (intent)" "" "- M3C_INTENT_COPY_IN_OUTLINE" "" "## Accepted Tradeoffs (outline)" "" "- M3C_OUTLINE_MARK"
resolve "$P" sidm3c outline intent
check "M3c: with intent absent, a staged '(intent)' copy in outline is not rescued either" lacks "$OUT" "M3C_INTENT_COPY_IN_OUTLINE"
check "M3c: the outline stage still merges" body_has "$OUT" "Accepted Tradeoffs (outline)" M3C_OUTLINE_MARK
case_end

case_begin "rescue-legacy-when-intent-absent" "bin/resolve-accepted-tradeoffs-file"
P="$TMPROOT/p-m4"
plan "$P" sidm4 outline "## Accepted Tradeoffs" "" "- M4_RESCUE_MARK" "" "## Accepted Tradeoffs (outline)" "" "- M4_OUTLINE_MARK"
plan "$P" sidm4 detail "## Accepted Tradeoffs" "" "- M4_DETAIL_COPY_MARK" "" "## Accepted Tradeoffs (detail)" "" "- M4_DETAIL_MARK"
resolve "$P" sidm4 detail outline intent
check "M4: exit 0 and a merged file" test "$RC|$OUT" = "0|$(want_path sidm4 detail)"
check "M4: outline's legacy heading is rescued as the '(intent)' stage" body_has "$OUT" "Accepted Tradeoffs (intent)" M4_RESCUE_MARK
check "M4: only the most upstream file is rescued, not detail's copy" lacks "$OUT" "M4_DETAIL_COPY_MARK"
check "M4: the staged outline section still merges" body_has "$OUT" "Accepted Tradeoffs (outline)" M4_OUTLINE_MARK
check "M4: the staged detail section still merges" body_has "$OUT" "Accepted Tradeoffs (detail)" M4_DETAIL_MARK
case_end

case_begin "no-rescue-when-intent-read-but-sectionless" "bin/resolve-accepted-tradeoffs-file"
P="$TMPROOT/p-m4b"
plan "$P" sidm4b intent "## Issues" "" "- #1"
plan "$P" sidm4b outline "## Accepted Tradeoffs" "" "- M4B_STALE_COPY" "" "## Accepted Tradeoffs (outline)" "" "- M4B_OUTLINE_MARK"
resolve "$P" sidm4b outline intent
check "M4b: exit 0 and the outline-chain merged path" test "$RC|$OUT" = "0|$(want_path sidm4b outline)"
check "M4b: a readable but sectionless intent blocks the rescue of outline's legacy copy" lacks "$OUT" "M4B_STALE_COPY"
check "M4b: no '(intent)' stage heading is synthesized" test "$(h2_count "$OUT" 'Accepted Tradeoffs (intent)')" = "0"
check "M4b: the outline stage still merges" body_has "$OUT" "Accepted Tradeoffs (outline)" M4B_OUTLINE_MARK
case_end

case_begin "all-stages-empty-bodyless-file" "bin/resolve-accepted-tradeoffs-file"
P="$TMPROOT/p-m5"
plan "$P" sidm5 intent "## Issues" "" "- M5_ISSUE_MARK"
plan "$P" sidm5 outline "## Delivery plan" "" "- step"
resolve "$P" sidm5 outline intent
check "M5: exit 0 and the merged path" test "$RC|$OUT" = "0|$(want_path sidm5 outline)"
check "M5: the merged file exists" test -f "$OUT"
check "M5: the merged file carries no tradeoff section and no other content" lacks "$OUT" "^## Accepted Tradeoffs|M5_ISSUE_MARK"
case_end

case_begin "containment-violation-exit-3" "bin/resolve-accepted-tradeoffs-file"
P="$TMPROOT/p-m6"
mkdir -p "$P"
printf '%s\n' "## Accepted Tradeoffs" "" "- M6_OUTSIDE_SECRET" > "$TMPROOT/sidm6-escape.md"
resolve "$P" sidm6 "../escape"
check "M6: an escaping lone candidate → exit 3, empty stdout" test "$RC|$OUT" = "3|"
check "M6: no state file carries the outside content" bash -c '! grep -rqF M6_OUTSIDE_SECRET "$0" 2>/dev/null' "$WORKFLOW_STATE_DIR"
case_end

case_begin "one-merged-file-per-chain" "bin/resolve-accepted-tradeoffs-file"
resolve "$P1" sidm1 outline intent
OUT_OUTLINE="$OUT"
resolve "$P1" sidm1 intent
OUT_INTENT="$OUT"
check "M7: the outline and intent chains name their own merged files" \
  test "$OUT_INTENT|$OUT_OUTLINE" = "$(want_path sidm1 intent)|$(want_path sidm1 outline)"
check "M7: the outline chain excludes the detail stage although detail.md exists" \
  test "$(h2_count "$OUT_OUTLINE" 'Accepted Tradeoffs (outline)')$(h2_count "$OUT_OUTLINE" 'Accepted Tradeoffs (detail)')" = "10"
check "M7: the intent chain holds the intent stage only" \
  test "$(h2_count "$OUT_INTENT" 'Accepted Tradeoffs (intent)')$(h2_count "$OUT_INTENT" 'Accepted Tradeoffs (outline)')" = "10"
check "M7: the detail chain's file survives the later chains" test -f "$(want_path sidm1 detail)"
case_end

# stage_counts <file> → "<legacy><intent><outline><detail>" heading counts.
stage_counts() {
  local f="$1"
  printf '%s%s%s%s' "$(h2_count "$f" 'Accepted Tradeoffs')" "$(h2_count "$f" 'Accepted Tradeoffs (intent)')" \
    "$(h2_count "$f" 'Accepted Tradeoffs (outline)')" "$(h2_count "$f" 'Accepted Tradeoffs (detail)')"
}

case_begin "rerun-over-existing-merged-file-is-idempotent" "bin/resolve-accepted-tradeoffs-file"
resolve "$P1" sidm1 detail outline intent
FIRST_COUNTS="$(stage_counts "$OUT")"
resolve "$P1" sidm1 detail outline intent
check "M9: the second run still exits 0 on the same merged path" test "$RC|$OUT" = "0|$(want_path sidm1 detail)"
check "M9: the second run does not grow any stage heading" test "$([ -f "$OUT" ] && printf f)$(stage_counts "$OUT")" = "f$FIRST_COUNTS"
check "M9: each staged heading appears at most once (no legacy heading)" test "$(stage_counts "$OUT")" = "0111"
check "M9: the detail body appears once" test "$(grep -cF M1_DETAIL_MARK "$OUT" 2>/dev/null || true)" = "1"
# Changed inputs: an existing merged file must be REBUILT, not returned as-is. Last user of P1.
plan "$P1" sidm1 detail "## Accepted Tradeoffs (detail)" "" "- M9_DETAIL_V2"
plan "$P1" sidm1 outline "## Issues" "" "- #1"
resolve "$P1" sidm1 detail outline intent
check "M9: the changed-input rerun exits 0 on the same merged path" test "$RC|$OUT" = "0|$(want_path sidm1 detail)"
check "M9: the rewritten detail body replaces the old one" body_has "$OUT" "Accepted Tradeoffs (detail)" M9_DETAIL_V2
check "M9: the old detail body is gone" lacks "$OUT" "M1_DETAIL_MARK"
check "M9: the deleted outline section is gone" test "$(h2_count "$OUT" 'Accepted Tradeoffs (outline)')" = "0"
M9_TMPS="$(find "$(dirname "$OUT")" -maxdepth 1 -name 'accepted-tradeoffs.detail.md.tmp.*' 2>/dev/null)"
check "M9: no temp file is left in the control dir" test -z "$M9_TMPS"
resolve "$TMPROOT/p-m5" sidm5 outline intent
resolve "$TMPROOT/p-m5" sidm5 outline intent
check "M9: the all-empty rerun keeps exit 0 and its merged file" test "$RC|$OUT|$([ -f "$OUT" ] && printf f)" = "0|$(want_path sidm5 outline)|f"
check "M9: an all-empty chain rerun still carries no '## Accepted Tradeoffs' heading" lacks "$OUT" "^## Accepted Tradeoffs"
case_end

case_begin "merged-output-path-is-a-directory" "bin/resolve-accepted-tradeoffs-file"
P="$TMPROOT/p-m10"
plan "$P" sidm10 intent "## Accepted Tradeoffs (intent)" "" "- M10_INTENT_MARK"
M10_DIR="$(want_path sidm10 intent)"
mkdir -p "$M10_DIR"
: > "$M10_DIR/keep"
RAW_ERR="$(run_with_timeout 90 bash "$RESOLVER" "$P" sidm10 intent 2>&1 >/dev/null)"
resolve "$P" sidm10 intent
check "M10: a readable candidate is forwarded as-is (exit 0), never the directory path" \
  test "$RC|$LINES|$OUT" = "0|1|$(np "$P/sidm10-intent.md")"
check "M10: the directory and its content survive" test -d "$M10_DIR" -a -f "$M10_DIR/keep"
check "M10: no temp file is left beside the directory" \
  test -z "$(find "$(dirname "$M10_DIR")" -maxdepth 1 -name 'accepted-tradeoffs.intent.md.tmp.*' 2>/dev/null)"
check "M10: the fallback run is silent on stderr" test -z "$RAW_ERR"
P="$TMPROOT/p-m10b"
mkdir -p "$P" "$(want_path sidm10b intent)"
RAW_ERR="$(run_with_timeout 90 bash "$RESOLVER" "$P" sidm10b intent 2>&1 >/dev/null)"
resolve "$P" sidm10b intent
check "M10b: no readable candidate and a directory at the merged path → exit 3, empty stdout" test "$RC|$OUT" = "3|"
check "M10b: the refusal names its reason on stderr" bash -c 'grep -q "resolve-accepted-tradeoffs-file: .*refusing" <<<"$0"' "$RAW_ERR"
check "M10b: the directory survives" test -d "$(want_path sidm10b intent)"
case_end

case_begin "staged-headings-come-from-plan-schema" "bin/resolve-accepted-tradeoffs-file"
PLAN_SCHEMA="$SCRIPT_CHECKOUT_ROOT/hooks/lib/plan-schema.js"
P="$TMPROOT/p-m11"
plan "$P" sidm11 intent "## Accepted Tradeoffs (intent)" "" "- M11_I"
plan "$P" sidm11 outline "## Accepted Tradeoffs (outline)" "" "- M11_O"
plan "$P" sidm11 detail "## Accepted Tradeoffs (detail)" "" "- M11_D"
resolve "$P" sidm11 detail outline intent
WANT_H=""
for stage in intent outline detail; do
  WANT_H+="## $(node "$PLAN_SCHEMA" --accepted-tradeoffs-heading "$stage" | tr -d '\r')"$'\n'
done
GOT_H="$(grep '^## ' "$OUT" 2>/dev/null | tr -d '\r')"$'\n'
check "M11-0: plan-schema answered one heading per stage (vacuity guard)" test "$(grep -c . <<<"$WANT_H")" = "3"
check "M11: the merged file's headings are exactly plan-schema's staged headings, in stage order" test "$GOT_H" = "$WANT_H"
# NEW BEHAVIOUR (#2924): the resolver takes each staged heading from plan-schema instead of building it.
check "M11: the resolver does not concatenate a '(\$stage)' heading itself" bash -c '! grep -qE "\(\\\$\{?stage\}?\)" "$0"' "$RESOLVER"
check "M11: the resolver asks plan-schema for each stage's heading" \
  grep -qE -- '--accepted-tradeoffs-heading[[:space:]]+"?\$\{?stage' "$RESOLVER"
case_end

MOCK_BIN="$TMPROOT/mock-bin"
mkdir -p "$MOCK_BIN"
CAP="$TMPROOT/prompt.txt"
printf '%s\n' '#!/usr/bin/env bash' "cat > \"$CAP\"" 'echo APPROVED' 'echo fine' > "$MOCK_BIN/codex"
chmod +x "$MOCK_BIN/codex"
MOCK_BIN_P="$MOCK_BIN"
if command -v cygpath >/dev/null 2>&1; then MOCK_BIN_P="$(cygpath -u "$MOCK_BIN")"; fi
MERGED="$TMPROOT/merged.md"
printf '%s\n' "## Accepted Tradeoffs (intent)" "" "- M8_INTENT_MARK" "" "## Accepted Tradeoffs (outline)" "" "- M8_OUTLINE_MARK" \
  "" "## Accepted Tradeoffs (detail)" "" "- M8_DETAIL_MARK" "" "## Steps" "" "- M8_NOT_SETTLED" > "$MERGED"
printf '%s\n' "# tests/x.sh" "" 'assert_eq a b c' > "$TMPROOT/input.md"
printf '%s\n' "## Test Case Categories" "" "- Normal cases" > "$TMPROOT/context.md"
in_block() { awk -v m="$1" '/^\[ACCEPTED TRADEOFFS START\]$/{f=1;next} /^\[ACCEPTED TRADEOFFS END\]$/{f=0} f && index($0,m){hit=1} END{exit !hit}' "$CAP" 2>/dev/null; }

case_begin "settled-block-carries-every-stage" "bin/lib/review-plan-codex/inputs.sh"
( export PATH="$MOCK_BIN_P:$PATH"
  run_with_timeout 90 bash "$REVIEW_PLAN_CODEX" --input "$TMPROOT/input.md" --format detail-plan \
    --accepted-tradeoffs "$MERGED" --context "$TMPROOT/context.md" --no-log >/dev/null 2>&1 )
check "M8-0: the mock codex captured a prompt" test -s "$CAP"
check "M8: the '(intent)' section lands inside the settled-decisions block" in_block M8_INTENT_MARK
check "M8: the '(outline)' section lands inside the settled-decisions block" in_block M8_OUTLINE_MARK
check "M8: the '(detail)' section lands inside the settled-decisions block" in_block M8_DETAIL_MARK
check "M8: a non-tradeoff section is not promoted" lacks "$CAP" "M8_NOT_SETTLED"
case_end

echo ""
echo "Results: $PASS/$((PASS + FAIL)) passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
