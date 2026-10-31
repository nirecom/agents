#!/usr/bin/env bash
# tests/bin/feature-2814-plan-hierarchy-prompts.sh
# Tests: bin/review-plan-codex, bin/lib/codex-core.sh,bin/lib/review-plan-codex/hierarchy.sh, bin/lib/review-plan-codex/prompts.sh, bin/lib/review-plan-codex/prompts-review-only.sh, skills/_shared/priority-hierarchy/core.md, agents/detail-reviewer/concern-identifiers.md, agents/outline-reviewer/concern-identifiers.md
# Tags: TL2, codex, review, planning, priority-hierarchy, fail-closed, prompt, issue-2814, scope:issue-specific, pwsh-not-required
# #2814 T1-T3: every plan-review prompt carries the plan step hierarchy (core.md inside
# [PLAN STEP HIERARCHY START]/[... END], the reviewed artifact, the context nonce) before the
# context; no wording invites brainstorming; round 2+ only confirms fixes. A copied tree
# without core.md, or without the format's row in its table, reports FAILED with no codex call.
# TL3 gap: a live codex obeying the hierarchy is not observed; the mock records the prompt only.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
PH_ROOT="$(make_tmp)"
readonly PH_ROOT
trap 'cd / 2>/dev/null; rm -rf "$PH_ROOT"' EXIT
harness_isolate "$PH_ROOT/iso"
unset CLAUDE_CODE_SESSION_ID
cd "$PH_ROOT" || exit 1

SCRIPT="$SCRIPT_CHECKOUT_ROOT/bin/review-plan-codex"
FORMATS="detail-plan outline-plan security-plan test-review"
DEVIATIONS="deviation-add deviation-relax deviation-remove deviation-reinterpret"

# ck <name> <want> <got> — name-first equality reporter.
ck() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=$(printf '%q' "$2") got=$(printf '%q' "$3")"; fi; }

MOCK_BIN="$PH_ROOT/mock-bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/codex" <<'MOCK'
#!/usr/bin/env bash
cat > "${CODEX_MOCK_PROMPT:?}"
printf 'APPROVED\nlooks fine\n'
exit 0
MOCK
chmod +x "$MOCK_BIN/codex"

PLAN_FILE="$PH_ROOT/plan.md"
printf '# Plan\n\n## Steps\n1. Change the loop.\n' > "$PLAN_FILE"
CTX_FILE="$PH_ROOT/codex-context.md"
cat > "$CTX_FILE" <<'CTX'
<!-- codex-context-section: intent source=/fixture/intent.md -->
## intent
The loop stops before the planner is re-delegated.
<!-- codex-context-section: outline source=/fixture/outline.md -->
## outline
The outline keeps the ledger format unchanged.
CTX
TD_FILE="$PH_ROOT/test-design.md"
printf '## Test Case Categories\n- Every parser change needs a table-driven test.\n' > "$TD_FILE"
LEDGER_R2="$PH_ROOT/ledger-r2.txt"
printf 'C1|HIGH|the plan drops the retry path\n' > "$LEDGER_R2"

RUN_RC=0
RUN_OUT=""
# run_plan <script> <format> <capture> [extra args...] — the script against the mock.
run_plan() {
  local script="$1" fmt="$2" cap="$3"; shift 3
  rm -f "$cap"
  RUN_RC=0
  RUN_OUT="$(PATH="$MOCK_BIN:$PATH" HOME="$PH_ROOT" CODEX_MOCK_PROMPT="$cap" \
    run_with_timeout 90 bash "$script" --input "$PLAN_FILE" --format "$fmt" \
    --context "$CTX_FILE" --context "$TD_FILE" --no-log "$@" 2>&1)" || RUN_RC=$?
}
header_of() { printf '%s\n' "$RUN_OUT" | grep -m1 -oE '^## Codex Review: (PERFORMED|FAILED|SKIPPED)' || printf 'none'; }
called() { if [ -s "$1" ]; then printf called; else printf no-call; fi; }
# first_line <file> <ERE> — the first line number matching, or 0.
first_line() { local n; n="$(grep -n -m1 -E -- "$2" "$1" 2>/dev/null | cut -d: -f1)"; printf '%s' "${n:-0}"; }
# count_ci <file> <phrase> — case-insensitive line count. -i with -F aborts in Git-for-Windows
# grep, so the phrase goes through awk tolower/index instead.
count_ci() { awk -v p="$2" 'BEGIN{p=tolower(p);n=0} index(tolower($0),p){n++} END{print n}' "$1" 2>/dev/null || printf 'unreadable'; }
field_of() { grep -m1 -E -- "^$2: " "$1" 2>/dev/null | sed -E "s/^$2: //" | tr -d '\r'; }

artifact_of() {
  case "$1" in
    detail-plan|security-plan) printf 'detail' ;;
    outline-plan) printf 'outline' ;;
    test-review) printf 'test files' ;;
  esac
}

# assert_round1 <format> — T1 + T2 on the round 1 prompt.
assert_round1() {
  local fmt="$1" cap="$PH_ROOT/prompt-$1-r1.txt" s e c dev phrase
  run_plan "$SCRIPT" "$fmt" "$cap"
  ck "$fmt r1: the script exits 0" "0" "$RUN_RC"
  ck "$fmt r1: the run is PERFORMED (precondition)" "## Codex Review: PERFORMED" "$(header_of)"
  ck "$fmt r1: codex received a prompt" "called" "$(called "$cap")"
  s="$(first_line "$cap" '^\[PLAN STEP HIERARCHY START\]$')"
  e="$(first_line "$cap" '^\[PLAN STEP HIERARCHY END\]$')"
  c="$(first_line "$cap" '^\[CONTEXT SECTION START nonce=')"
  ck "$fmt r1: the hierarchy block opens" "yes" "$([ "$s" -gt 0 ] && printf yes || printf no)"
  ck "$fmt r1: the hierarchy block closes after it opens" "yes" "$([ "$e" -gt "$s" ] && printf yes || printf no)"
  ck "$fmt r1: the hierarchy block precedes the first context section" "yes" \
    "$([ "$e" -gt 0 ] && [ "$c" -gt "$e" ] && printf yes || printf "no(end=$e ctx=$c)")"
  ck "$fmt r1: the hierarchy block precedes the plan" "yes" \
    "$([ "$e" -gt 0 ] && [ "$(first_line "$cap" '^\[PLAN START\]$')" -gt "$e" ] && printf yes || printf no)"
  for dev in $DEVIATIONS; do
    ck "$fmt r1: the hierarchy block names $dev" "yes" \
      "$([ "$e" -gt "$s" ] && sed -n "${s},${e}p" "$cap" | grep -qF -- "$dev" && printf yes || printf no)"
  done
  ck "$fmt r1: Reviewed artifact names the format's artifact" "$(artifact_of "$fmt")" "$(field_of "$cap" 'Reviewed artifact')"
  ck "$fmt r1: the nonce is 32 lowercase hex digits" "yes" \
    "$(field_of "$cap" 'Context section nonce' | grep -qxE '[0-9a-f]{32}' && printf yes || printf no)"
  ck "$fmt r1: Upstream sections present is stated" "yes" \
    "$(grep -qE '^Upstream sections present: .+' "$cap" && printf yes || printf no)"
  if [ "$fmt" = "test-review" ]; then
    ck "$fmt r1: test files are not a plan step" "none" "$(field_of "$cap" 'Plan step under review')"
  else
    ck "$fmt r1: the plan step under review is stated and is not none" "yes" \
      "$(v="$(field_of "$cap" 'Plan step under review')"; [ -n "$v" ] && [ "$v" != "none" ] && printf yes || printf "no($v)")"
  fi
  # T2: no wording that invites brainstorming beyond the upstream plan steps.
  while IFS= read -r phrase; do
    [ -n "$phrase" ] || continue
    ck "$fmt r1: the prompt lacks '$phrase'" "0" "$(count_ci "$cap" "$phrase")"
  done <<'BANNED'
Look for:
unstated assumptions
approved high-level design
semi-trusted
blind spots
challenge design choices
BANNED
}

# assert_round2 <format> — T3: the round 2 prompt only confirms fixes.
assert_round2() {
  local fmt="$1" cap="$PH_ROOT/prompt-$1-r2.txt" fixl newl
  run_plan "$SCRIPT" "$fmt" "$cap" --round 2 --ledger "$LEDGER_R2"
  ck "$fmt r2: the run is PERFORMED (precondition)" "## Codex Review: PERFORMED" "$(header_of)"
  fixl="$(first_line "$cap" 'Only confirm whether each previous-round concern is fixed')"
  newl="$(first_line "$cap" 'DO NOT introduce new concerns')"
  ck "$fmt r2: the fix-confirmation sentence is present" "yes" "$([ "$fixl" -gt 0 ] && printf yes || printf no)"
  ck "$fmt r2: DO NOT introduce new concerns stays" "yes" "$([ "$newl" -gt 0 ] && printf yes || printf no)"
  ck "$fmt r2: the fix-confirmation comes before the no-new-concerns rule" "yes" \
    "$([ "$fixl" -gt 0 ] && [ "$newl" -ge "$fixl" ] && printf yes || printf no)"
  ck "$fmt r2: the hierarchy block is present in round 2 too" "1" "$(grep -c -x -F '[PLAN STEP HIERARCHY START]' "$cap" || true)"
}

case_begin "round1-hierarchy-detail-plan" "bin/review-plan-codex"
assert_round1 detail-plan
case_end

case_begin "round1-hierarchy-outline-plan" "bin/review-plan-codex"
assert_round1 outline-plan
case_end

case_begin "round1-hierarchy-security-plan" "bin/lib/review-plan-codex/prompts-review-only.sh"
assert_round1 security-plan
case_end

case_begin "round1-hierarchy-test-review" "bin/lib/review-plan-codex/prompts-review-only.sh"
assert_round1 test-review
case_end

case_begin "round2-confirm-only-four-formats" "bin/lib/review-plan-codex/prompts.sh"
for f in $FORMATS; do assert_round2 "$f"; done
case_end

TREE="$PH_ROOT/tree"
mkdir -p "$TREE/skills"
cp -r "$SCRIPT_CHECKOUT_ROOT/bin" "$TREE/bin"
cp -r "$SCRIPT_CHECKOUT_ROOT/skills/_shared" "$TREE/skills/_shared"
TREE_CORE="$TREE/skills/_shared/priority-hierarchy/core.md"

case_begin "core-md-missing-fails-closed" "skills/_shared/priority-hierarchy/core.md"
ck "fail-closed: the copied tree carries core.md (precondition)" "present" "$([ -f "$TREE_CORE" ] && printf present || printf absent)"
cap="$PH_ROOT/prompt-tree-ok.txt"
run_plan "$TREE/bin/review-plan-codex" detail-plan "$cap"
ck "fail-closed: the complete copied tree reviews normally (control)" "## Codex Review: PERFORMED called" "$(header_of) $(called "$cap")"
if [ -f "$TREE_CORE" ]; then mv "$TREE_CORE" "$TREE_CORE.hidden"; fi
for f in $FORMATS; do
  cap="$PH_ROOT/prompt-tree-nocore-$f.txt"
  run_plan "$TREE/bin/review-plan-codex" "$f" "$cap"
  ck "fail-closed: $f without core.md reports FAILED" "## Codex Review: FAILED" "$(header_of)"
  ck "fail-closed: $f without core.md never calls codex" "no-call" "$(called "$cap")"
done
if [ -f "$TREE_CORE.hidden" ]; then mv "$TREE_CORE.hidden" "$TREE_CORE"; fi
case_end

case_begin "format-row-missing-fails-closed" "bin/lib/review-plan-codex/hierarchy.sh"
if [ -f "$TREE_CORE" ]; then
  grep -v -E '^\|[[:space:]]*`?detail-plan`?[[:space:]]*\|' "$TREE_CORE" > "$TREE_CORE.new"
  mv "$TREE_CORE.new" "$TREE_CORE"
fi
ck "row-missing: the detail-plan row is gone (precondition)" "0" \
  "$(grep -c -E '^\|[[:space:]]*`?detail-plan`?[[:space:]]*\|' "$TREE_CORE" 2>/dev/null || true)"
ck "row-missing: the outline-plan row stays (precondition)" "1" \
  "$(grep -c -E '^\|[[:space:]]*`?outline-plan`?[[:space:]]*\|' "$TREE_CORE" 2>/dev/null || true)"
cap="$PH_ROOT/prompt-tree-norow-detail.txt"
run_plan "$TREE/bin/review-plan-codex" detail-plan "$cap"
ck "row-missing: detail-plan reports FAILED" "## Codex Review: FAILED" "$(header_of)"
ck "row-missing: detail-plan never calls codex" "no-call" "$(called "$cap")"
cap="$PH_ROOT/prompt-tree-norow-outline.txt"
run_plan "$TREE/bin/review-plan-codex" outline-plan "$cap"
ck "row-missing: outline-plan, whose row is present, still reviews" "## Codex Review: PERFORMED called" "$(header_of) $(called "$cap")"
case_end

case_begin "cc-reviewers-round2-confirm-only" "agents/detail-reviewer/concern-identifiers.md"
for f in agents/detail-reviewer/concern-identifiers.md agents/outline-reviewer/concern-identifiers.md agents/detail-reviewer.md agents/outline-reviewer.md; do
  ck "$f: Round 2+ is limited to confirming fixes" "yes" \
    "$(grep -i -E 'round 2' "$SCRIPT_CHECKOUT_ROOT/$f" | grep -qiE 'only (confirm|check)[^.]*(fixed|resolved)' && printf yes || printf no)"
  ck "$f: Round 2+ still forbids new concerns" "yes" \
    "$(grep -qiE 'no new concerns|not introduce new concerns|introducing a new concern is prohibited' "$SCRIPT_CHECKOUT_ROOT/$f" && printf yes || printf no)"
done
case_end

# T8 / detail 6-1: the plan-review preamble, called directly from codex-core.sh.
CORE_LIB="$SCRIPT_CHECKOUT_ROOT/bin/lib/codex-core.sh"
# preamble <function> <args...> — sets PRE_OUT (stdout, CR stripped) and PRE_RC (its exit).
PRE_RC=0; PRE_OUT=""
preamble() {
  PRE_RC=0
  PRE_OUT="$(run_with_timeout 30 bash -c '. "$1" >/dev/null 2>&1 || exit 97; shift; "$@"' _ "$CORE_LIB" "$@" 2>/dev/null)" || PRE_RC=$?
  PRE_OUT="${PRE_OUT//$'\r'/}"
}
has_ci() { printf '%s' "$1" | awk -v p="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" 'index(tolower($0), p){f=1} END{exit !f}'; }

case_begin "plan-review-preamble-wording" "bin/lib/codex-core.sh"
while IFS='|' read -r fmt reviewed; do
  [ -n "$fmt" ] || continue
  preamble codex_core_plan_review_preamble "$fmt review" "$reviewed"; P="$PRE_OUT"
  ck "preamble ($fmt): the function exists and exits 0" "0" "$PRE_RC"
  ck "preamble ($fmt): asks for an independent second opinion" "yes" "$([ -n "$P" ] && has_ci "$P" "second opinion" && printf yes || printf no)"
  ck "preamble ($fmt): names the reviewed artifact '$reviewed'" "yes" "$([ -n "$P" ] && has_ci "$P" "$reviewed" && printf yes || printf no)"
  ck "preamble ($fmt): treats upstream plan steps as decided" "yes" "$([ -n "$P" ] && has_ci "$P" "upstream" && printf yes || printf no)"
  ck "preamble ($fmt): objections are reported with the tag" "yes" "$([ -n "$P" ] && has_ci "$P" "[upstream-inconsistency" && printf yes || printf no)"
  ck "preamble ($fmt): no 'blind spots' invitation" "no" "$([ -z "$P" ] && printf empty || { has_ci "$P" "blind spots" && printf yes || printf no; })"
  ck "preamble ($fmt): no 'challenge' of design choices" "no" "$([ -z "$P" ] && printf empty || { has_ci "$P" "challenge" && printf yes || printf no; })"
done <<'TABLE'
detail-plan|detail
security-plan|detail
outline-plan|outline
test-review|test files
TABLE
case_end

case_begin "adversarial-preamble-unchanged" "bin/lib/codex-core.sh"
# Golden: the existing function's surface-less output is byte-identical to the pre-#2814 text.
WANT_ADV="The following code diff was authored by Claude (a different LLM, not by a human). Your job is to provide an independent, adversarial second opinion. Do not assume Claude's reasoning is correct. Actively look for blind spots and issues Claude may have missed. Be skeptical of design choices and challenge them."
preamble codex_core_adversarial_preamble "code diff"
ck "adversarial preamble: output unchanged" "$WANT_ADV" "$PRE_OUT"
ck "adversarial preamble: exits 0" "0" "$PRE_RC"
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
