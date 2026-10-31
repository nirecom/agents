#!/usr/bin/env bash
# Tests: bin/workflow/lib/next-step/advance.js, bin/workflow/lib/next-step/advance-shared.js, hooks/workflow-state/record-step-verdict.js
# Tags: tl1, static, workflow, advance, no-prose, scope:issue-specific, tl2, advance-door, skip-owner-lock, recorded-verdict, error-cases, pwsh-not-required
#
# The forward operation must decide from RECORDED FACTS only: intent.md / outline.md
# are model-authored prose, and reading them would let a step settle because the
# plan text sounded convincing rather than because a condition was recorded — the
# same failure mode the skip gate itself was fixed to avoid. State files and config
# files are the only admissible inputs here.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$SCRIPT_CHECKOUT_ROOT" || exit 1

# Fixture for the behavioural advance-door cases at the end (#2460); the static cases
# above them run no entrypoint. Pinned as a set so nothing lands in a real home.
nrm() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
AD_TMP="$(mktemp -d)"; readonly AD_TMP
trap 'rm -rf "$AD_TMP"' EXIT
mkdir -p "$AD_TMP/wf" "$AD_TMP/plans" "$AD_TMP/repo"
export WORKFLOW_STATE_DIR="$(nrm "$AD_TMP/wf")"
export WORKFLOW_PLANS_DIR="$(nrm "$AD_TMP/plans")"
export AGENTS_STATE_DIR="$(nrm "$AD_TMP/agents-state")"
unset CLAUDE_CODE_SESSION_ID
git init -q "$AD_TMP/repo" >/dev/null 2>&1
git -C "$AD_TMP/repo" config core.hooksPath /dev/null
export CLAUDE_PROJECT_DIR="$(nrm "$AD_TMP/repo")"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# advance-args.js is required by both next-step and set-workflow-type, so it
# inherits the same ban: it holds argv vocabulary only today, and this pin
# forbids plan-reading logic from ever growing there.
TARGETS="
bin/workflow/lib/next-step/advance.js
bin/workflow/lib/next-step/advance-shared.js
bin/workflow/lib/next-step/advance-args.js
hooks/workflow-state/record-step-verdict.js
"

# Tokens that can only appear in code that reaches plan prose. `isTrivial` is the
# keyword-matching predicate over intent.md; the plans dir is where the artifacts
# live; the three artifact suffixes are the artifacts themselves.
FORBIDDEN_TOKENS="isTrivial -intent.md -outline.md -detail.md getWorkflowPlansDir WORKFLOW_PLANS_DIR"
# Modules whose entire purpose is parsing those artifacts.
FORBIDDEN_REQUIRES="parse-closes-issues parse-worktrees workflow-plans-dir"

echo "=== N1: the advance-path modules exist ==="
for f in $TARGETS; do
  if [ -f "$f" ]; then pass "N1: $f exists"; else fail "N1: $f exists -- file not found"; fi
done

echo ""
echo "=== N2: no prose-reading API is referenced ==="
for f in $TARGETS; do
  [ -f "$f" ] || { fail "N2: $f is unreadable -- cannot prove it reads no prose"; continue; }
  for t in $FORBIDDEN_TOKENS; do
    if grep -qF -- "$t" "$f"; then
      fail "N2: $f must not reference $t -- found at $(grep -nF -- "$t" "$f" | head -1)"
    else
      pass "N2: $f does not reference $t"
    fi
  done
done

echo ""
echo "=== N3: no plan-artifact parser is required ==="
for f in $TARGETS; do
  [ -f "$f" ] || { fail "N3: $f is unreadable -- cannot prove its requires"; continue; }
  for m in $FORBIDDEN_REQUIRES; do
    if grep -n 'require(' "$f" | grep -qF -- "$m"; then
      fail "N3: $f must not require $m"
    else
      pass "N3: $f does not require $m"
    fi
  done
done

echo ""
echo "=== N4: the detector is not vacuous ==="
# A grep-based ban proves nothing unless the same grep flags a module that really
# does read prose. skip-signal-resolver.js is the reference positive.
CONTROL="hooks/workflow-state/skip-signal-resolver.js"
if grep -qF -- "isTrivial" "$CONTROL" && grep -qF -- "-intent.md" "$CONTROL"; then pass "N4: the token scan flags the known prose reader ($CONTROL)"
else fail "N4: the token scan flags the known prose reader ($CONTROL) -- detector is broken or the control moved"; fi

echo ""
echo "=== S1: Stage-5 SKILL.md call-site --next pinning (#1644 waste-type-5 regression guard) ==="
# Each declaring-gate call site migrated by Stage 5 either omits --next (its result
# is never consumed -- the skill proceeds to its own next documented step) or passes
# --next (its ACTION block IS consumed). A drive-by edit that adds/drops --next
# silently changes which contract applies -- pin both directions here.

# #2460: the skill-level record-complexity-and-skip and record-skip-judgment call
# sites are gone at the end state (jev-judge finalize is the only skip writer), so
# only the workflow_init sites remain pinned here.
NO_NEXT_FILES=(
  "skills/workflow-init/SKILL.md"
  "skills/workflow-init/SKILL.md"
)
NO_NEXT_TEXT=(
  'node "$AGENTS_MAIN_ROOT/bin/workflow/set-deliverable-type" --session "$SESSION_ID" --type wf-meta --advance --step workflow_init --complete'
  'node "$AGENTS_MAIN_ROOT/bin/workflow/next-step" --advance --step workflow_init --complete'
)

for i in "${!NO_NEXT_FILES[@]}"; do
  f="${NO_NEXT_FILES[$i]}"
  t="${NO_NEXT_TEXT[$i]}"
  if [ ! -f "$f" ]; then fail "S1-no-next[$i]: $f exists -- file not found"; continue; fi
  if ! grep -qF -- "$t" "$f"; then
    fail "S1-no-next[$i]: $f does not contain expected call-site text: $t"
    continue
  fi
  pass "S1-no-next[$i]: $f contains the expected no-\`--next\` call site"
  # The captured span already runs to the command's natural terminator (closing
  # backtick / pipe) -- assert that span itself carries no --next flag.
  if printf '%s' "$t" | grep -qF -- '--next'; then
    fail "S1-no-next[$i]: $f call-site span itself contains --next -- fixture is wrong"
  else
    pass "S1-no-next[$i]: $f call-site span carries no --next flag"
  fi
done

WITH_NEXT_FILES=(
  "skills/make-outline-plan/SKILL.md"
  "skills/make-detail-plan/SKILL.md"
  "skills/run-tests/SKILL.md"
  "skills/run-tests/SKILL.md"
)
WITH_NEXT_TEXT=(
  'node "$AGENTS_MAIN_ROOT/bin/workflow/next-step" --advance --step outline --complete --next'
  'node "$AGENTS_MAIN_ROOT/bin/workflow/next-step" --advance --step detail --complete --next'
  'node "$AGENTS_MAIN_ROOT/bin/workflow/next-step" --advance --step run_tests --complete --next'
  'node "$AGENTS_MAIN_ROOT/bin/workflow/next-step" --advance --step run_tests --skipped --skip-reason "<reason>" --next'
)

for i in "${!WITH_NEXT_FILES[@]}"; do
  f="${WITH_NEXT_FILES[$i]}"
  t="${WITH_NEXT_TEXT[$i]}"
  if [ ! -f "$f" ]; then fail "S1-with-next[$i]: $f exists -- file not found"; continue; fi
  if grep -qF -- "$t" "$f"; then
    pass "S1-with-next[$i]: $f contains the expected --next-consuming call site"
  else
    fail "S1-with-next[$i]: $f does not contain expected call-site text: $t"
  fi
done

# ---------------------------------------------------------------------------
# #2460: the advance door for a "recorded-verdict:" skip of outline / detail.
# Such a reason passes next-step's pending-verdict gate, so the door admits it only
# while an all-true skip judgment stands, and checks + writes under the skip owner lock.
# ---------------------------------------------------------------------------
ROOT_N="$(nrm "$SCRIPT_CHECKOUT_ROOT")"
NEXT_CLI="$ROOT_N/bin/workflow/next-step"
export AD_WS="$ROOT_N/hooks/workflow-state"
export AD_SETTLE="$ROOT_N/hooks/lib/jev/two-stage/settle-skip.js"
export AD_CONTROL="$ROOT_N/hooks/workflow-state/state-io/control-dir.js"
export AD_NEXT="$NEXT_CLI"
AD_REPO="$AD_TMP/repo"
check() { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 -- expected [$2] got [$3]"; fi; }
check_contains() {
  if printf '%s' "$3" | grep -qF -- "$2"; then pass "$1"; else fail "$1 -- expected [$2] in: $3"; fi
}
tmo() { if command -v timeout >/dev/null 2>&1; then timeout 60 "$@"; else perl -e 'alarm 60; exec @ARGV' -- "$@"; fi; }

AD_STEPS="workflow_init clarify_intent research outline detail branching_complete write_tests review_tests write_code run_tests review_security docs user_verification cleanup pre_final_report_gate final_report"
# ad_state <sid> <step the session is on: outline|detail>
ad_state() {
  local sid="$1" done_steps="workflow_init clarify_intent research" json='{"steps":{' first=1 s st
  [ "$2" = "detail" ] && done_steps="$done_steps outline"
  for s in $AD_STEPS; do
    st="pending"; case " $done_steps " in *" $s "*) st="complete" ;; esac
    [ $first -eq 1 ] || json="$json,"; first=0
    json="$json\"$s\":{\"status\":\"$st\"}"
  done
  printf '%s' "$json},\"closes_issues\":[2460]}" > "$AD_TMP/wf/${sid}.json"
  tmo node "$ROOT_N/tests/lib/plan-approval-fixture.js" inject-complete \
    "$(nrm "$AD_TMP/wf/${sid}.json")" clarify_intent outline detail >/dev/null 2>&1 || true
}
conds_of() { # <target> <true|false>
  if [ "$1" = "detail" ]; then printf '{"sd_single_approach":true,"sd_no_open_decision":%s}' "$2"
  else printf '{"so_c1":true,"so_c2":%s}' "$2"; fi
}
artifact_of() { if [ "$2" = "detail" ]; then echo "$AD_TMP/plans/$1-outline.md"; else echo "$AD_TMP/plans/$1-intent.md"; fi; }
# stand <sid> <target> <true|false> — the stage artifact, then a judgment recorded after it.
stand() {
  : > "$(artifact_of "$1" "$2")"
  AD_SID="$1" AD_TARGET="$2" AD_CONDS="$(conds_of "$2" "$3")" tmo node -e '
    require(process.env.AD_WS).recordSkipJudgment(
      process.env.AD_SID, process.env.AD_TARGET, JSON.parse(process.env.AD_CONDS), "subagent");
  ' >/dev/null 2>&1 || true
}
# entry <sid> <step> — "<status>|<skip_reason or ->|<all_conditions_met or ->".
entry() {
  AD_SID="$1" AD_STEP="$2" tmo node -e '
    const wf = require(process.env.AD_WS);
    const s = wf.readState(process.env.AD_SID) || {};
    const e = ((s.current && s.current.steps) || s.steps || {})[process.env.AD_STEP] || {};
    const sj = wf.readSkipJudgment(process.env.AD_SID, process.env.AD_STEP);
    process.stdout.write([e.status || "-", e.skip_reason || "-", sj ? String(sj.all_conditions_met) : "-"].join("|"));
  ' 2>/dev/null || echo PROBE_FAIL
}
lock_of() { # <sid> <target>
  AD_SID="$1" AD_NAME="$2-skip-owner.lock" tmo node -e '
    process.stdout.write(require(process.env.AD_CONTROL).controlPath(
      process.env.AD_SID, process.env.AD_NAME, { forWrite: true }));
  ' 2>/dev/null
}
AD_OUT=""; AD_ERR=""; AD_RC=0
advance_skip() { # <sid> <step> <reason>
  AD_RC=0
  AD_OUT="$(cd "$AD_REPO" && tmo node "$NEXT_CLI" --advance --step "$2" --skipped --skip-reason "$3" --session "$1" 2>"$AD_TMP/err")" || AD_RC=$?
  AD_ERR="$(cat "$AD_TMP/err" 2>/dev/null || echo "")"
}

echo ""
echo "=== D1: a recorded-verdict reason is admitted only while an all-true judgment stands ==="
for step in outline detail; do
  rv="recorded-verdict: judged for $step"
  ad_state "d1n-$step" "$step"
  advance_skip "d1n-$step" "$step" "$rv"
  check "D1 [$step] no judgment: exit 3" 3 "$AD_RC"
  check_contains "D1 [$step] no judgment: the refusal names the missing judgment" "skip refused" "$AD_ERR"
  check "D1 [$step] no judgment: no ADVANCED line" "" "$AD_OUT"
  check "D1 [$step] no judgment: the step stays pending, nothing written" "pending|-|-" "$(entry "d1n-$step" "$step")"

  ad_state "d1f-$step" "$step"; stand "d1f-$step" "$step" false
  advance_skip "d1f-$step" "$step" "$rv"
  check "D1 [$step] a not-all-true judgment: exit 3" 3 "$AD_RC"
  check "D1 [$step] a not-all-true judgment: the step stays pending" "pending|-|false" "$(entry "d1f-$step" "$step")"

  ad_state "d1s-$step" "$step"; stand "d1s-$step" "$step" true
  touch -d '2037-01-01 00:00:00' "$(artifact_of "d1s-$step" "$step")"
  advance_skip "d1s-$step" "$step" "$rv"
  check "D1 [$step] a judgment older than its artifact: exit 3" 3 "$AD_RC"
  check "D1 [$step] a judgment older than its artifact: the step stays pending" "pending|-|true" "$(entry "d1s-$step" "$step")"

  ad_state "d1w-$step" "$step"
  advance_skip "d1w-$step" "$step" "   $rv"
  check "D1 [$step] leading whitespace does not slip past the door: exit 3" 3 "$AD_RC"
  check "D1 [$step] leading whitespace: the step stays pending" "pending|-|-" "$(entry "d1w-$step" "$step")"

  ad_state "d1t-$step" "$step"; stand "d1t-$step" "$step" true
  advance_skip "d1t-$step" "$step" "$rv"
  check "D1 [$step] an all-true judgment stands: exit 0" 0 "$AD_RC"
  check "D1 [$step] an all-true judgment stands: ADVANCED line" "ADVANCED=$step status=skipped" "$AD_OUT"
  check "D1 [$step] an all-true judgment stands: skipped with the reason" "skipped|$rv|true" "$(entry "d1t-$step" "$step")"
  check "D1 [$step] the owner lock is released afterwards" "no" \
    "$([ -e "$(lock_of "d1t-$step" "$step")" ] && echo yes || echo no)"

  ad_state "d1o-$step" "$step"
  advance_skip "d1o-$step" "$step" "the plan stage is not needed for this change"
  check "D1 [$step] another reason is not judged by this door: exit 0" 0 "$AD_RC"
  check "D1 [$step] another reason: skipped without a judgment" \
    "skipped|the plan stage is not needed for this change|-" "$(entry "d1o-$step" "$step")"
done

echo ""
echo "=== D2: the judged skip is checked and written under the skip owner lock ==="
ad_state d2a outline; stand d2a outline true
D2_LOCK="$(lock_of d2a outline)"
mkdir -p "$(dirname "$D2_LOCK")"
AD_LOCK="$D2_LOCK" node -e '
  require("fs").writeFileSync(process.env.AD_LOCK, String(process.pid));
  setTimeout(() => {}, 60000);
' &
D2_HOLDER=$!
for _ in $(seq 1 100); do [ -s "$D2_LOCK" ] && break; sleep 0.1; done
D2_HELD="$(cat "$D2_LOCK" 2>/dev/null || echo "")"
if [ -n "$D2_HELD" ]; then pass "D2a setup: another live process holds the lock"
else fail "D2a setup: another live process holds the lock -- lock file never appeared"; fi
advance_skip d2a outline "recorded-verdict: so_c1+so_c2 met"
check "D2a: a lock held by another live process refuses the skip: exit 3" 3 "$AD_RC"
check_contains "D2a: the refusal names the lock" "skip owner lock not acquired" "$AD_ERR"
check "D2a: no ADVANCED line" "" "$AD_OUT"
check "D2a: the step stays pending, the judgment untouched" "pending|-|true" "$(entry d2a outline)"
check "D2a: the holder's lock is left as it was" "$D2_HELD" "$(cat "$D2_LOCK" 2>/dev/null || echo "")"
kill "$D2_HOLDER" 2>/dev/null || true
wait "$D2_HOLDER" 2>/dev/null || true

# The same lock now names a process that is gone and is not this caller's parent: it is
# not read as a parent hold. The caller takes the lock itself, so the lock is gone afterwards.
advance_skip d2a outline "recorded-verdict: so_c1+so_c2 met"
check "D2c: a lock naming a gone, non-parent pid is taken over: exit 0" 0 "$AD_RC"
check "D2c: the step is skipped" "skipped|recorded-verdict: so_c1+so_c2 met|true" "$(entry d2a outline)"
check "D2c: the caller released the lock it took" "no" "$([ -e "$D2_LOCK" ] && echo yes || echo no)"

# Parent hold: the lock names this caller's parent, which waits for it.
ad_state d2b outline; stand d2b outline true
D2B="$(cd "$AD_REPO" && AD_SID=d2b tmo node -e '
  const { spawnSync } = require("child_process");
  const { underSkipOwnerLock } = require(process.env.AD_SETTLE);
  const r = underSkipOwnerLock(process.env.AD_SID, "outline", () => spawnSync(process.execPath, [
    process.env.AD_NEXT, "--advance", "--step", "outline", "--skipped",
    "--skip-reason", "recorded-verdict: so_c1+so_c2 met", "--session", process.env.AD_SID,
  ], { encoding: "utf8" }));
  process.stdout.write(r.status + "|" + String(r.stdout).trim());
' 2>/dev/null || echo PROBE_FAIL)"
check "D2b: an advance spawned by the lock holder runs under that hold" "0|ADVANCED=outline status=skipped" "$D2B"
check "D2b: the step is skipped" "skipped|recorded-verdict: so_c1+so_c2 met|true" "$(entry d2b outline)"

# The production shape of the parent hold: settleSkip spawns record-skip-judgment --advance.
ad_state d2s outline; : > "$(artifact_of d2s outline)"
D2S_TID=0123456789abcdef
D2S_CLAIM="$(tmo node "$ROOT_N/tests/lib/finalized-ticket.js" "$ROOT_N" d2s outline "$D2S_TID" "$(conds_of outline true)" subagent 2>/dev/null || echo "")"
D2S="$(cd "$AD_REPO" && AD_SID=d2s AD_TID="$D2S_TID" AD_CLAIM="$D2S_CLAIM" tmo node -e '
  const claim = JSON.parse(require("fs").readFileSync(process.env.AD_CLAIM.trim(), "utf8"));
  const r = require(process.env.AD_SETTLE).settleSkip(process.env.AD_SID, "outline", { so_c1: true, so_c2: true },
    "subagent", { id: process.env.AD_TID, created_ms: claim.created_ms }, process.env.AD_TID,
    { stage: claim.stage, artifacts_sha256: claim.artifacts_sha256 });
  process.stdout.write(r.settle + "|" + r.rsj_lines.filter((l) => l.startsWith("ADVANCED=")).join(","));
' 2>&1 || echo PROBE_FAIL)"
check "D2s: settleSkip's own record-skip-judgment --advance completes under its lock" \
  "ok|ADVANCED=outline status=skipped" "$D2S"
check "D2s: the step is skipped by the recorded verdict" \
  "skipped|recorded-verdict: so_c1+so_c2 met|true" "$(entry d2s outline)"
check "D2s: settleSkip released the lock" "no" "$([ -e "$(lock_of d2s outline)" ] && echo yes || echo no)"

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
