#!/bin/bash
# tests/bin/TL3-review-criteria-codex.sh
# Tests: bin/review-plan-codex, skills/_shared/review-criteria.md
# Tags: review-criteria, codex, bin, tl3, threat-boundary, issue-2020, scope:common
# T9 (#2814): real codex judges three detail fixtures against one intent/outline pair.

# Skip gates — evaluated before set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v codex >/dev/null 2>&1 || exit 77
[ -x "$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" ] || exit 77
"$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" --is-off RUN_TL3 off && exit 77
[ -x "$SCRIPT_CHECKOUT_ROOT/bin/review-plan-codex" ] || exit 77

# TL3 gap:
# - The TL2 siblings (feature-2814-review-criteria-block.sh / -wiring.sh) pin the prompt bytes with
#   a mock codex; only this file checks that a real model applies the criteria.
# - Model output is non-deterministic: one run per fixture, no retry. A flaky verdict here is a
#   signal about the criteria wording, not a harness bug.
# - #2020 CC fallback reviewers (plan-security-reviewer, security-scanner) are not run live on
#   out-of-boundary-only input (A2/A3/A6); only the codex cases (e) and (f) are. Static coverage:
#   tests/agents/feature-2814-review-criteria-consumers.sh (both agents reference the Threat
#   boundary section and name the [NOT-CONCERN] marker form).

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
CODE_BIN="$SCRIPT_CHECKOUT_ROOT/bin/review-code-codex"

# Pinned config root: empty .env so no ambient PROJECT_NFR or codex knobs leak in.
CFG="$TMP_ROOT/cfg"
mkdir -p "$CFG"
: > "$CFG/.env"
PROJ="$TMP_ROOT/proj"
mkdir -p "$PROJ"

# review <fixture> <outfile> [format]: one real codex review of a detail fixture.
review() {
  local rc=0
  (cd "$TMP_ROOT" && AGENTS_MAIN_ROOT="$CFG" run_with_timeout 600 "$BIN" \
    --input "$FX/$1" --format "${3:-detail-plan}" --round 1 \
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

# untagged_numbered: the numbered concern lines of stdin that lack the axis:A?/B? cat:<category> prefix.
untagged_numbered() {
  grep -E '^[0-9]+\. \[(HIGH|MEDIUM|LOW)\]' | grep -vE '^[0-9]+\. \[(HIGH|MEDIUM|LOW)\] axis:A[0-6]/B[0-3] cat:[a-z]+ ' || true
}

# Offline self-check of untagged_numbered, so a broken filter cannot pass (e) and (f) vacuously.
case_begin "untagged-numbered-filter-self-check" "skills/_shared/review-criteria.md"
UNT_FX=$'1. [HIGH] axis:A5/B2 cat:security tagged line\n2. [MEDIUM] an eval of the issue title is reachable\n3. [LOW] cat:docs axis missing\n[NOT-CONCERN] axis:A2/B0 | bin/x#- | not numbered'
UNT_GOT="$(printf '%s\n' "$UNT_FX" | untagged_numbered)"
if [[ "$UNT_GOT" == $'2. [MEDIUM] an eval of the issue title is reachable\n3. [LOW] cat:docs axis missing' ]]; then
  pass "self-check: untagged_numbered keeps exactly the numbered lines missing a tag"
else
  fail "self-check: untagged_numbered returned $(printf '%q' "$UNT_GOT")"
fi
case_end

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

# #2020: the Threat boundary section reaches a real codex, so a security-plan review tags each
# numbered concern with the axis: and cat: prefixes and writes any marker line in the I4 form.
case_begin "security-plan-tags-axis-and-category" "skills/_shared/review-criteria.md"
OUT_D="$TMP_ROOT/d.txt"
rc=$(review detail-security-eval.md "$OUT_D" security-plan)
if performed "$OUT_D"; then
  pass "(d) codex review performed (rc=$rc)"
  NUM_D="$(body "$OUT_D" | grep -E '^[0-9]+\. \[(HIGH|MEDIUM|LOW)\]' || true)"
  TAGGED_D="$(printf '%s\n' "$NUM_D" | grep -cE '^[0-9]+\. \[(HIGH|MEDIUM|LOW)\] axis:A[0-6]/B[0-3] cat:[a-z]+ ' || true)"
  if [ -n "$NUM_D" ] && [ "$TAGGED_D" -eq "$(printf '%s\n' "$NUM_D" | grep -c .)" ]; then
    pass "(d) every numbered concern carries axis:A?/B? cat:<category>"
  else
    fail "(d) numbered concerns missing or untagged: $(printf '%s' "$NUM_D" | head -3)"
  fi
  if printf '%s\n' "$NUM_D" | grep -qE 'cat:security'; then
    pass "(d) the eval of the issue title is a security concern"
  else
    fail "(d) no cat:security concern for the eval of the issue title"
  fi
  BAD_MARK="$(body "$OUT_D" | grep -F '[NOT-CONCERN]' | grep -vcE '^\[NOT-CONCERN\] axis:A[0-6]/B[0-3] \| [^|]+#[^|]* \| .+' || true)"
  if [ "${BAD_MARK:-0}" -eq 0 ]; then
    pass "(d) every [NOT-CONCERN] line (if any) follows the I4 form"
  else
    fail "(d) $BAD_MARK [NOT-CONCERN] line(s) break the I4 form"
  fi
else
  fail "(d) codex review not performed: $(head -3 "$OUT_D")"
fi
case_end

# #2020 I4/I5: a plan whose only threats are direct external attackers (A2), user-mediated (A3)
# and a same-host human (A6) gets no security concern; those threats go to [NOT-CONCERN] markers.
case_begin "security-plan-out-of-boundary-only-not-concern" "skills/_shared/review-criteria.md"
OUT_E="$TMP_ROOT/e.txt"
rc=$(review detail-security-out-of-boundary.md "$OUT_E" security-plan)
if performed "$OUT_E"; then
  pass "(e) codex review performed (rc=$rc)"
  SEC_E="$(body "$OUT_E" | grep -E '^[0-9]+\. \[(HIGH|MEDIUM|LOW)\]' | grep -E 'cat:security' || true)"
  if [ -z "$SEC_E" ]; then
    pass "(e) no numbered concern is tagged cat:security"
  else
    fail "(e) out-of-boundary threats raised as security concerns: $(printf '%s' "$SEC_E" | head -3)"
  fi
  UNT_E="$(body "$OUT_E" | untagged_numbered)"
  if [[ -z "$UNT_E" ]]; then
    pass "(e) every numbered concern (if any) carries axis:A?/B? cat:<category>"
  else
    fail "(e) numbered concerns without the axis/cat tags: $(printf '%s' "$UNT_E" | head -3)"
  fi
  OOB_E="$(body "$OUT_E" | grep -cE '^\[NOT-CONCERN\] axis:A[236]/B[0-3] \| [^|]+#[^|]* \| .+' || true)"
  if [ "${OOB_E:-0}" -ge 1 ]; then
    pass "(e) the excluded threats are routed to [NOT-CONCERN] lines with axis A2/A3/A6"
  else
    fail "(e) no [NOT-CONCERN] axis:A2/A3/A6 line: $(body "$OUT_E" | head -8)"
  fi
  if body "$OUT_E" | grep -qE '^[0-9]+\. \[(HIGH|MEDIUM|LOW)\]'; then
    pass "(e) other-category concerns exist, so the verdict stays as is (I5 does not apply)"
  elif approved "$OUT_E"; then
    pass "(e) markers only: the verdict is APPROVED (I5)"
  else
    fail "(e) markers only but not APPROVED: $(body "$OUT_E" | head -3)"
  fi
else
  fail "(e) codex review not performed: $(head -3 "$OUT_E")"
fi
case_end

# #2020 I4 (code path): bin/review-code-codex carries the same criteria block, so a diff whose only
# threats are A2 (TLS-breaking network attacker), A3 (user pastes an untrusted command) and A6
# (another local OS user reads /tmp) gets no security delta row and no numbered cat:security
# concern; those threats go to [NOT-CONCERN] markers in the I4 form.
case_begin "code-review-out-of-boundary-only-not-concern" "skills/_shared/review-criteria.md"
CODE_REPO="$TMP_ROOT/code-repo"
mkdir -p "$CODE_REPO/bin"
git -C "$CODE_REPO" init -q
git -C "$CODE_REPO" config core.hooksPath /dev/null
git -C "$CODE_REPO" config user.email tl3@example.invalid
git -C "$CODE_REPO" config user.name tl3
git -C "$CODE_REPO" checkout -q -b main
printf 'review-loop fixture\n' > "$CODE_REPO/README.md"
git -C "$CODE_REPO" add README.md
git -C "$CODE_REPO" commit -q -m initial
git -C "$CODE_REPO" checkout -q -b feature
cat > "$CODE_REPO/bin/review-loop" <<'FIXTURE'
#!/usr/bin/env bash
# bin/review-loop: stop the review loop at round 3 and ask the user what to do next.
# Threats considered:
# - A network attacker on the path to api.github.com who breaks TLS and rewrites the response.
# - Another local OS user on the same host who reads /tmp/review-loop-round.txt.
# - The user who pastes a command copied from an untrusted web page at the choice prompt.
set -euo pipefail

ROUND_FILE="/tmp/review-loop-round.txt"
ROUND=0
if [[ -f "$ROUND_FILE" ]]; then
  ROUND="$(cat "$ROUND_FILE")"
fi
[[ "$ROUND" =~ ^[0-9]+$ ]] || ROUND=0
ROUND=$((ROUND + 1))
printf '%s\n' "$ROUND" > "$ROUND_FILE"

STATUS="$(curl -fsS https://api.github.com/repos/example/example/commits/main/status | jq -r '.state')"
printf '%s\n' "Reviewing round $ROUND (CI: $STATUS)"

if [[ "$ROUND" -ge 3 ]]; then
  printf '%s\n' "Round limit reached. Choose: continue, accept, abandon"
  read -r CHOICE
  case "$CHOICE" in
    continue) printf '0\n' > "$ROUND_FILE" ;;
    accept|abandon) rm -f "$ROUND_FILE" ;;
    *) printf '%s\n' "Unknown choice" >&2; exit 1 ;;
  esac
fi
exit 0
FIXTURE
git -C "$CODE_REPO" add bin/review-loop
git -C "$CODE_REPO" commit -q -m "add review-loop"
OUT_F="$TMP_ROOT/f.txt"
rc=0
(cd "$CODE_REPO" && AGENTS_MAIN_ROOT="$CFG" run_with_timeout 600 "$CODE_BIN" \
  --base main --project-root "$PROJ" --no-log) > "$OUT_F" 2>&1 || rc=$?
if performed "$OUT_F"; then
  pass "(f) codex code review performed (rc=$rc)"
  SEC_F="$(body "$OUT_F" | grep -E '^\[(HIGH|MEDIUM|LOW)\] [^|]+ \| [^|]+ \| *security *\|' || true)"
  if [ -z "$SEC_F" ]; then
    pass "(f) no Concern Delta row carries the security category"
  else
    fail "(f) out-of-boundary threats raised as security delta rows: $(printf '%s' "$SEC_F" | head -3)"
  fi
  NUM_SEC_F="$(body "$OUT_F" | grep -E '^[0-9]+\. \[(HIGH|MEDIUM|LOW)\]' | grep -E 'cat:security' || true)"
  if [ -z "$NUM_SEC_F" ]; then
    pass "(f) no numbered concern is tagged cat:security"
  else
    fail "(f) out-of-boundary threats raised as numbered security concerns: $(printf '%s' "$NUM_SEC_F" | head -3)"
  fi
  UNT_F="$(body "$OUT_F" | untagged_numbered)"
  if [[ -z "$UNT_F" ]]; then
    pass "(f) every numbered concern (if any) carries axis:A?/B? cat:<category>"
  else
    fail "(f) numbered concerns without the axis/cat tags: $(printf '%s' "$UNT_F" | head -3)"
  fi
  OOB_F="$(body "$OUT_F" | grep -cE '^\[NOT-CONCERN\] axis:A[236]/B[0-3] \| [^|]+#[^|]* \| .+' || true)"
  if [ "${OOB_F:-0}" -ge 1 ]; then
    pass "(f) the excluded threats are routed to [NOT-CONCERN] lines with axis A2/A3/A6"
  else
    fail "(f) no [NOT-CONCERN] axis:A2/A3/A6 line: $(body "$OUT_F" | head -8)"
  fi
else
  fail "(f) codex code review not performed: $(head -3 "$OUT_F")"
fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
