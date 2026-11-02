#!/usr/bin/env bash
# tests/bin/feature-2814-review-criteria-wiring.sh
# Tests: bin/review-plan-codex, bin/review-code-codex, bin/lib/review-plan-codex/prompts.sh, bin/lib/codex-core.sh, bin/lib/codex-review-criteria.sh
# Tags: TL2, codex, review, review-criteria, severity, prompt, fail-closed, issue-2814, scope:issue-specific, pwsh-not-required
# #2814 reopen T1 / R1-6: every codex review prompt (4 plan formats x round 1/2, and the code
# diff review) carries the [REVIEW CRITERIA] and [SEVERITY DEFINITION] blocks; the code review
# no longer asks for "the safest and simplest" approach; without --project-root the blocks stay
# and only the NFR frame drops; the code preamble's language line follows the plan preamble's;
# a copied tree without the criteria or severity file reports FAILED and never calls codex.
# TL3 gap (what this test does NOT catch):
# - a live codex applying the criteria; the mock codex records the prompt only.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
WR_ROOT="$(make_tmp)"
readonly WR_ROOT
trap 'cd / 2>/dev/null; rm -rf "$WR_ROOT"' EXIT
harness_isolate "$WR_ROOT/iso"
unset CLAUDE_CODE_SESSION_ID PROJECT_NFR CODEX_REVIEW_MAX_DIFF_LINES PLAN_LANG CONV_LANG
cd "$WR_ROOT" || exit 1

REAL="$SCRIPT_CHECKOUT_ROOT"
FORMATS="detail-plan outline-plan security-plan test-review"
ck() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=$(printf '%q' "$2") got=$(printf '%q' "${3:0:300}")"; fi; }
yn() { if "$@"; then printf yes; else printf no; fi; }
called() { if [ -s "$1" ]; then printf called; else printf no-call; fi; }
has_line() { if grep -q -x -F -- "$2" "$1" 2>/dev/null; then printf yes; else printf no; fi; }
has_text() { if grep -q -F -- "$2" "$1" 2>/dev/null; then printf yes; else printf no; fi; }

MOCK_BIN="$WR_ROOT/mock-bin"
mkdir -p "$MOCK_BIN"
printf '%s\n' '#!/usr/bin/env bash' 'cat > "${CODEX_MOCK_PROMPT:?}"' "printf 'APPROVED\\nlooks fine\\n'" 'exit 0' > "$MOCK_BIN/codex"
chmod +x "$MOCK_BIN/codex"

# The global .env the NFR lookup falls back to: pinned empty, never the ambient one.
CFG="$WR_ROOT/cfg"
mkdir -p "$CFG"
: > "$CFG/.env"
PROJ="$WR_ROOT/proj"
mkdir -p "$PROJ/.git"

PLAN_FILE="$WR_ROOT/plan.md"
printf '# Plan\n\n## Steps\n1. Change the loop.\n' > "$PLAN_FILE"
CTX_FILE="$WR_ROOT/codex-context.md"
printf '<!-- codex-context-section: intent source=/fixture/intent.md -->\n## intent\nThe loop stops before the planner is re-delegated.\n' > "$CTX_FILE"
TD_FILE="$WR_ROOT/test-design.md"
printf '## Test Case Categories\n- Every parser change needs a table-driven test.\n' > "$TD_FILE"
LEDGER_R2="$WR_ROOT/ledger-r2.txt"
printf 'C1|HIGH|the plan drops the retry path\n' > "$LEDGER_R2"

# A global .env declaring an NFR: with a root the NFR frame appears, without one it must not.
CFG_NFR="$WR_ROOT/cfg-nfr"
mkdir -p "$CFG_NFR"
printf 'PROJECT_NFR=WIRING-NFR-SENTINEL must hold\n' > "$CFG_NFR/.env"

RUN_RC=0
RUN_OUT=""
# run_plan <script> <format> <round> <capture> [cfg] [root, "-" = no --project-root]
run_plan() {
  local script="$1" fmt="$2" round="$3" cap="$4" cfg="${5:-$CFG}" root="${6:-$PROJ}"
  local extra=()
  [ "$round" -ge 2 ] && extra=(--ledger "$LEDGER_R2")
  [ "$root" = "-" ] || extra+=(--project-root "$root")
  rm -f "$cap"
  RUN_RC=0
  RUN_OUT="$(AGENTS_MAIN_ROOT="$cfg" PATH="$MOCK_BIN:$PATH" HOME="$WR_ROOT" CODEX_MOCK_PROMPT="$cap" \
    run_with_timeout 90 bash "$script" --input "$PLAN_FILE" --format "$fmt" --round "$round" \
    --context "$CTX_FILE" --context "$TD_FILE" --no-log "${extra[@]}" 2>&1)" || RUN_RC=$?
}

# A repo with one committed change on a feature branch (the feature-2223 git fixture).
REPO="$WR_ROOT/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config core.hooksPath /dev/null
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"
git -C "$REPO" config commit.gpgsign false
printf 'init\n' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m initial
git -C "$REPO" checkout -q -b feature
printf 'changed line for review\n' >> "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m change

# run_code <script> <capture> [root, "-" = no --project-root] — review-code-codex on $REPO.
run_code() {
  local root_args=(--project-root "${3:-$REPO}")
  [ "${3:-}" = "-" ] && root_args=()
  rm -f "$2"
  RUN_RC=0
  RUN_OUT="$(cd "$REPO" && AGENTS_MAIN_ROOT="$CFG" PATH="$MOCK_BIN:$PATH" HOME="$WR_ROOT" CODEX_MOCK_PROMPT="$2" \
    run_with_timeout 90 bash "$1" --base main "${root_args[@]}" 2>&1)" || RUN_RC=$?
}

case_begin "plan-prompts-carry-criteria-and-severity" "bin/lib/review-plan-codex/prompts.sh"
for fmt in $FORMATS; do
  for round in 1 2; do
    cap="$WR_ROOT/prompt-$fmt-r$round.txt"
    run_plan "$REAL/bin/review-plan-codex" "$fmt" "$round" "$cap"
    ck "$fmt r$round: the script exits 0" "0" "$RUN_RC"
    ck "$fmt r$round: codex received a prompt (precondition)" "called" "$(called "$cap")"
    ck "$fmt r$round: [REVIEW CRITERIA START] is in the prompt" "yes" "$(has_line "$cap" '[REVIEW CRITERIA START]')"
    ck "$fmt r$round: [REVIEW CRITERIA END] is in the prompt" "yes" "$(has_line "$cap" '[REVIEW CRITERIA END]')"
    ck "$fmt r$round: [SEVERITY DEFINITION START] is in the prompt" "yes" "$(has_line "$cap" '[SEVERITY DEFINITION START]')"
    ck "$fmt r$round: [SEVERITY DEFINITION END] is in the prompt" "yes" "$(has_line "$cap" '[SEVERITY DEFINITION END]')"
    ck "$fmt r$round: the plan body still reaches codex" "yes" "$(has_text "$cap" 'Change the loop.')"
  done
done
case_end

CODE_CAP="$WR_ROOT/prompt-code.txt"
case_begin "code-prompt-carries-criteria-and-severity" "bin/review-code-codex"
run_code "$REAL/bin/review-code-codex" "$CODE_CAP"
ck "code: the script exits 0" "0" "$RUN_RC"
ck "code: codex received a prompt (precondition)" "called" "$(called "$CODE_CAP")"
ck "code: [REVIEW CRITERIA START] is in the prompt" "yes" "$(has_line "$CODE_CAP" '[REVIEW CRITERIA START]')"
ck "code: [SEVERITY DEFINITION START] is in the prompt" "yes" "$(has_line "$CODE_CAP" '[SEVERITY DEFINITION START]')"
rce="$(grep -n -m1 -x -F '[SEVERITY DEFINITION END]' "$CODE_CAP" 2>/dev/null | cut -d: -f1)"
dfs="$(grep -n -m1 -F '[DIFF START]' "$CODE_CAP" 2>/dev/null | cut -d: -f1)"
ck "code: the severity definition closes (precondition)" "yes" "$(yn [ "${rce:-0}" -gt 0 ])"
ck "code: the criteria blocks precede the diff" "yes" "$(yn [ "${rce:-0}" -lt "${dfs:-0}" ])"
ck "code: the diff still reaches codex" "yes" "$(has_text "$CODE_CAP" 'changed line for review')"
case_end

case_begin "code-prompt-no-safest-and-simplest" "bin/review-code-codex"
ck "code wording: the prompt is captured (precondition)" "called" "$(called "$CODE_CAP")"
ck "code wording: no 'safest and simplest' in the prompt" "no" "$(has_text "$CODE_CAP" 'safest and simplest')"
ck "code wording: no 'safest and simplest' in the script" "no" "$(has_text "$REAL/bin/review-code-codex" 'safest and simplest')"
ck "code wording: a justified choice is not a concern merely because an alternative exists" "yes" \
  "$(has_text "$CODE_CAP" 'a choice that can be justified is not a concern merely because an alternative exists')"
ck "code wording: the focus line asks for safe and simple enough" "yes" \
  "$(has_line "$CODE_CAP" '- Whether the chosen approach is safe and simple enough for the requirements and constraints')"
ck "code wording: the preamble names the REVIEW CRITERIA" "yes" \
  "$(has_text "$CODE_CAP" 'independent second opinion on it under the REVIEW CRITERIA below')"
case_end

case_begin "no-project-root-still-carries-criteria" "bin/lib/review-plan-codex/prompts.sh"
# Production reaches review-plan-codex without --project-root; criteria and severity must not
# ride on the root, while the NFR frame (root-scoped) stays out. The with-root run is the control.
for fmt in detail-plan test-review; do
  cap="$WR_ROOT/noroot-ctl-$fmt.txt"
  run_plan "$REAL/bin/review-plan-codex" "$fmt" 1 "$cap" "$CFG_NFR" "$PROJ"
  ck "with root $fmt: the global NFR reaches the prompt (control)" "0 yes" "$RUN_RC $(has_line "$cap" '[PROJECT NFR START]')"
  cap="$WR_ROOT/noroot-$fmt.txt"
  run_plan "$REAL/bin/review-plan-codex" "$fmt" 1 "$cap" "$CFG_NFR" -
  ck "no root $fmt: the script exits 0 and codex is called (precondition)" "0 called" "$RUN_RC $(called "$cap")"
  ck "no root $fmt: [REVIEW CRITERIA START] is in the prompt" "yes" "$(has_line "$cap" '[REVIEW CRITERIA START]')"
  ck "no root $fmt: [SEVERITY DEFINITION START] is in the prompt" "yes" "$(has_line "$cap" '[SEVERITY DEFINITION START]')"
  ck "no root $fmt: [PROJECT NFR START] is absent" "no" "$(has_line "$cap" '[PROJECT NFR START]')"
done
cap="$WR_ROOT/noroot-code.txt"
run_code "$REAL/bin/review-code-codex" "$cap" -
ck "no root code: the script exits 0 and codex is called (precondition)" "0 called" "$RUN_RC $(called "$cap")"
ck "no root code: [REVIEW CRITERIA START] is in the prompt" "yes" "$(has_line "$cap" '[REVIEW CRITERIA START]')"
ck "no root code: [SEVERITY DEFINITION START] is in the prompt" "yes" "$(has_line "$cap" '[SEVERITY DEFINITION START]')"
case_end

# pre <fn> <args>... — one codex-core preamble under a pinned language (PLAN_LANG / CONV_LANG).
pre() { ( export AGENTS_MAIN_ROOT="$CFG" PLAN_LANG=japanese CONV_LANG=japanese; . "$REAL/bin/lib/codex-core.sh" >/dev/null 2>&1 || exit 97; "$@" ) 2>/dev/null | tr -d '\r'; }
case_begin "code-preamble-lang-line-follows-plan-rule" "bin/lib/codex-core.sh"
for surf in plan conv none; do
  s="$surf"; [ "$surf" = none ] && s=""
  PP="$(pre codex_core_plan_review_preamble "implementation plan" plan $s)"
  CP="$(pre codex_core_code_review_preamble "code diff" $s)"
  want_n=2; [ "$surf" = none ] && want_n=1
  ck "lang $surf: the plan preamble has $want_n line(s) (precondition)" "$want_n" "$(printf '%s\n' "$PP" | grep -c .)"
  ck "lang $surf: the code preamble has the same line shape ($want_n line(s))" "$want_n" "$(printf '%s\n' "$CP" | grep -c .)"
  ck "lang $surf: the code preamble's language line equals the plan preamble's" \
    "$(printf '%s\n' "$PP" | sed -n 2p)" "$(printf '%s\n' "$CP" | sed -n 2p)"
done
PLAN_LANG_LINE="$(pre codex_core_plan_review_preamble "implementation plan" plan plan | sed -n 2p)"
export PLAN_LANG=japanese CONV_LANG=japanese
cap="$WR_ROOT/lang-code.txt"
run_code "$REAL/bin/review-code-codex" "$cap"
unset PLAN_LANG CONV_LANG
ck "lang code prompt: the plan language line follows the preamble line" "$PLAN_LANG_LINE" \
  "$(awk -v p='under the REVIEW CRITERIA below' 'f{print; exit} index($0, p){f=1}' "$cap" 2>/dev/null | tr -d '\r')"
case_end

# A copied tree without skills/_shared/review-criteria.md: both scripts must fail closed.
TREE="$WR_ROOT/tree"
mkdir -p "$TREE/skills" "$TREE/agents" "$TREE/hooks"
cp -r "$REAL/bin" "$TREE/bin"
cp -r "$REAL/skills/_shared" "$TREE/skills/_shared"
cp -r "$REAL/hooks/lib" "$TREE/hooks/lib"
rm -f "$TREE/skills/_shared/review-criteria.md"

# A second copy that keeps the criteria but lacks skills/_shared/severity.md.
TREE_SEV="$WR_ROOT/tree-sev"
mkdir -p "$TREE_SEV/skills" "$TREE_SEV/agents" "$TREE_SEV/hooks"
cp -r "$REAL/bin" "$TREE_SEV/bin"
cp -r "$REAL/skills/_shared" "$TREE_SEV/skills/_shared"
cp -r "$REAL/hooks/lib" "$TREE_SEV/hooks/lib"
rm -f "$TREE_SEV/skills/_shared/severity.md"

# fails_closed <label> <tree> — every plan format and the code review report FAILED, no codex call.
fails_closed() {
  local label="$1" tree="$2" fmt cap
  for fmt in $FORMATS; do
    cap="$WR_ROOT/$label-$fmt.txt"
    run_plan "$tree/bin/review-plan-codex" "$fmt" 1 "$cap"
    ck "$label $fmt: the run reports FAILED for the unavailable criteria" "1" \
      "$(printf '%s\n' "$RUN_OUT" | grep -c -E '^## Codex Review: FAILED .*review criteria unavailable')"
    ck "$label $fmt: codex is never called" "no-call" "$(called "$cap")"
  done
  cap="$WR_ROOT/$label-code.txt"
  run_code "$tree/bin/review-code-codex" "$cap"
  ck "$label code: the run reports FAILED for the unavailable criteria" "1" \
    "$(printf '%s\n' "$RUN_OUT" | grep -c -E '^## Codex Review: FAILED .*review criteria unavailable')"
  ck "$label code: codex is never called" "no-call" "$(called "$cap")"
}

case_begin "missing-criteria-fails-closed" "bin/lib/codex-review-criteria.sh"
ck "tree: the criteria file is absent (precondition)" "absent" "$([ -e "$TREE/skills/_shared/review-criteria.md" ] && printf present || printf absent)"
fails_closed tree "$TREE"
case_end

case_begin "missing-severity-fails-closed" "bin/lib/codex-review-criteria.sh"
ck "tree-sev: the criteria file is present and severity.md absent (precondition)" "present absent" \
  "$([ -s "$TREE_SEV/skills/_shared/review-criteria.md" ] && printf present || printf absent) $([ -e "$TREE_SEV/skills/_shared/severity.md" ] && printf present || printf absent)"
fails_closed tree-sev "$TREE_SEV"
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
