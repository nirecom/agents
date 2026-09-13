#!/usr/bin/env bash
# tests/fix-524-confirm-plan-guard/layer2-cases.sh
# Tests: hooks/stop-confirm-plan-guard.js, hooks/lib/plan-artifact-lang.js
# Tags: plan, hook, workflow, plans, lang, TL2, scope:common
# Sourced by ../fix-524-confirm-plan-guard.sh after T10 — reuses PLANS_DIR,
# WORKFLOW_DIR, ISOLATED_CFG_DIR, TRANSCRIPT_DIR, STOP_HOOK, write_marker,
# write_transcript, count_markers, pass/fail, run_with_timeout.
# T13..T35 (#2278): Layer 2 fires on every Stop (marker-independent) and
# re-lints the CONFIRMed stage artifact against PLAN_LANG before the follow-up check.
# lang-check: ignore -- this file intentionally contains CJK test fixtures for language-policy tests

L2_FOLLOWUP_PREFIX='[confirm-plan] Layer 2/follow-up:'
L2_PLANLANG_PREFIX='[confirm-plan] Layer 2/plan-lang:'
L1_PREFIX='[confirm-plan] Step 2 violation:'
L2_EN_PROSE='This artifact body is written entirely in English prose here.'
L2_JA_PROSE='この計画書は日本語で書かれています。'

# TL3 gap (what this test does NOT catch):
# - real Claude Code Stop-event dispatch of stop-confirm-plan-guard.js via the
#   settings.json Stop registration (here the hook is run directly with a synthetic
#   stdin payload and a hand-built transcript)
# - whether an exit-2 block really keeps a live session from stopping
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

# set_plan_lang <value|->  — the fixture AGENTS_CONFIG_DIR/.env is the sole PLAN_LANG
# source; "-" writes an empty .env (PLAN_LANG unset). Never carries DOCS_LANG_* keys.
set_plan_lang() {
  if [ -n "$1" ] && [ "$1" != "-" ]; then
    printf 'PLAN_LANG=%s\n' "$1" > "$ISOLATED_CFG_DIR/.env"
  else
    : > "$ISOLATED_CFG_DIR/.env"
  fi
}

# run_stop_hook_l2 <stdin_json> — like run_stop_hook, but the child never sees
# the developer's PLAN_LANG / DOCS_LANG_* or the live session ids (rules/test/fixture-isolation.md).
# Sets STOP_STDOUT, STOP_STDERR, STOP_RC.
run_stop_hook_l2() {
  local stdin_json="$1" errf="$TRANSCRIPT_DIR/l2-stderr.txt"
  STOP_STDOUT=$(
    unset PLAN_LANG DOCS_LANG_PUBLIC DOCS_LANG_PRIVATE CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE
    echo "$stdin_json" | run_with_timeout node "$STOP_HOOK" 2>"$errf"
  )
  STOP_RC=$?
  STOP_STDERR=$(cat "$errf" 2>/dev/null || echo "")
}

# l2_transcript <stage|-> <followup|-> <leading_text|->
# One assistant turn: [text?] → Bash CONFIRM_<STAGE> tool_use → follow-up?
# followup: a Skill name, or "bash:<command>" for a Bash tool_use follow-up.
l2_transcript() {
  run_with_timeout node -e '
const [stage, skill, text] = process.argv.slice(1);
const content = [];
if (text !== "-") content.push({ type: "text", text });
if (stage !== "-") content.push({ type: "tool_use", name: "Bash", input: { command: "echo \"<<WORKFLOW_CONFIRM_" + stage.toUpperCase() + ": ok>>\"" } });
if (skill.startsWith("bash:")) content.push({ type: "tool_use", name: "Bash", input: { command: skill.slice(5) } });
else if (skill !== "-") content.push({ type: "tool_use", name: "Skill", input: { skill } });
process.stdout.write(JSON.stringify({ type: "assistant", message: { content } }));
' "$1" "$2" "$3"
}

# stop_reason — block reason from STOP_STDOUT ("" unless decision=block)
stop_reason() {
  run_with_timeout node -e '
try { const o = JSON.parse(process.argv[1]); process.stdout.write(o.decision === "block" && typeof o.reason === "string" ? o.reason : ""); }
catch (e) { process.stdout.write(""); }
' "$STOP_STDOUT" 2>/dev/null
}

# l2_case <plan_lang|-> <label> <sid> <stage|-> <followup|-> <text|-> <expected rc> <expected reason prefix|-> [reason must contain]
# PLAN_LANG is (re)written per case (C6) — no case inherits a sibling's .env state.
# No marker is written unless the caller did so beforehand.
l2_case() {
  local plan_lang="$1" label="$2" sid="$3" stage="$4" skill="$5" text="$6" exp_rc="$7" exp_prefix="$8" must_have="${9:-}"
  local tpath="$TRANSCRIPT_DIR/${sid}.jsonl" reason ok=1
  set_plan_lang "$plan_lang"
  write_transcript "$tpath" "$(l2_transcript "$stage" "$skill" "$text")"
  run_stop_hook_l2 "{\"session_id\":\"$sid\",\"transcript_path\":\"$tpath\"}"
  reason="$(stop_reason)"
  [ "$STOP_RC" -eq "$exp_rc" ] || ok=0
  if [ "$exp_prefix" = "-" ]; then
    [ -z "$STOP_STDOUT" ] || ok=0
  else
    [ -n "$reason" ] && [ "${reason#"$exp_prefix"}" != "$reason" ] || ok=0
    [ -z "$must_have" ] || [ "${reason#*"$must_have"}" != "$reason" ] || ok=0
  fi
  if [ "$ok" -eq 1 ]; then
    pass "$label"
  else
    fail "$label — expected rc=$exp_rc prefix='$exp_prefix'${must_have:+ containing '$must_have'}; got rc=$STOP_RC stdout='$STOP_STDOUT' stderr='$STOP_STDERR'"
  fi
}

# write_artifact <sid> <stage> <body> — plan artifact in the pinned PLANS_DIR
write_artifact() {
  printf '%s\n' "$3" > "$PLANS_DIR/$1-$2.md"
}

# ── T13: marker-less Layer 2, follow-up present → silent pass ────────────
echo "=== T13: no marker, CONFIRM_DETAIL + write-tests follow-up ==="
l2_case - "T13 no marker, PLAN_LANG unset, CONFIRM_DETAIL + Skill write-tests — exit 0, empty stdout" \
  "a1b2c3d4-e5f6-7890-abcd-ef1234560013" detail write-tests - 0 -

# ── T14: marker-less Layer 2 fires on a missing follow-up ────────────────
echo "=== T14: no marker, CONFIRM_OUTLINE without follow-up ==="
l2_case - "T14 no marker, PLAN_LANG unset, CONFIRM_OUTLINE alone — exit 2, reason starts with Layer 2/follow-up" \
  "a1b2c3d4-e5f6-7890-abcd-ef1234560014" outline - - 2 "$L2_FOLLOWUP_PREFIX"

# ── T15/T16/T17: PLAN_LANG re-lint blocks even with a valid follow-up (3 stages) ──
echo "=== T15-T17: PLAN_LANG=japanese, English artifact, valid follow-up → plan-lang block ==="
# Row: "<T> <sid> <stage> <follow-up skill>" (array, not a heredoc: node children must not share the loop's stdin)
L2_STAGE_ROWS=(
  "T15 a1b2c3d4-e5f6-7890-abcd-ef1234560015 intent make-outline-plan"
  "T16 a1b2c3d4-e5f6-7890-abcd-ef1234560016 outline make-detail-plan"
  "T17 a1b2c3d4-e5f6-7890-abcd-ef1234560017 detail write-tests"
)
for _row in "${L2_STAGE_ROWS[@]}"; do
  read -r _t _sid _stage _skill <<< "$_row"
  write_artifact "$_sid" "$_stage" "$L2_EN_PROSE"
  l2_case japanese "$_t PLAN_LANG=japanese, English ${_stage}.md + Skill $_skill — exit 2, Layer 2/plan-lang names ${_stage}.md" \
    "$_sid" "$_stage" "$_skill" - 2 "$L2_PLANLANG_PREFIX" "${_stage}.md"
done

# ── T18: both session-id forms resolve the artifact (#1079 regression) ───
echo "=== T18: TIMESTAMP and UUID session ids both re-lint ==="
for _sid in "20260625-120000" "a1b2c3d4-e5f6-7890-abcd-ef1234567890"; do
  write_artifact "$_sid" intent "$L2_EN_PROSE"
  l2_case japanese "T18 sid=$_sid — English intent.md re-linted, exit 2 Layer 2/plan-lang" \
    "$_sid" intent make-outline-plan - 2 "$L2_PLANLANG_PREFIX" "intent.md"
  rm -f "$PLANS_DIR/$_sid-intent.md"
done

# ── T19: hint tier never blocks ──────────────────────────────────────────
echo "=== T19: PLAN_LANG=french (hint), English artifact, follow-up present ==="
write_artifact "a1b2c3d4-e5f6-7890-abcd-ef1234560019" detail "$L2_EN_PROSE"
l2_case french "T19 PLAN_LANG=french + English detail.md + write-tests — exit 0, empty stdout (hint tier)" \
  "a1b2c3d4-e5f6-7890-abcd-ef1234560019" detail write-tests - 0 -

# ── T20: compliant artifact passes ───────────────────────────────────────
echo "=== T20: PLAN_LANG=japanese, Japanese artifact ==="
write_artifact "a1b2c3d4-e5f6-7890-abcd-ef1234560020" detail "$L2_JA_PROSE"
l2_case japanese "T20 PLAN_LANG=japanese + Japanese detail.md + write-tests — exit 0, empty stdout" \
  "a1b2c3d4-e5f6-7890-abcd-ef1234560020" detail write-tests - 0 -

# ── T21: Layer 1 precedes Layer 2 (ordering contract) ────────────────────
echo "=== T21: marker + path leak + CONFIRM_DETAIL without follow-up → Step 2 violation ==="
SID_T21="a1b2c3d4-e5f6-7890-abcd-ef1234560021"
write_marker "$SID_T21" detail >/dev/null
l2_case japanese "T21 marker + leaked path + CONFIRM_DETAIL (no follow-up) — Layer 1 'Step 2 violation' wins" \
  "$SID_T21" detail - "see $PLANS_DIR/abc-detail.md for details" 2 "$L1_PREFIX"
rm -f "$WORKFLOW_DIR/${SID_T21}".confirm-plan-turn-*.json 2>/dev/null || true

# ── T22 (C5): PLAN_LANG=english, Japanese artifact, follow-up present → plan-lang block ──
echo "=== T22: PLAN_LANG=english, Japanese detail.md + write-tests → Layer 2/plan-lang ==="
write_artifact "a1b2c3d4-e5f6-7890-abcd-ef1234560022" detail "$L2_JA_PROSE"
l2_case english "T22 PLAN_LANG=english + Japanese detail.md + write-tests — exit 2, Layer 2/plan-lang names detail.md" \
  "a1b2c3d4-e5f6-7890-abcd-ef1234560022" detail write-tests - 2 "$L2_PLANLANG_PREFIX" "detail.md"

# ── T23 (C5): artifact missing, PLAN_LANG strict, follow-up present → fail-open ──
echo "=== T23: PLAN_LANG=japanese, artifact absent, follow-up present → exit 0 ==="
rm -f "$PLANS_DIR/a1b2c3d4-e5f6-7890-abcd-ef1234560023-outline.md"
l2_case japanese "T23 PLAN_LANG=japanese, outline.md absent + make-detail-plan — exit 0, empty stdout (fail-open)" \
  "a1b2c3d4-e5f6-7890-abcd-ef1234560023" outline make-detail-plan - 0 -

# ── T24 (C5): artifact path is a directory (unreadable), follow-up present → fail-open ──
echo "=== T24: PLAN_LANG=japanese, artifact path is a directory, follow-up present → exit 0 ==="
SID_T24="a1b2c3d4-e5f6-7890-abcd-ef1234560024"
mkdir -p "$PLANS_DIR/$SID_T24-intent.md"
l2_case japanese "T24 PLAN_LANG=japanese, intent.md is a directory + make-outline-plan — exit 0, empty stdout (unreadable → fail-open)" \
  "$SID_T24" intent make-outline-plan - 0 -
rmdir "$PLANS_DIR/$SID_T24-intent.md" 2>/dev/null || true

# ── T25 (C3): strict-English allow path ──────────────────────────────────
echo "=== T25: PLAN_LANG=english, English detail.md + write-tests → exit 0 ==="
write_artifact "a1b2c3d4-e5f6-7890-abcd-ef1234560025" detail "$L2_EN_PROSE"
l2_case english "T25 PLAN_LANG=english + English detail.md + write-tests — exit 0, empty stdout" \
  "a1b2c3d4-e5f6-7890-abcd-ef1234560025" detail write-tests - 0 -

# ── T26 (C5): plan-lang re-lint precedes the follow-up check (ordering pin) ──
echo "=== T26: PLAN_LANG=japanese, English detail.md, CONFIRM_DETAIL with NO follow-up → plan-lang wins ==="
write_artifact "a1b2c3d4-e5f6-7890-abcd-ef1234560026" detail "$L2_EN_PROSE"
l2_case japanese "T26 English detail.md + CONFIRM_DETAIL, no Skill — exit 2, reason starts with Layer 2/plan-lang (not Layer 2/follow-up)" \
  "a1b2c3d4-e5f6-7890-abcd-ef1234560026" detail - - 2 "$L2_PLANLANG_PREFIX"

# ── T27 (C1): marker PRESENT + compliant artifact + no follow-up → Layer 2 still fires ──
echo "=== T27: marker present, Japanese detail.md, CONFIRM_DETAIL without follow-up → Layer 2/follow-up ==="
SID_T27="a1b2c3d4-e5f6-7890-abcd-ef1234560027"
write_artifact "$SID_T27" detail "$L2_JA_PROSE"
write_marker "$SID_T27" detail >/dev/null
l2_case japanese "T27 marker + Japanese detail.md + CONFIRM_DETAIL, no Skill — exit 2, Layer 2/follow-up (marker must not short-circuit Layer 2)" \
  "$SID_T27" detail - - 2 "$L2_FOLLOWUP_PREFIX"
rm -f "$WORKFLOW_DIR/${SID_T27}".confirm-plan-turn-*.json 2>/dev/null || true

# ── T28-T31 (C2): stage-aware follow-up classifier, paired allow/block ──
echo "=== T28-T31: stage-aware follow-up (allow/block pairs, Japanese artifacts) ==="
# Row: "<T>|<sid>|<stage>|<follow-up>|<rc>|<prefix|->" — follow-up "bash:<cmd>" emits a Bash tool_use.
L2_FOLLOWUP_ROWS=(
  "T28|a1b2c3d4-e5f6-7890-abcd-ef1234560028|intent|make-outline-plan|0|-"
  "T29|a1b2c3d4-e5f6-7890-abcd-ef1234560029|intent|make-detail-plan|2|$L2_FOLLOWUP_PREFIX"
  "T30|a1b2c3d4-e5f6-7890-abcd-ef1234560030|detail|bash:echo \"<<WORKFLOW_BRANCHING_COMPLETE: ok>>\"|0|-"
  "T31|a1b2c3d4-e5f6-7890-abcd-ef1234560031|detail|make-outline-plan|2|$L2_FOLLOWUP_PREFIX"
)
for _row in "${L2_FOLLOWUP_ROWS[@]}"; do
  IFS='|' read -r _t _sid _stage _fu _rc _pfx <<< "$_row"
  write_artifact "$_sid" "$_stage" "$L2_JA_PROSE"
  l2_case japanese "$_t PLAN_LANG=japanese, CONFIRM_${_stage^^} + follow-up '$_fu' — exit $_rc, prefix '$_pfx'" \
    "$_sid" "$_stage" "$_fu" - "$_rc" "$_pfx"
done

# ── T32 (C4): non-artifact-class sid is never re-linted ──────────────────
echo "=== T32: sid=sid-t13-123, English detail.md present, valid follow-up → exit 0 ==="
write_artifact "sid-t13-123" detail "$L2_EN_PROSE"
l2_case japanese "T32 PLAN_LANG=japanese, sid-t13-123 (non-artifact class) + English detail.md + write-tests — exit 0, empty stdout" \
  "sid-t13-123" detail write-tests - 0 -
rm -f "$PLANS_DIR/sid-t13-123-detail.md"

# ── T33 (C7): the re-lint is idempotent and read-only ────────────────────
echo "=== T33: same violating artifact linted twice → identical block, artifact bytes unchanged ==="
SID_T33="a1b2c3d4-e5f6-7890-abcd-ef1234560033"
write_artifact "$SID_T33" detail "$L2_EN_PROSE"
_t33_before="$(sha1sum "$PLANS_DIR/$SID_T33-detail.md" | cut -d' ' -f1)"
l2_case japanese "T33a first run: PLAN_LANG=japanese, English detail.md + write-tests — exit 2, Layer 2/plan-lang" \
  "$SID_T33" detail write-tests - 2 "$L2_PLANLANG_PREFIX"
_t33_reason1="$(stop_reason)"
l2_case japanese "T33b second run (same fixture) — exit 2, Layer 2/plan-lang" \
  "$SID_T33" detail write-tests - 2 "$L2_PLANLANG_PREFIX"
_t33_reason2="$(stop_reason)"
_t33_after="$(sha1sum "$PLANS_DIR/$SID_T33-detail.md" | cut -d' ' -f1)"
if [ -n "$_t33_reason1" ] && [ "$_t33_reason1" = "$_t33_reason2" ]; then
  pass "T33c both runs produced an identical block reason"
else
  fail "T33c reasons differ or empty — run1='$_t33_reason1' run2='$_t33_reason2'"
fi
if [ "$_t33_before" = "$_t33_after" ]; then
  pass "T33d artifact sha1 unchanged after two guard runs ($_t33_before)"
else
  fail "T33d artifact modified by the guard — before=$_t33_before after=$_t33_after"
fi

# ── T34 (C3): Layer 1 stays marker-dependent — no marker, leaked plans path, no CONFIRM ──
echo "=== T34: no marker, plans-dir path in assistant text, no CONFIRM sentinel → exit 0 ==="
SID_T34="a1b2c3d4-e5f6-7890-abcd-ef1234560034"
rm -f "$WORKFLOW_DIR/${SID_T34}".confirm-plan-turn-*.json 2>/dev/null || true
l2_case japanese "T34 PLAN_LANG=japanese, no marker, text 'see $PLANS_DIR/<uuid>-detail.md', no CONFIRM — exit 0, empty stdout (Layer 1 needs a marker)" \
  "$SID_T34" - - "see $PLANS_DIR/$SID_T34-detail.md for details" 0 -

# ── T35 (C3): Layer 2 inherits lintPlanLang's heading / closed-fence exclusions ──
echo "=== T35: English only in a heading / inside a closed fence, Japanese body → exit 0 ==="
write_artifact "a1b2c3d4-e5f6-7890-abcd-ef1234560035" detail $'# This Heading Is Written In English\n'"$L2_JA_PROSE"
l2_case japanese "T35a PLAN_LANG=japanese, English heading + Japanese body + write-tests — exit 0, empty stdout (heading excluded)" \
  "a1b2c3d4-e5f6-7890-abcd-ef1234560035" detail write-tests - 0 -
write_artifact "a1b2c3d4-e5f6-7890-abcd-ef1234560036" detail "$L2_JA_PROSE"$'\n```\nEnglish words inside a closed code fence here\n```\n'"$L2_JA_PROSE"
l2_case japanese "T35b PLAN_LANG=japanese, English inside a closed fence + Japanese body + write-tests — exit 0, empty stdout (fence excluded)" \
  "a1b2c3d4-e5f6-7890-abcd-ef1234560036" detail write-tests - 0 -
set_plan_lang -
