#!/bin/bash
# tests/feature-2278-pretool-lang-gates/gate-plan-lang-cases.sh
# Tests: hooks/gate-plan-lang.js, hooks/lib/plan-artifact-lang.js, hooks/lib/pretool-lang-gate.js
# Tags: lang, hook, pretooluse, plans, TL2, scope:issue-specific
# Sourced by ../feature-2278-pretool-lang-gates.sh — helpers come from there.
# PLG-T1..T32: hooks/gate-plan-lang.js PreToolUse gate (block before write).
# lang-check: ignore -- this file intentionally contains CJK test fixtures for language-policy tests

echo ""
echo "=== PLG: hooks/gate-plan-lang.js PreToolUse gate ==="

PLG_PREFIX_JA='[gate-plan-lang] PLAN_LANG=japanese'
PLG_PREFIX_EN='[gate-plan-lang] PLAN_LANG=english'

INTENT_TS="$PLANS_DIR/$FAKE_TS-intent.md"
OUTLINE_UUID="$PLANS_DIR/$FAKE_UUID-outline.md"
DETAIL_UUID="$PLANS_DIR/$FAKE_UUID-detail.md"
DETAIL_TS="$PLANS_DIR/$FAKE_TS-detail.md"
INTENT_UUID="$PLANS_DIR/$FAKE_UUID-intent.md"
NON_ARTIFACT="$PLANS_DIR/$FAKE_UUID-detail-draft.md"
OUTSIDE_INTENT="$OUTSIDE_DIR/$FAKE_TS-intent.md"
INNOCENT="$OUTSIDE_DIR/notes.txt"

CFG_PLAN_JA="$(make_env japanese "" "")"
CFG_PLAN_EN="$(make_env english "" "")"
CFG_PLAN_NONE="$(make_env "" "" "")"
CFG_PLAN_ANY="$(make_env any "" "")"
CFG_PLAN_FR="$(make_env french "" "")"

# PLG-T1/T2: Write English prose to a plan artifact (TIMESTAMP + UUID basenames) → block
run_gate "$PLAN_GATE" "$(mk_payload Write "$INTENT_TS" content "$EN_PROSE")" "$CFG_PLAN_JA"
assert_block_prefix "PLG-T1: Write English to ${FAKE_TS}-intent.md under PLAN_LANG=japanese → block with [gate-plan-lang] prefix" "$PLG_PREFIX_JA"
run_gate "$PLAN_GATE" "$(mk_payload Write "$OUTLINE_UUID" content "$EN_PROSE")" "$CFG_PLAN_JA"
assert_block_prefix "PLG-T2: Write English to <uuid>-outline.md under PLAN_LANG=japanese → block" "$PLG_PREFIX_JA"

# PLG-T3: Write Japanese → approve
run_gate "$PLAN_GATE" "$(mk_payload Write "$INTENT_TS" content "$JA_PROSE")" "$CFG_PLAN_JA"
assert_approve "PLG-T3: Write Japanese to plan artifact under PLAN_LANG=japanese → approve"

# PLG-T4: Edit new_string English → block; old_string ignored, disk not read (file absent)
[ -e "$DETAIL_UUID" ] && rm -f "$DETAIL_UUID"
run_gate "$PLAN_GATE" "$(mk_edit Edit "$DETAIL_UUID" "$JA_PROSE" "$EN_PROSE")" "$CFG_PLAN_JA"
assert_block_prefix "PLG-T4: Edit new_string English on absent detail.md → block (fragment only, disk not read)" "$PLG_PREFIX_JA"

# PLG-T5: MultiEdit edits[0] Japanese, edits[1] English → block naming edits[1] only
_e0="$(mk_edit_elem - "" "a" "$JA_PROSE")"
_e1="$(mk_edit_elem - "" "b" "$EN_PROSE")"
run_gate "$PLAN_GATE" "$(mk_multiedit MultiEdit "$DETAIL_UUID" "$_e0" "$_e1")" "$CFG_PLAN_JA"
assert_block_prefix "PLG-T5a: MultiEdit with one English fragment → block" "$PLG_PREFIX_JA"
assert_reason_has "PLG-T5b: block reason names edits[1]" "edits[1]"
assert_reason_lacks "PLG-T5c: block reason does not name the clean edits[0]" "edits[0]"
_e1ja="$(mk_edit_elem - "" "b" "日本語の二つ目の断片。")"
run_gate "$PLAN_GATE" "$(mk_multiedit MultiEdit "$DETAIL_UUID" "$_e0" "$_e1ja")" "$CFG_PLAN_JA"
assert_approve "PLG-T5d: MultiEdit with all-Japanese fragments → approve"

# PLG-T6: editFiles with content English → block
run_gate "$PLAN_GATE" "$(mk_payload editFiles "$INTENT_TS" content "$EN_PROSE")" "$CFG_PLAN_JA"
assert_block_prefix "PLG-T6: editFiles content English → block" "$PLG_PREFIX_JA"

# PLG-T7: PLAN_LANG=english, Write Japanese → block (both directions of the classifier)
run_gate "$PLAN_GATE" "$(mk_payload Write "$INTENT_TS" content "$JA_PROSE")" "$CFG_PLAN_EN"
assert_block_prefix "PLG-T7: Write Japanese under PLAN_LANG=english → block" "$PLG_PREFIX_EN"

# PLG-T8: English only in a heading line, Japanese body → approve
run_gate "$PLAN_GATE" "$(mk_payload Write "$INTENT_TS" content $'# This Heading Is Written In English\n'"$JA_PROSE")" "$CFG_PLAN_JA"
assert_approve "PLG-T8: English heading + Japanese body → approve (heading exclusion inherited)"

# PLG-T9: English inside a fence closed within the same fragment → approve
run_gate "$PLAN_GATE" "$(mk_payload Write "$INTENT_TS" content "$JA_PROSE"$'\n```\nEnglish words inside a closed code fence here\n```\n'"$JA_PROSE")" "$CFG_PLAN_JA"
assert_approve "PLG-T9: English inside a closed code fence → approve"

# PLG-T10: non-artifact basename in plans dir → approve
run_gate "$PLAN_GATE" "$(mk_payload Write "$NON_ARTIFACT" content "$EN_PROSE")" "$CFG_PLAN_JA"
assert_approve "PLG-T10: <uuid>-detail-draft.md (non-artifact basename) → approve"

# PLG-T11: artifact-shaped basename outside the plans dir → approve
run_gate "$PLAN_GATE" "$(mk_payload Write "$OUTSIDE_INTENT" content "$EN_PROSE")" "$CFG_PLAN_JA"
assert_approve "PLG-T11: intent.md outside WORKFLOW_PLANS_DIR → approve"

# PLG-T12: PLAN_LANG unset / any → approve (noop tier), no additionalContext
run_gate "$PLAN_GATE" "$(mk_payload Write "$INTENT_TS" content "$EN_PROSE")" "$CFG_PLAN_NONE"
assert_approve "PLG-T12a: PLAN_LANG unset → approve without additionalContext"
run_gate "$PLAN_GATE" "$(mk_payload Write "$INTENT_TS" content "$EN_PROSE")" "$CFG_PLAN_ANY"
assert_approve "PLG-T12b: PLAN_LANG=any → approve without additionalContext"

# PLG-T13: hint tier (french) → silent approve
run_gate "$PLAN_GATE" "$(mk_payload Write "$INTENT_TS" content "$EN_PROSE")" "$CFG_PLAN_FR"
assert_approve "PLG-T13: PLAN_LANG=french (hint tier) → silent approve, no additionalContext"

# PLG-T14: non-JSON stdin → approve, rc 0 (fail-open)
run_gate "$PLAN_GATE" 'not-json' "$CFG_PLAN_JA"
assert_approve "PLG-T14: non-JSON stdin → approve rc 0 (fail-open)"

# PLG-T15: relative WORKFLOW_PLANS_DIR makes getWorkflowPlansDir throw → approve (fail-open)
WORKFLOW_PLANS_DIR="relative/plans" run_gate "$PLAN_GATE" "$(mk_payload Write "$INTENT_TS" content "$EN_PROSE")" "$CFG_PLAN_JA"
assert_approve "PLG-T15: relative WORKFLOW_PLANS_DIR (resolver throws) → approve (fail-open)"

# PLG-T16: non-target tool → approve
run_gate "$PLAN_GATE" "$(mk_payload Read "$INTENT_TS" - "")" "$CFG_PLAN_JA"
assert_approve "PLG-T16: tool_name=Read → approve"

# PLG-T17 (C3): unclosed fence in one fragment must not swallow a sibling fragment
_fence_ja="$(mk_edit_elem - "" "a" $'```\n日本語の行')"
_plain_en="$(mk_edit_elem - "" "b" "$EN_PROSE")"
run_gate "$PLAN_GATE" "$(mk_multiedit MultiEdit "$DETAIL_UUID" "$_fence_ja" "$_plain_en")" "$CFG_PLAN_JA"
assert_block_prefix "PLG-T17a: edits[0] opens an unclosed fence, edits[1] English → block (fragments linted independently)" "$PLG_PREFIX_JA"
run_gate "$PLAN_GATE" "$(mk_multiedit MultiEdit "$DETAIL_UUID" "$_plain_en" "$_fence_ja")" "$CFG_PLAN_JA"
assert_block_prefix "PLG-T17b: reverse order (English first, unclosed fence second) → block" "$PLG_PREFIX_JA"

# PLG-T18 (C2): innocent top-level path, artifact path on the element → block (both spellings)
_el_fp="$(mk_edit_elem file_path "$INTENT_UUID" "a" "$EN_PROSE")"
run_gate "$PLAN_GATE" "$(mk_multiedit MultiEdit "$INNOCENT" "$_el_fp")" "$CFG_PLAN_JA"
assert_block_prefix "PLG-T18a: edits[0].file_path = plan artifact, top-level innocent → block" "$PLG_PREFIX_JA"
_el_p="$(mk_edit_elem path "$INTENT_UUID" "a" "$EN_PROSE")"
run_gate "$PLAN_GATE" "$(mk_multiedit MultiEdit "$INNOCENT" "$_el_p")" "$CFG_PLAN_JA"
assert_block_prefix "PLG-T18b: edits[0].path spelling → block" "$PLG_PREFIX_JA"

# PLG-T19 (C2 inverse): element pointing outside the plans dir is ignored even when top-level is an artifact
_el_out="$(mk_edit_elem file_path "$INNOCENT" "a" "$EN_PROSE")"
_el_inherit_ja="$(mk_edit_elem - "" "b" "$JA_PROSE")"
run_gate "$PLAN_GATE" "$(mk_multiedit MultiEdit "$DETAIL_UUID" "$_el_out" "$_el_inherit_ja")" "$CFG_PLAN_JA"
assert_approve "PLG-T19: English element targets an innocent path, inheriting element is Japanese → approve"

# PLG-T20: editFiles carrying edits[] (cases-shapes.sh S3 shape) → block
_el_ts="$(mk_edit_elem file_path "$DETAIL_TS" "a" "$EN_PROSE")"
run_gate "$PLAN_GATE" "$(mk_multiedit editFiles "$INNOCENT" "$_el_ts")" "$CFG_PLAN_JA"
assert_block_prefix "PLG-T20: editFiles edits[0].file_path = ${FAKE_TS}-detail.md English → block" "$PLG_PREFIX_JA"

# PLG-T21/T22 (C7): artifact-shaped basename whose `..` segments escape the plans
# dir after path.resolve → not a plan artifact → approve (containment is decided
# on the resolved path, never on the basename alone).
TRAVERSAL_OUT_A="$PLANS_DIR/../outside/$FAKE_UUID-intent.md"
TRAVERSAL_OUT_B="$PLANS_DIR/sub/../../$FAKE_UUID-intent.md"
run_gate "$PLAN_GATE" "$(mk_payload Write "$TRAVERSAL_OUT_A" content "$EN_PROSE")" "$CFG_PLAN_JA"
assert_approve "PLG-T21: <plans>/../outside/<uuid>-intent.md English → approve (resolves outside plans dir)"
run_gate "$PLAN_GATE" "$(mk_payload Write "$TRAVERSAL_OUT_B" content "$EN_PROSE")" "$CFG_PLAN_JA"
assert_approve "PLG-T22: <plans>/sub/../../<uuid>-intent.md English → approve (resolves outside plans dir)"

# PLG-T23 (C7 inverse): `..` that resolves back INSIDE the plans dir is still gated
TRAVERSAL_IN="$PLANS_DIR/sub/../$FAKE_UUID-intent.md"
run_gate "$PLAN_GATE" "$(mk_payload Write "$TRAVERSAL_IN" content "$EN_PROSE")" "$CFG_PLAN_JA"
assert_block_prefix "PLG-T23: <plans>/sub/../<uuid>-intent.md English → block (resolves inside plans dir)" "$PLG_PREFIX_JA"

# PLG-T24 (C3): strict-English allow path — PLAN_LANG=english, English prose → approve
run_gate "$PLAN_GATE" "$(mk_payload Write "$OUTLINE_UUID" content "$EN_PROSE")" "$CFG_PLAN_EN"
assert_approve "PLG-T24: PLAN_LANG=english, English Write to <uuid>-outline.md → approve"

# PLG-T25 (C6): malformed tool_input shapes on an artifact path, strict policy → approve (fail-open)
# Columns: name | tool | tool_input JSON (ARTIFACT = $INTENT_UUID)
while IFS='|' read -r _name _tool _raw; do
    [[ -z "$_name" || "$_name" =~ ^[[:space:]]*# ]] && continue
    _name="${_name//[[:space:]]/}"; _tool="${_tool//[[:space:]]/}"; _raw="${_raw//[[:space:]]/}"
    _raw="${_raw/ARTIFACT/$INTENT_UUID}"
    run_gate "$PLAN_GATE" "$(mk_payload_raw "$_tool" "$_raw")" "$CFG_PLAN_JA"
    assert_approve "PLG-T25/$_name: $_tool tool_input=$_raw → approve (fail-open)"
done <<'TABLE'
# name           | tool      | tool_input
null-input       | Write     | null
content-number   | Write     | {"file_path":"ARTIFACT","content":42}
newstring-object | Edit      | {"file_path":"ARTIFACT","old_string":"a","new_string":{"x":1}}
edits-empty      | MultiEdit | {"file_path":"ARTIFACT","edits":[]}
edits-notarray   | MultiEdit | {"file_path":"ARTIFACT","edits":"notarray"}
TABLE

# PLG-T26 (C1): on-disk artifact EXISTS and violates; every incoming fragment is compliant → approve.
# Proves the gate lints only post-edit fragments, never pre-edit disk content.
printf '%s\n' "$EN_PROSE" > "$DETAIL_UUID"
run_gate "$PLAN_GATE" "$(mk_edit Edit "$DETAIL_UUID" "$EN_PROSE" "$JA_PROSE")" "$CFG_PLAN_JA"
assert_approve "PLG-T26a: Edit on English detail.md (on disk), new_string Japanese → approve (disk content not linted)"
_t26_e0="$(mk_edit_elem - "" "$EN_PROSE" "$JA_PROSE")"
_t26_e1="$(mk_edit_elem - "" "prose" "日本語の二つ目の断片。")"
run_gate "$PLAN_GATE" "$(mk_multiedit MultiEdit "$DETAIL_UUID" "$_t26_e0" "$_t26_e1")" "$CFG_PLAN_JA"
assert_approve "PLG-T26b: MultiEdit on English detail.md (on disk), all fragments Japanese → approve"
rm -f "$DETAIL_UUID"

# PLG-T27 (C3): violating Write whose payload also carries a synthetic secret on a
# compliant line → block, and the secret must not surface in stdout/stderr/reason.
run_gate "$PLAN_GATE" "$(mk_payload Write "$INTENT_UUID" content "$JA_PROSE $SYNTHETIC_SECRET"$'\n'"$EN_PROSE")" "$CFG_PLAN_JA"
assert_block_prefix "PLG-T27a: Write with Japanese+secret line and English line → block" "$PLG_PREFIX_JA"
assert_not_leaked "PLG-T27b: synthetic secret from the compliant line is not echoed in stdout/stderr/reason" "$SYNTHETIC_SECRET"

# PLG-T28 (C1): on-disk artifact carries an UNRELATED English violation (line A) that
# the edit does not touch; the edit rewrites the Japanese line B with another compliant
# string → approve, and the PreToolUse gate must leave the file bytes untouched.
printf '%s\n%s\n' "$EN_PROSE" "$JA_PROSE" > "$DETAIL_UUID"
_t28_before="$(sha1sum "$DETAIL_UUID")"
run_gate "$PLAN_GATE" "$(mk_edit Edit "$DETAIL_UUID" "$JA_PROSE" "日本語に書き直した行B。")" "$CFG_PLAN_JA"
assert_approve "PLG-T28a: Edit touching only compliant line B, untouched English line A on disk → approve"
_t28_e0="$(mk_edit_elem - "" "$JA_PROSE" "日本語に書き直した行B。")"
_t28_e1="$(mk_edit_elem - "" "行B" "行B(追記)")"
run_gate "$PLAN_GATE" "$(mk_multiedit MultiEdit "$DETAIL_UUID" "$_t28_e0" "$_t28_e1")" "$CFG_PLAN_JA"
assert_approve "PLG-T28b: MultiEdit touching only compliant line B, untouched English line A on disk → approve"
_t28_after="$(sha1sum "$DETAIL_UUID")"
# Guarded on a real verdict: an absent gate trivially leaves bytes alone (no false green).
if [ -n "$GATE_STDOUT" ] && [ -n "$_t28_before" ] && [ "$_t28_before" = "$_t28_after" ]; then
    pass "PLG-T28c: artifact bytes unchanged after the gate ran (PreToolUse gate never writes)"
else
    fail "PLG-T28c: gate verdict missing or bytes changed — stdout='$GATE_STDOUT' before='$_t28_before' after='$_t28_after'"
fi
rm -f "$DETAIL_UUID"

# PLG-T29 (C2): `path` key at the top level (no file_path) → same gate path as file_path
run_gate "$PLAN_GATE" "$(mk_payload_pathkey editFiles path "$INTENT_UUID" content "$EN_PROSE")" "$CFG_PLAN_JA"
assert_block_prefix "PLG-T29: editFiles {path: <uuid>-intent.md, content: English} (no file_path) → block" "$PLG_PREFIX_JA"

# PLG-T30 (C5): sibling directory sharing the plans-dir prefix is NOT the plans dir
# (containment must be separator-aware, never a bare startsWith on the prefix).
SIBLING_PLANS_DIR="${PLANS_DIR}-other"
mkdir -p "$SIBLING_PLANS_DIR"
run_gate "$PLAN_GATE" "$(mk_payload Write "$SIBLING_PLANS_DIR/$FAKE_UUID-intent.md" content "$EN_PROSE")" "$CFG_PLAN_JA"
assert_approve "PLG-T30: English Write to <plans-dir>-other/<uuid>-intent.md → approve (prefix sibling is outside)"

# PLG-T31 (C4): compliant artifact on disk, violating Write submitted twice → identical
# block stdout both times, and the on-disk bytes never change (idempotent, read-only gate).
printf '%s\n' "$JA_PROSE" > "$OUTLINE_UUID"
_t31_before="$(sha1sum "$OUTLINE_UUID")"
_t31_payload="$(mk_payload Write "$OUTLINE_UUID" content "$EN_PROSE")"
run_gate "$PLAN_GATE" "$_t31_payload" "$CFG_PLAN_JA"
assert_block_prefix "PLG-T31a: first run — English Write over compliant <uuid>-outline.md → block" "$PLG_PREFIX_JA"
_t31_out1="$GATE_STDOUT"
run_gate "$PLAN_GATE" "$_t31_payload" "$CFG_PLAN_JA"
assert_block_prefix "PLG-T31b: second run (identical payload) → block" "$PLG_PREFIX_JA"
if [ -n "$GATE_STDOUT" ] && [ "$_t31_out1" = "$GATE_STDOUT" ]; then
    pass "PLG-T31c: both runs produced byte-identical stdout"
else
    fail "PLG-T31c: stdout differs or empty — run1='$_t31_out1' run2='$GATE_STDOUT'"
fi
_t31_after="$(sha1sum "$OUTLINE_UUID")"
if [ -n "$GATE_STDOUT" ] && [ -n "$_t31_before" ] && [ "$_t31_before" = "$_t31_after" ]; then
    pass "PLG-T31d: artifact bytes unchanged after two blocking runs"
else
    fail "PLG-T31d: gate verdict missing or bytes changed — stdout='$GATE_STDOUT' before='$_t31_before' after='$_t31_after'"
fi
rm -f "$OUTLINE_UUID"

# PLG-T32 (C8): degenerate compliant fragments — empty, single character, ~200KB Japanese → approve
run_gate "$PLAN_GATE" "$(mk_payload Write "$INTENT_TS" content "")" "$CFG_PLAN_JA"
assert_approve "PLG-T32a: Write with empty content → approve"
run_gate "$PLAN_GATE" "$(mk_payload Write "$INTENT_TS" content "あ")" "$CFG_PLAN_JA"
assert_approve "PLG-T32b: Write with single character 'あ' → approve"
# JA_PROSE + newline is ~60 bytes; 3500 repeats ≈ 200KB, built inside node (no argv transit).
run_gate "$PLAN_GATE" "$(mk_payload_big Write "$INTENT_TS" "$JA_PROSE"$'\n' 3500)" "$CFG_PLAN_JA"
assert_approve "PLG-T32c: Write with ~200KB Japanese-only content → approve (rc 0, no error)"
