#!/usr/bin/env bash
# tests/feature-2338-plan-lang-heading.sh
# Tests: hooks/lib/lint-plan-lang.js, hooks/check-plan-lang.js, hooks/gate-plan-lang.js, hooks/stop-confirm-plan-guard.js
# Tags: scope:issue-specific, TL1, TL2
# lang-check: ignore -- CJK heading fixtures are built inside node here.
# TL1 unit tests (B*) for the policy-INDEPENDENT canonical-heading check in
# lintPlanLang(content, policy, artifactType) (#2338), plus TL2 subprocess tests
# (C1*) spawning each enforcement hook (gate/check/stop-confirm) against a plan
# artifact carrying a localized H2 heading. The hooks propagate stage/artifactType
# into this same core (broader hook paths also covered by
# feature-2278-pretool-lang-gates.sh). RED until the check and 3rd arg exist.
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LINT="$AGENTS_ROOT/hooks/lib/lint-plan-lang.js"
PLAN_SCHEMA="$AGENTS_ROOT/hooks/lib/plan-schema.js"
if command -v cygpath >/dev/null 2>&1; then
    LINT_NODE="$(cygpath -m "$LINT")"
    PLAN_SCHEMA_NODE="$(cygpath -m "$PLAN_SCHEMA")"
else
    LINT_NODE="$LINT"
    PLAN_SCHEMA_NODE="$PLAN_SCHEMA"
fi
REASON="schema heading must use canonical English name"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

if [[ -f "$LINT" ]]; then
    pass "prereq: hooks/lib/lint-plan-lang.js exists"
else
    fail "prereq: hooks/lib/lint-plan-lang.js not found: $LINT"
fi

# B1: canonical English H2 under japanese policy -> no violation.
_b1="$(node -e "
const { lintPlanLang } = require('$LINT_NODE');
const v = lintPlanLang('## Adopted approach', 'japanese', 'outline');
if (v.length !== 0) { process.stderr.write('expected 0, got ' + v.length + ': ' + JSON.stringify(v) + '\n'); process.exit(1); }
" 2>&1)"
if [[ $? -eq 0 ]]; then pass "B1: canonical English H2 (japanese policy) -> no violation"; else fail "B1: $_b1"; fi

# B2: localized Japanese H2 (maps to a canonical name) under japanese policy -> schema violation.
_b2="$(node -e "
const { lintPlanLang } = require('$LINT_NODE');
const schema = require('$PLAN_SCHEMA_NODE');
const k = Object.keys(schema.LOCALIZED_TO_CANONICAL || {})[0];
if (!k) { process.stderr.write('no localized variant available in LOCALIZED_TO_CANONICAL\n'); process.exit(1); }
const v = lintPlanLang('## ' + k, 'japanese', 'outline');
if (!v.some(function (x) { return x.reason === '$REASON'; })) { process.stderr.write('expected reason, got ' + JSON.stringify(v) + '\n'); process.exit(1); }
" 2>&1)"
if [[ $? -eq 0 ]]; then pass "B2: localized Japanese H2 (japanese policy) -> schema-heading violation"; else fail "B2: $_b2"; fi

# B3: localized Japanese H2 under ENGLISH policy -> still a violation (policy-independent).
_b3="$(node -e "
const { lintPlanLang } = require('$LINT_NODE');
const schema = require('$PLAN_SCHEMA_NODE');
const k = Object.keys(schema.LOCALIZED_TO_CANONICAL || {})[0];
if (!k) { process.stderr.write('no localized variant available\n'); process.exit(1); }
const v = lintPlanLang('## ' + k, 'english', 'outline');
if (!v.some(function (x) { return x.reason === '$REASON'; })) { process.stderr.write('expected schema violation under english policy, got ' + JSON.stringify(v) + '\n'); process.exit(1); }
" 2>&1)"
if [[ $? -eq 0 ]]; then pass "B3: localized Japanese H2 (english policy) -> schema-heading violation (policy-independent)"; else fail "B3: $_b3"; fi

# B4: unknown H2 heading -> no violation (only known localized variants are flagged).
_b4="$(node -e "
const { lintPlanLang } = require('$LINT_NODE');
const v = lintPlanLang('## Some Custom Unknown Subsection', 'japanese', 'outline');
if (v.length !== 0) { process.stderr.write('expected 0 for unknown H2, got ' + JSON.stringify(v) + '\n'); process.exit(1); }
" 2>&1)"
if [[ $? -eq 0 ]]; then pass "B4: unknown H2 heading -> no violation"; else fail "B4: $_b4"; fi

# B5: an H3 heading (even a localized one) -> no violation (only H2 is checked).
_b5="$(node -e "
const { lintPlanLang } = require('$LINT_NODE');
const schema = require('$PLAN_SCHEMA_NODE');
const k = Object.keys(schema.LOCALIZED_TO_CANONICAL || {})[0];
if (!k) { process.stderr.write('no localized variant available\n'); process.exit(1); }
const v = lintPlanLang('### ' + k, 'japanese', 'outline');
if (v.length !== 0) { process.stderr.write('expected 0 for H3, got ' + JSON.stringify(v) + '\n'); process.exit(1); }
" 2>&1)"
if [[ $? -eq 0 ]]; then pass "B5: localized H3 heading -> no violation (H2-only check)"; else fail "B5: $_b5"; fi

# B6: no 3rd argument -> heading check skipped (backward compatibility).
_b6="$(node -e "
const { lintPlanLang } = require('$LINT_NODE');
const schema = require('$PLAN_SCHEMA_NODE');
const k = Object.keys(schema.LOCALIZED_TO_CANONICAL || {})[0];
if (!k) { process.stderr.write('no localized variant available\n'); process.exit(1); }
const v = lintPlanLang('## ' + k, 'japanese');
if (v.length !== 0) { process.stderr.write('expected 0 (no artifactType), got ' + JSON.stringify(v) + '\n'); process.exit(1); }
" 2>&1)"
if [[ $? -eq 0 ]]; then pass "B6: lintPlanLang(content, policy) with no 3rd arg -> no heading check"; else fail "B6: $_b6"; fi

# B7: classifier both verdicts — artifactType present blocks; absent skips.
_b7="$(node -e "
const { lintPlanLang } = require('$LINT_NODE');
const schema = require('$PLAN_SCHEMA_NODE');
const k = Object.keys(schema.LOCALIZED_TO_CANONICAL || {})[0];
if (!k) { process.stderr.write('no localized variant available\n'); process.exit(1); }
const content = '## ' + k;
const withType = lintPlanLang(content, 'japanese', 'outline');
const without = lintPlanLang(content, 'japanese');
if (!withType.some(function (x) { return x.reason === '$REASON'; })) { process.stderr.write('artifactType present should BLOCK, got ' + JSON.stringify(withType) + '\n'); process.exit(1); }
if (without.some(function (x) { return x.reason === '$REASON'; })) { process.stderr.write('artifactType absent should ALLOW, got ' + JSON.stringify(without) + '\n'); process.exit(1); }
" 2>&1)"
if [[ $? -eq 0 ]]; then pass "B7: classifier both verdicts — artifactType present blocks, absent skips"; else fail "B7: $_b7"; fi

# ============================================================================
# C1 (TL2): the three enforcement hooks propagate stage/artifactType into
# lintPlanLang, so a localized H2 heading in a plan artifact is blocked
# end-to-end — PreToolUse (gate), PostToolUse (check) and Stop (Layer 2 re-lint).
# Fixture-isolated per rules/test/fixture-isolation.md: PLANS_DIR + WORKFLOW_DIR
# pinned as a pair, session ids unset, neutral CWD, PLAN_LANG from a fixture .env
# only. CJK headings/bodies are built inside node (never through bash). RED until
# #2338 lands (today the hooks skip headings, so the localized H2 is not flagged).
# ============================================================================

GATE_HOOK="$AGENTS_ROOT/hooks/gate-plan-lang.js"
CHECK_HOOK="$AGENTS_ROOT/hooks/check-plan-lang.js"
STOP_HOOK="$AGENTS_ROOT/hooks/stop-confirm-plan-guard.js"

c1_to_node() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

C1_ROOT="$(mktemp -d)"
trap 'rm -rf "$C1_ROOT"' EXIT
mkdir -p "$C1_ROOT/plans" "$C1_ROOT/wf" "$C1_ROOT/cfg"
printf 'PLAN_LANG=japanese\n' > "$C1_ROOT/cfg/.env"

C1_ROOT_NODE="$(c1_to_node "$C1_ROOT")"
C1_PLANS_NODE="$(c1_to_node "$C1_ROOT/plans")"
C1_WF_NODE="$(c1_to_node "$C1_ROOT/wf")"
C1_CFG_NODE="$(c1_to_node "$C1_ROOT/cfg")"
GATE_HOOK_NODE="$(c1_to_node "$GATE_HOOK")"
CHECK_HOOK_NODE="$(c1_to_node "$CHECK_HOOK")"
STOP_HOOK_NODE="$(c1_to_node "$STOP_HOOK")"

c1_run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then timeout 30 "$@"; else perl -e 'alarm 30; exec @ARGV' -- "$@"; fi
}

# Build every fixture (localized H2 heading + Japanese body, payloads, transcript)
# inside a single node process so no CJK ever transits bash. Emits:
#   plans/<uuid>-outline.md          — artifact for the Stop re-lint
#   write-payload.json               — Write payload for gate/check hooks
#   stop-stdin.json / transcript     — Stop hook stdin + hand-built transcript
C1_SID="a1b2c3d4-e5f6-7890-abcd-ef1234560001"
C1_SID_OK="a1b2c3d4-e5f6-7890-abcd-ef1234560002"
_c1_build="$(node -e "
const fs = require('fs');
const path = require('path');
const schema = require('$PLAN_SCHEMA_NODE');
const k = Object.keys(schema.LOCALIZED_TO_CANONICAL || {})[0];
if (!k) { process.stderr.write('no localized variant available in LOCALIZED_TO_CANONICAL\n'); process.exit(1); }
// Canonical English name the localized key maps to — the ALLOW-path heading.
const canonical = schema.LOCALIZED_TO_CANONICAL[k];
if (!canonical) { process.stderr.write('no canonical target for the first localized key\n'); process.exit(1); }
const jaBody = 'この計画書は日本語の本文で書かれています。';
const plans = '$C1_PLANS_NODE';
const root = '$C1_ROOT_NODE';
const sid = '$C1_SID';
const sidOk = '$C1_SID_OK';
const buildFixture = function (theSid, headingName) {
  const artifact = plans + '/' + theSid + '-outline.md';
  const doc = '# 計画\n\n## ' + headingName + '\n\n' + jaBody + '\n';
  fs.writeFileSync(artifact, doc);
  const transcript = JSON.stringify({ type: 'assistant', message: { content: [
    { type: 'tool_use', name: 'Bash', input: { command: 'echo \"<<WORKFLOW_CONFIRM_OUTLINE: ok>>\"' } },
    { type: 'tool_use', name: 'Skill', input: { skill: 'make-detail-plan' } }
  ] } }) + '\n';
  const tpath = plans + '/' + theSid + '.jsonl';
  fs.writeFileSync(tpath, transcript);
  return { artifact: artifact, doc: doc, tpath: tpath };
};
// BLOCK fixture: localized (Japanese) canonical H2 heading — the heading is the
// ONLY schema violation the hooks should surface (body is compliant Japanese).
const blk = buildFixture(sid, k);
fs.writeFileSync(root + '/write-payload.json', JSON.stringify({ tool_name: 'Write', tool_input: { file_path: blk.artifact, content: blk.doc } }));
fs.writeFileSync(root + '/stop-stdin.json', JSON.stringify({ session_id: sid, transcript_path: blk.tpath }));
// ALLOW fixture: the SAME body but a canonical English H2 heading. Under
// PLAN_LANG=japanese the English canonical heading is required (schema), and the
// Japanese body is policy-compliant, so no hook should flag anything.
const ok = buildFixture(sidOk, canonical);
fs.writeFileSync(root + '/write-payload-ok.json', JSON.stringify({ tool_name: 'Write', tool_input: { file_path: ok.artifact, content: ok.doc } }));
fs.writeFileSync(root + '/stop-stdin-ok.json', JSON.stringify({ session_id: sidOk, transcript_path: ok.tpath }));
" 2>&1)"
if [[ $? -ne 0 ]]; then
    fail "C1 prereq: fixture build failed: $_c1_build"
else
    # c1_run_hook <hook_node> <stdin_file> — runs a Pre/PostToolUse hook with the
    # fixture env pinned and every inherited policy key / session id removed.
    # Captures stdout to a file (CJK-safe) and the exit code.
    c1_run_hook() {
        C1_HOOK_OUT="$C1_ROOT/hook-out.json"
        (
            cd "$C1_ROOT" || exit 97
            unset PLAN_LANG DOCS_LANG_PUBLIC DOCS_LANG_PRIVATE
            unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_PROJECT_DIR
            export AGENTS_CONFIG_DIR="$C1_CFG_NODE"
            export WORKFLOW_PLANS_DIR="$C1_PLANS_NODE"
            export CLAUDE_WORKFLOW_DIR="$C1_WF_NODE"
            c1_run_with_timeout node "$1" < "$2" > "$C1_HOOK_OUT" 2>/dev/null
        )
        C1_HOOK_RC=$?
    }
    # c1_is_block <stdout_file> — prints 1 when the JSON decision is "block".
    c1_is_block() {
        node -e 'const fs=require("fs");try{const o=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));process.stdout.write(o.decision==="block"?"1":"0");}catch(e){process.stdout.write("0");}' "$1" 2>/dev/null
    }
    # c1_is_valid_json <file> — prints 1 when the file contains valid JSON, 0 otherwise.
    c1_is_valid_json() {
        node -e 'const fs=require("fs");try{JSON.parse(fs.readFileSync(process.argv[1],"utf8"));process.stdout.write("1");}catch(e){process.stdout.write("0");}' "$1" 2>/dev/null
    }

    # C1a: PreToolUse gate blocks the localized-heading Write fragment.
    c1_run_hook "$GATE_HOOK_NODE" "$C1_ROOT/write-payload.json"
    if [[ "$(c1_is_block "$C1_HOOK_OUT")" == "1" ]]; then
        pass "C1a: gate-plan-lang.js blocks a localized H2 heading (PreToolUse, artifactType propagated)"
    else
        fail "C1a: gate-plan-lang.js did not block the localized H2 heading (rc=$C1_HOOK_RC out=$(cat "$C1_HOOK_OUT" 2>/dev/null))"
    fi

    # C1b: PostToolUse checker blocks the same localized-heading content.
    c1_run_hook "$CHECK_HOOK_NODE" "$C1_ROOT/write-payload.json"
    if [[ "$(c1_is_block "$C1_HOOK_OUT")" == "1" ]]; then
        pass "C1b: check-plan-lang.js blocks a localized H2 heading (PostToolUse, artifactType propagated)"
    else
        fail "C1b: check-plan-lang.js did not block the localized H2 heading (rc=$C1_HOOK_RC out=$(cat "$C1_HOOK_OUT" 2>/dev/null))"
    fi

    # C1c: Stop guard Layer 2 re-lints the CONFIRMed outline artifact and blocks
    # (exit 2 + decision block) on the localized heading, even with a valid
    # follow-up skill present — the body is compliant Japanese, so the heading is
    # the sole trigger.
    c1_run_hook "$STOP_HOOK_NODE" "$C1_ROOT/stop-stdin.json"
    if [[ "$C1_HOOK_RC" -eq 2 && "$(c1_is_block "$C1_HOOK_OUT")" == "1" ]]; then
        pass "C1c: stop-confirm-plan-guard.js Layer 2 blocks a localized H2 heading in the outline artifact (exit 2)"
    else
        fail "C1c: stop guard did not block the localized H2 heading (rc=$C1_HOOK_RC out=$(cat "$C1_HOOK_OUT" 2>/dev/null))"
    fi

    # ------------------------------------------------------------------------
    # C1 ALLOW verdict (subprocess) — the same three hooks must PASS a plan whose
    # H2 is the canonical English name (with the identical compliant Japanese
    # body). Classifier "both verdicts" at the hook boundary: a canonical heading
    # is never flagged, so gate/check emit no block and the Stop guard exits 0.
    # This is GREEN on current source (today the hooks never flag a canonical
    # English heading), so it also proves the block subtests above are not
    # false-positives from an always-block hook.
    # ------------------------------------------------------------------------

    # C1d: PreToolUse gate allows a canonical English H2 Write fragment (no block, valid JSON output).
    c1_run_hook "$GATE_HOOK_NODE" "$C1_ROOT/write-payload-ok.json"
    if [[ "$(c1_is_valid_json "$C1_HOOK_OUT")" == "1" && "$(c1_is_block "$C1_HOOK_OUT")" == "0" ]]; then
        pass "C1d: gate-plan-lang.js allows a canonical English H2 heading (PreToolUse, valid JSON, no block)"
    else
        fail "C1d: gate-plan-lang.js did not allow the canonical English H2 heading (rc=$C1_HOOK_RC valid_json=$(c1_is_valid_json "$C1_HOOK_OUT") block=$(c1_is_block "$C1_HOOK_OUT") out=$(cat "$C1_HOOK_OUT" 2>/dev/null))"
    fi

    # C1e: PostToolUse checker allows the same canonical-heading content (no block, valid JSON output).
    c1_run_hook "$CHECK_HOOK_NODE" "$C1_ROOT/write-payload-ok.json"
    if [[ "$(c1_is_valid_json "$C1_HOOK_OUT")" == "1" && "$(c1_is_block "$C1_HOOK_OUT")" == "0" ]]; then
        pass "C1e: check-plan-lang.js allows a canonical English H2 heading (PostToolUse, valid JSON, no block)"
    else
        fail "C1e: check-plan-lang.js did not allow the canonical English H2 heading (rc=$C1_HOOK_RC valid_json=$(c1_is_valid_json "$C1_HOOK_OUT") block=$(c1_is_block "$C1_HOOK_OUT") out=$(cat "$C1_HOOK_OUT" 2>/dev/null))"
    fi

    # C1f: Stop guard Layer 2 allows a canonical-heading outline artifact: exit 0
    # and no block decision. The stop guard emits no output (not JSON) when it
    # allows; c1_is_block handles empty output safely (returns "0" via catch).
    c1_run_hook "$STOP_HOOK_NODE" "$C1_ROOT/stop-stdin-ok.json"
    if [[ "$C1_HOOK_RC" -eq 0 && "$(c1_is_block "$C1_HOOK_OUT")" == "0" ]]; then
        pass "C1f: stop-confirm-plan-guard.js Layer 2 allows a canonical English H2 heading (exit 0, no block)"
    else
        fail "C1f: stop guard did not allow the canonical English H2 heading (rc=$C1_HOOK_RC block=$(c1_is_block "$C1_HOOK_OUT") out=$(cat "$C1_HOOK_OUT" 2>/dev/null))"
    fi
fi

# B8: table-driven — every LOCALIZED_TO_CANONICAL entry blocked under EVERY artifact type.
# This proves the check is not table-of-first-entry-only, and applies to all artifact types.
_b8="$(node -e "
const { lintPlanLang } = require('$LINT_NODE');
const schema = require('$PLAN_SCHEMA_NODE');
const map = schema.LOCALIZED_TO_CANONICAL || {};
const keys = Object.keys(map);
if (keys.length === 0) { process.stderr.write('LOCALIZED_TO_CANONICAL is empty\n'); process.exit(1); }
const types = ['intent', 'outline', 'detail'];
const bad = [];
keys.forEach(function (k) {
  types.forEach(function (t) {
    const v = lintPlanLang('## ' + k, 'japanese', t);
    if (!v.some(function (x) { return x.reason.indexOf('canonical') !== -1 || x.reason.indexOf('schema') !== -1; })) {
      bad.push(JSON.stringify(k) + ' / ' + t + ' -> no schema-heading violation (got ' + JSON.stringify(v) + ')');
    }
  });
});
if (bad.length !== 0) { process.stderr.write('missing schema-heading violations (' + keys.length + ' entries x 3 types):\n' + bad.join('\n') + '\n'); process.exit(1); }
process.stdout.write('checked ' + (keys.length * 3) + ' combos (' + keys.length + ' entries x 3 types)\n');
" 2>&1)"
if [[ $? -eq 0 ]]; then pass "B8: every localized entry blocked for intent/outline/detail artifact types ($_b8)"; else fail "B8: $_b8"; fi

# B9: policy-path test — lintPlanLang with policy='any' and no artifactType skips
# the heading check. When PLAN_LANG is unset (maps to 'any'/'noop') and the hook
# does not pass an artifactType, no heading violation is emitted. This is distinct
# from B6 which uses policy='japanese': B9 proves the skip holds under the explicit
# 'any' policy (the unset-PLAN_LANG fast-path).
_b9="$(node -e "
const { lintPlanLang } = require('$LINT_NODE');
const schema = require('$PLAN_SCHEMA_NODE');
const k = Object.keys(schema.LOCALIZED_TO_CANONICAL || {})[0];
if (!k) { process.stderr.write('no localized variant available\n'); process.exit(1); }
const v = lintPlanLang('## ' + k, 'any');
if (v.some(function (x) { return x.reason && x.reason.indexOf('canonical') !== -1; })) {
  process.stderr.write('policy=any with no artifactType should skip heading check, got ' + JSON.stringify(v) + '\n'); process.exit(1);
}
" 2>&1)"
if [[ $? -eq 0 ]]; then pass "B9: lintPlanLang with policy='any' and no artifactType -> no schema-heading violation (unset-PLAN_LANG fast-path)"; else fail "B9: $_b9"; fi

TOTAL=$((PASS + FAIL))
echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
