#!/usr/bin/env bash
# tests/fix-1689-run-tests-contract.sh
# Tests: skills/run-tests/SKILL.md, rules/test.md
# Tags: run-tests, prompt-contract, merge-base, ssot, recovery, static, scope:issue-specific, pwsh-not-required, TL2
#
# Issues #1638 / #1689 — the two halves of skills/run-tests/SKILL.md that are PROMPT rather than
# code, and therefore have no other test.
#
# WHY A PROMPT NEEDS A TEST AT ALL. Everything this skill does at runtime is done by an LLM
# reading these instructions. There is no function to call and no exit code to assert, so a
# sentence that goes missing in a later edit fails silently and permanently: the model simply
# does the old thing, or invents something. The two sentences at stake here are the ones whose
# absence caused the issues in the first place.
#
#   #1638 — RNT-1 CARRIED ITS OWN merge-base CHAIN. Five lines of prose reimplementing
#   `origin/main` → `main` → `HEAD~1`. That is a second implementation of a fact that now has an
#   owner (bin/resolve-merge-base.sh), and it is the copy that produced the 280k-line range: it
#   had no anomaly check, no recorded baseline and no way to stop. The rows below pin the
#   REPLACEMENT — one reference to the resolver — and, just as importantly, pin the REMOVAL: as
#   long as the old chain is still written here, a model reading the file can follow either one,
#   and CPR-2 is violated whatever the resolver does.
#
#   #1689 — RNT-9 HAD NO NON-COERCIVE RECOVERY. When the suite fails for a reason the diff did
#   not cause (a pre-existing failure on main), the only documented outcomes were `pending`
#   forever or reaching for a session-wide OFF sentinel — which suspends every guard in the
#   workflow to get past one step. So the rows pin the surgical alternative AND its price:
#   evidence, in the same turn, that the failure is unrelated. A recovery mechanism documented
#   without its evidence requirement is just permission to mark a failing suite complete.
#
# WHAT THESE ROWS DELIBERATELY DO NOT DO. They do not check wording. Every assertion is on a
# token that is load-bearing for the reader — a script name, a flag, a sentinel literal, an exit
# code — because those are what a model must reproduce exactly, and they survive rewording and
# translation. Prose-level regexes accept both English and Japanese for the same reason: the
# repository's prompts are English today, and a row that fails on a faithful translation would
# be testing the author's language rather than the contract.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$AGENTS_DIR/skills/run-tests/SKILL.md"
TEST_RULES="$AGENTS_DIR/rules/test.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$SKILL" ]; then
  echo "FAIL: precondition — $SKILL does not exist"
  echo ""
  echo "Total: 0 passed, 1 failed"
  exit 1
fi

# One RNT step's text: from its own `RNT-<n>.` line up to the next `RNT-` step or the next `##`
# heading. Scoping every assertion to a step is what makes the rows specific — a token found
# anywhere in a 60-line file proves nothing about where a model will read it.
rnt_section() { # <n> ; prints the section text
  awk -v n="$1" '
    $0 ~ "^RNT-" n "\\." { inside = 1; print; next }
    inside && ($0 ~ /^RNT-[0-9]+\./ || $0 ~ /^## /) { inside = 0 }
    inside { print }
  ' "$SKILL"
}

rules_section() { # prints the `## Rules` block
  awk '/^## Rules/ { inside = 1; next } inside && /^## / { inside = 0 } inside { print }' "$SKILL"
}

# `--` before the pattern: several patterns below start with a flag literal (`--explain`,
# `--format base`), which grep would otherwise parse as its own option.
expect_match() { # <row> <desc> <ere> <text>
  if printf '%s' "$4" | grep -qiE -- "$3"; then pass "$1: $2"; else fail "$1: $2 -- nothing matches /$3/"; fi
}

expect_no_match() { # <row> <desc> <ere> <text>
  if printf '%s' "$4" | grep -qiE -- "$3"; then fail "$1: $2 -- /$3/ is still present"; else pass "$1: $2"; fi
}

RNT1="$(rnt_section 1)"
RNT2="$(rnt_section 2)"
RNT3="$(rnt_section 3)"
RNT9="$(rnt_section 9)"
RULES="$(rules_section)"

# The sections have to be non-empty before anything is asserted about them: an awk range that
# matched nothing would make every expect_no_match row below pass for free.
for _pair in "RNT-1:$RNT1" "RNT-2:$RNT2" "RNT-3:$RNT3" "RNT-9:$RNT9" "Rules:$RULES"; do
  _name="${_pair%%:*}"
  _body="${_pair#*:}"
  if [ -n "$(printf '%s' "$_body" | tr -d '[:space:]')" ]; then
    pass "S0[$_name]: the section was located and is non-empty"
  else
    fail "S0[$_name]: the section is empty or missing, so no assertion about it means anything"
  fi
done

# ---- #1638: RNT-1 delegates, and no longer carries its own chain ------------

expect_match "S1" "RNT-1 delegates merge-base resolution to select-tests.sh --auto" \
  'select-tests\.sh[[:space:]]+--auto' "$RNT1"
expect_match "S2" "and names the resolver that owns the chain" \
  'resolve-merge-base\.sh' "$RNT1"

# The removal, item by item. Each of these is one line of the old chain, and any one of them
# left behind is a second source of truth a model may follow instead.
expect_no_match "S3a" "RNT-1 no longer reimplements the origin/main attempt" \
  'merge-base[[:space:]]+origin/main' "$RNT1"
expect_no_match "S3b" "nor the local main attempt" \
  'merge_base=\$\(git merge-base main HEAD\)' "$RNT1"
expect_no_match "S3c" "nor the HEAD~1 fallback" \
  'merge_base=HEAD~1' "$RNT1"
expect_no_match "S3d" "nor its own git fetch" \
  'git fetch origin main' "$RNT1"

# ---- #1638: exit 4 has a way out, and it survives the re-run ---------------

expect_match "S4" "RNT-1 documents the exit code that stops the run" \
  'exit[[:space:]]*4' "$RNT1"
expect_match "S5" "and presents the resolver's own explanation to the user" \
  '--explain' "$RNT1"
# The recovery is only real if the approved base is PERSISTED: re-running without recording it
# hits exit 4 again forever, which is the dead end the first draft had.
expect_match "S6" "the approved base is recorded through the approval CLI" \
  'record-merge-base-baseline' "$RNT1"
expect_match "S7" "and RNT-1 is re-run afterwards rather than skipped past" \
  're-?run|re-?execute|再実行|やり直' "$RNT1"
# Abort is a documented outcome too. Without it the only way out of a base the user does not
# trust is to approve one anyway.
expect_match "S8" "aborting is an option, and it leaves the step pending" \
  'pending' "$RNT1"

# RNT-2 must consume the same one-liner, with no variable left over from the deleted chain.
expect_match "S9" "RNT-2 calls select-tests.sh --auto" \
  'select-tests\.sh[[:space:]]+--auto' "$RNT2"
expect_no_match "S9b" "and no longer passes the deleted \$merge_base variable" \
  'select-tests\.sh[[:space:]]+"?\$\{?merge_base' "$RNT2"

# Tier 1 and Tier 2 must look at the SAME range. They are resolved by different commands, so
# without this line Tier 2 can re-resolve to a different base and silently review a different
# set of files than Tier 1 selected tests for.
expect_match "S10" "RNT-3 obtains its base from the resolver, so both tiers share one range" \
  '--format[[:space:]]+base' "$RNT3"

# The Rules section is where a model looks for the prohibition rather than the procedure.
expect_match "S11" "the Rules section names the resolver as the single source of truth" \
  'resolve-merge-base\.sh' "$RULES"

# ---- #1689: the surgical recovery, and its price ---------------------------

expect_match "S12" "RNT-9 still emits the completion sentinel on a pass" \
  '<<WORKFLOW_MARK_STEP_run_tests_complete>>' "$RNT9"
expect_match "S13" "and the pending sentinel on failure" \
  '<<WORKFLOW_MARK_STEP_run_tests_pending>>' "$RNT9"

# The recovery itself: a failure the diff did not cause.
expect_match "S14" "RNT-9 documents a recovery for failures unrelated to the diff" \
  'unrelated|pre-?existing|無関係|既存' "$RNT9"

# The evidence, item by item, because each one rules out a different wrong conclusion: the test
# name says WHAT failed, the paths say what it touches, the diff range says the change did not
# touch them, and main says the failure was already there.
expect_match "S15a" "the evidence includes which tests failed" \
  'failing[_ -]?tests?|test name|失敗テスト' "$RNT9"
expect_match "S15b" "the paths the failure touches" \
  'path|パス' "$RNT9"
expect_match "S15c" "that those paths are outside the resolved diff range" \
  'resolve-merge-base\.sh|--format[[:space:]]+base|diff' "$RNT9"
expect_match "S15d" "and that the same failure reproduces on main" \
  'main' "$RNT9"
# Evidence is worthless if it can be produced later, after the sentinel is already accepted.
expect_match "S16" "the evidence is required in the same turn as the sentinel" \
  'same turn|同一ターン|同じターン' "$RNT9"
# And the default when the evidence cannot be produced has to be spelled out, or the recovery
# reads as the ordinary way to get past a red suite.
expect_match "S17" "and without the evidence the step stays pending for the user to judge" \
  'pending' "$RNT9"

# The prohibition. This is the row that separates a surgical recovery from a workflow-wide
# escape hatch: WORKFLOW_ENFORCE_WORKFLOW_OFF suspends every guard for the whole session,
# including the outbound-content scan's neighbours, to get past one step.
expect_match "S18" "RNT-9 forbids the session-wide OFF sentinel for this purpose" \
  'WORKFLOW_ENFORCE_WORKFLOW_OFF|EMERGENCY[_ ]OFF' "$RNT9"
# Case-sensitive and specific: a bare case-insensitive `off` would be satisfied by any word
# containing it, so this row would start passing on an unrelated edit.
if printf '%s' "$RULES" | grep -qE 'WORKFLOW_ENFORCE_WORKFLOW_OFF|OFF sentinel|EMERGENCY[_ ]OFF'; then
  pass "S19: the Rules section repeats the prohibition where a model looks for rules"
else
  fail "S19: the Rules section does not name the OFF sentinel it is prohibiting"
fi
expect_match "S20" "and scopes the recovery to the run_tests step alone" \
  'run_tests' "$RULES"

# ---- shape: the file stays a prompt --------------------------------------

# rules/coding/file-split.md Pattern B: prompts WARN at 100 lines, HARD at 200. The additions
# above are prose, and a prompt that has to be split is a prompt a model reads less of.
SKILL_LINES="$(grep -c '' "$SKILL" || true)"
if [ "$SKILL_LINES" -le 200 ]; then
  pass "S21: SKILL.md is within the hard prompt-size limit ($SKILL_LINES lines, limit 200)"
else
  fail "S21: SKILL.md is $SKILL_LINES lines, past the 200-line hard split limit for prompts"
fi

# rules/prompt.md forbids code blocks of three or more lines in a prompt: a fenced block invites
# a model to execute it verbatim instead of reading the instruction around it.
FENCES="$(grep -c '^```' "$SKILL" || true)"
if [ "$FENCES" = "0" ]; then
  pass "S22: and carries no fenced code block — the sentinels stay inline literals"
else
  fail "S22: SKILL.md contains $FENCES fence line(s); the additions must be prose with inline literals"
fi

# ---- the risk-category SSOT description ------------------------------------

# rules/test.md names the current risk categories in prose while pointing at the classifier as
# the SSOT. A category added to the classifier and not reflected here leaves the prose listing
# stale, which is what a reader consults before the code.
if [ ! -f "$TEST_RULES" ]; then
  fail "S23: rules/test.md does not exist"
elif grep -qF "merge-base-suspect" "$TEST_RULES"; then
  pass "S23: rules/test.md lists the new merge-base-suspect risk category"
else
  fail "S23: rules/test.md does not mention merge-base-suspect, so its category listing is stale"
fi

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
