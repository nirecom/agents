#!/usr/bin/env bash
# tests/hooks/feature-2400-null-freshness-predicate.sh
# Tests: hooks/lib/null-freshness.js, hooks/workflow-gate/user-verified-audit.js, hooks/supervisor-guard/audit-arm.js, hooks/workflow-gate/supervisor-check.js
# Tags: supervisor, null-freshness, predicate, TL1, scope:issue-specific
# #2400 — decision table of the shared null-freshness predicate (rows 1-9 and 5a), its
# refusal wording, the moved filterNullKeySubChecks, and an SSOT guard that both
# gates import the lib instead of keeping private copies. Each case satisfies every
# row above the one it targets, so a refusal can only come from the targeted row.
# Gate wiring (real hook process) is covered by the TL2 sections under
# tests/hooks/feature-2256-tr5-user-verified-hold/.

set -uo pipefail
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }

TMPD="$(make_tmp)"
trap 'rm -rf "$TMPD"' EXIT
harness_isolate "$TMPD"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
cd "$TMPD" || exit 1

LIB_NODE="$(np "$AGENTS_DIR")/hooks/lib/null-freshness.js"
DRV="$(np "$TMPD")/pred.js"
UVA="$AGENTS_DIR/hooks/workflow-gate/user-verified-audit.js"
ARM="$AGENTS_DIR/hooks/supervisor-guard/audit-arm.js"
SUPC="$AGENTS_DIR/hooks/workflow-gate/supervisor-check.js"

# pred.js <mode> — PIN (env) is a case spec over a fully-passing baseline:
# kind artifact|code, freshness (verbatim override), fSet/fDel, runNull, runSet/runDel
# (dotted paths), later, unsettled (key omitted when absent). Prints one flat line.
cat > "$TMPD/pred.js" << 'JSEOF'
"use strict";
let lib;
try { lib = require(process.env.LIB); } catch (e) {
  process.stdout.write("error=" + String(e && e.message).split("\n")[0]);
  process.exit(0);
}
const spec = JSON.parse(process.env.PIN || "{}");
const AK = { intent: "h-intent", outline: null, detail: "h-detail" };
const setPath = (o, p, v) => { const k = p.split("."); let t = o; for (const s of k.slice(0, -1)) t = t[s]; t[k[k.length - 1]] = v; };
const delPath = (o, p) => { const k = p.split("."); let t = o; for (const s of k.slice(0, -1)) t = t[s]; delete t[k[k.length - 1]]; };
function build() {
  let freshness = { freshness_key: null, input_version: spec.kind === "code" ? null : "iv-current", artifact_keys: Object.assign({}, AK) };
  if ("freshness" in spec) freshness = spec.freshness;
  for (const [p, v] of Object.entries(spec.fSet || {})) setPath(freshness, p, v);
  for (const p of spec.fDel || []) delPath(freshness, p);
  let run = { id: "run-0011", outcome: "terminal", tr_ids: ["TR5"], verdict: "CONTINUE", freshness_key: null,
    trigger_input_keys: { TR5: "iv-current" }, artifact_keys: Object.assign({}, AK) };
  for (const [p, v] of Object.entries(spec.runSet || {})) setPath(run, p, v);
  for (const p of spec.runDel || []) delPath(run, p);
  if (spec.runNull) run = null;
  const args = { freshness, tr5Run: run, laterBlockExists: spec.later === true };
  if (spec.unsettled !== undefined) args.unsettledRun = spec.unsettled;
  return args;
}
const mode = process.argv[2];
let out;
try {
if (mode === "eval") {
  const r = lib.evaluateNullFreshnessRecovery(build());
  out = `approve=${r.approve};kind=${r.kind};refusal=${r.refusal};moved=${(r.moved || []).join(",")}`;
} else if (mode === "describe") {
  out = lib.describeNullFreshnessRefusal(lib.evaluateNullFreshnessRecovery(build()));
} else if (mode === "classify") {
  out = String(lib.classifyNullFreshness(build().freshness));
} else if (mode === "filter") {
  out = lib.filterNullKeySubChecks(spec.ids, spec.freshness).join(",");
} else if (mode === "ivm") {
  const b = build();
  out = String(lib.inputVersionMatches(b.tr5Run, b.freshness.input_version));
} else if (mode === "frozen") {
  out = `${Object.isFrozen(lib.NULL_KIND)},${Object.isFrozen(lib.REFUSAL)}`;
} else if (mode === "evalu") {
  const r = lib.evaluateNullFreshnessRecovery(build());
  out = `refusal=${r.refusal};unreadable=${JSON.stringify(r.unreadable)}`;
} else if (mode === "unsettled") {
  const r = lib.unsettledAuditRun(spec.audit);
  out = r === null ? "null" : `${r.id}/${r.phase}`;
} else if (mode === "unreadable") {
  out = (spec.freshness === "__UNDEF__" ? lib.unreadableArtifacts() : lib.unreadableArtifacts(spec.freshness)).join(",");
}
} catch (e) { out = "error=" + String(e && e.message).split("\n")[0]; }
process.stdout.write(String(out));
JSEOF

pred() { PIN="$2" LIB="$LIB_NODE" run_with_timeout 60 node "$DRV" "$1" 2>&1; }
check() { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1" "want=$2 got=$3"; fi; }
check_match() { if printf '%s' "$3" | grep -Eq "$2"; then pass "$1"; else fail "$1" "/$2/ not in: $3"; fi; }
REQ_LIB_RE="require\\([\"']\\.\\./lib/null-freshness[\"']\\)"
file_has() { if grep -Eq "$2" "$3"; then pass "$1"; else fail "$1" "/$2/ not in $3"; fi; }
file_lacks() { if [ -f "$3" ] && ! grep -Eq "$2" "$3"; then pass "$1"; else fail "$1" "/$2/ found in (or missing) $3"; fi; }

# Premise guard: the driver's error channel is distinguishable from a verdict.
case_begin "module-loads" "hooks/lib/null-freshness.js"
check_match "module-loads: the predicate module resolves" '^approve=' "$(pred eval '{}')"
case_end

case_begin "row1-row2-classification" "hooks/lib/null-freshness.js"
check "P1: a non-null freshness_key is refused as not-null (caller misuse)" \
    "approve=false;kind=not-null;refusal=not-null;moved=" "$(pred eval '{"fSet":{"freshness_key":"fk-abc"}}')"
check "P2: a null freshness object is unavailable" \
    "approve=false;kind=unavailable;refusal=freshness-unavailable;moved=" "$(pred eval '{"freshness":null}')"
check "P3: a missing artifact_keys map is unavailable" \
    "approve=false;kind=unavailable;refusal=freshness-unavailable;moved=" "$(pred eval '{"fDel":["artifact_keys"]}')"
check "P3b: an array artifact_keys is unavailable" \
    "approve=false;kind=unavailable;refusal=freshness-unavailable;moved=" "$(pred eval '{"fSet":{"artifact_keys":[]}}')"
check "C1: classify — artifact side when input_version is a non-empty string" "artifact-side" "$(pred classify '{}')"
check "C2: classify — code side when input_version is null" "code-side" "$(pred classify '{"kind":"code"}')"
check "C3: classify — empty-string input_version counts as code side" "code-side" "$(pred classify '{"fSet":{"input_version":""}}')"
check "C4: NULL_KIND and REFUSAL are frozen" "true,true" "$(pred frozen '{}')"
case_end

case_begin "row3-no-tr5-run" "hooks/lib/null-freshness.js"
check "P4: no TR5 run is refused" \
    "approve=false;kind=artifact-side;refusal=no-tr5-run;moved=" "$(pred eval '{"runNull":true}')"
case_end

case_begin "row4-verdict-allow-list" "hooks/lib/null-freshness.js"
for v in WARN BLOCK OK; do
    check "P5: verdict $v is outside the CONTINUE-only allow-list" \
        "approve=false;kind=artifact-side;refusal=verdict-not-allowed;moved=" "$(pred eval "{\"runSet\":{\"verdict\":\"$v\"}}")"
done
check "P5c: a missing verdict is outside the allow-list" \
    "approve=false;kind=artifact-side;refusal=verdict-not-allowed;moved=" "$(pred eval '{"runDel":["verdict"]}')"
check "P5e: code side — WARN is refused too" \
    "approve=false;kind=code-side;refusal=verdict-not-allowed;moved=" "$(pred eval '{"kind":"code","runSet":{"verdict":"WARN"}}')"
case_end

case_begin "row5-later-block" "hooks/lib/null-freshness.js"
check "P6: a later BLOCK refuses an otherwise certifiable run" \
    "approve=false;kind=artifact-side;refusal=later-block;moved=" "$(pred eval '{"later":true}')"
check "P6b: code side — a later BLOCK refuses too" \
    "approve=false;kind=code-side;refusal=later-block;moved=" "$(pred eval '{"kind":"code","later":true}')"
case_end

case_begin "row6-artifact-breakdown-fail-closed" "hooks/lib/null-freshness.js"
NB="approve=false;kind=artifact-side;refusal=no-artifact-breakdown;moved="
check "P7a: a run without artifact_keys (legacy / minimal seed)" "$NB" "$(pred eval '{"runDel":["artifact_keys"]}')"
check "P7b: a partial breakdown (detail property missing)" "$NB" "$(pred eval '{"runDel":["artifact_keys.detail"]}')"
check "P7c: a numeric stored hash" "$NB" "$(pred eval '{"runSet":{"artifact_keys.detail":42}}')"
check "P7d: an empty-string stored hash" "$NB" "$(pred eval '{"runSet":{"artifact_keys.detail":""}}')"
check "P7e: an array artifact_keys" "$NB" "$(pred eval '{"runSet":{"artifact_keys":[]}}')"
check "P7f: a null artifact_keys" "$NB" "$(pred eval '{"runSet":{"artifact_keys":null}}')"
check "P7g: code side — a legacy run is fail-closed too" \
    "approve=false;kind=code-side;refusal=no-artifact-breakdown;moved=" "$(pred eval '{"kind":"code","runDel":["artifact_keys"]}')"
case_end

case_begin "row7-trigger-key-no-fallback" "hooks/lib/null-freshness.js"
NT="approve=false;kind=artifact-side;refusal=no-trigger-key;moved="
check "P8a: trigger_input_keys absent" "$NT" "$(pred eval '{"runDel":["trigger_input_keys"]}')"
check "P8b: trigger_input_keys.TR5 null" "$NT" "$(pred eval '{"runSet":{"trigger_input_keys.TR5":null}}')"
check "P8c: trigger_input_keys.TR5 numeric" "$NT" "$(pred eval '{"runSet":{"trigger_input_keys.TR5":42}}')"
check "P8d: run.input_version matching but no trigger key — no fallback" "$NT" \
    "$(pred eval '{"runDel":["trigger_input_keys"],"runSet":{"input_version":"iv-current"}}')"
check "P8e: inputVersionMatches does not fall back to run.input_version" "false" \
    "$(pred ivm '{"runDel":["trigger_input_keys"],"runSet":{"input_version":"iv-current"}}')"
check "P8f: inputVersionMatches is true on an exact trigger key" "true" "$(pred ivm '{}')"
case_end

case_begin "row8-inputs-moved" "hooks/lib/null-freshness.js"
check "P9: a stale trigger key moves the code diff" \
    "approve=false;kind=artifact-side;refusal=inputs-moved;moved=code diff (input_version)" \
    "$(pred eval '{"runSet":{"trigger_input_keys.TR5":"iv-old"}}')"
check "P10a: intent changed since the TR5 run" \
    "approve=false;kind=artifact-side;refusal=inputs-moved;moved=intent" "$(pred eval '{"fSet":{"artifact_keys.intent":"h-intent-2"}}')"
check "P10b: detail changed since the TR5 run" \
    "approve=false;kind=artifact-side;refusal=inputs-moved;moved=detail" "$(pred eval '{"fSet":{"artifact_keys.detail":"h-detail-2"}}')"
check "P10c: outline absent at TR5, present now" \
    "approve=false;kind=artifact-side;refusal=inputs-moved;moved=outline" "$(pred eval '{"fSet":{"artifact_keys.outline":"h-outline"}}')"
check "P10d: outline present at TR5, absent now" \
    "approve=false;kind=artifact-side;refusal=inputs-moved;moved=outline" "$(pred eval '{"runSet":{"artifact_keys.outline":"h-outline"}}')"
check "P10e: code diff and an artifact moved together are both named, code first" \
    "approve=false;kind=artifact-side;refusal=inputs-moved;moved=code diff (input_version),intent" \
    "$(pred eval '{"runSet":{"trigger_input_keys.TR5":"iv-old"},"fSet":{"artifact_keys.intent":"h-intent-2"}}')"
check "P13: code side — a detail edit is caught by the artifact match" \
    "approve=false;kind=code-side;refusal=inputs-moved;moved=detail" \
    "$(pred eval '{"kind":"code","fSet":{"artifact_keys.detail":"h-detail-2"}}')"
case_end

case_begin "row9-approve" "hooks/lib/null-freshness.js"
check "P11: artifact side, everything unchanged (outline null on both sides) approves" \
    "approve=true;kind=artifact-side;refusal=null;moved=" "$(pred eval '{}')"
check "P11b: a current map without the outline key reads as null and still matches" \
    "approve=true;kind=artifact-side;refusal=null;moved=" "$(pred eval '{"fDel":["artifact_keys.outline"]}')"
check "P12: code side approves without any trigger key" \
    "approve=true;kind=code-side;refusal=null;moved=" "$(pred eval '{"kind":"code","runDel":["trigger_input_keys"]}')"
case_end

case_begin "refusal-wording" "hooks/lib/null-freshness.js"
d_moved="$(pred describe '{"fSet":{"artifact_keys.intent":"h-intent-2"}}')"
check_match "P14a: INPUTS_MOVED names the null kind and the moved artifact" \
    '^the freshness key is null \(a plan artifact is missing\) and inputs moved since the TR5 verdict — changed: intent\.$' "$d_moved"
check_match "P14b: VERDICT_NOT_ALLOWED names the verdict and the allow-list" \
    'null \(a plan artifact is missing\).*last TR5 verdict \(WARN\) is not in the null-freshness allow-list \(CONTINUE\) \(fail-closed\)\.$' \
    "$(pred describe '{"runSet":{"verdict":"WARN"}}')"
check "P14c: UNAVAILABLE keeps the pre-existing wording verbatim" \
    "the freshness key could not be computed for this working tree (fail-closed)." "$(pred describe '{"freshness":null}')"
check_match "P14d: code-side label and LATER_BLOCK wording" \
    '^the freshness key is null \(code side uncomputable: input_version is null\) and a later audit BLOCK verdict \(post-TR5\) is unresolved\.$' \
    "$(pred describe '{"kind":"code","later":true}')"
check_match "P14e: NO_ARTIFACT_BREAKDOWN wording" 'recorded no per-artifact hashes to compare \(fail-closed\)\.$' \
    "$(pred describe '{"runDel":["artifact_keys"]}')"
check_match "P14f: NO_TRIGGER_KEY wording" 'recorded no trigger key to compare the code diff against \(fail-closed\)\.$' \
    "$(pred describe '{"runDel":["trigger_input_keys"]}')"
check_match "P14g: the missing-verdict case renders as none" 'last TR5 verdict \(none\)' \
    "$(pred describe '{"runDel":["verdict"]}')"
case_end

case_begin "filter-null-key-sub-checks" "hooks/lib/null-freshness.js"
check "P15a: a null freshness_key drops recurrence-patterns" "detail-code,scope-drift" \
    "$(pred filter '{"ids":["recurrence-patterns","detail-code","scope-drift"],"freshness":{"freshness_key":null,"input_version":null,"artifact_keys":{}}}')"
check "P15b: a non-null freshness_key returns the input unchanged" "recurrence-patterns,detail-code" \
    "$(pred filter '{"ids":["recurrence-patterns","detail-code"],"freshness":{"freshness_key":"fk-abc"}}')"
check "P15c: a null freshness object returns the input unchanged" "recurrence-patterns,detail-code" \
    "$(pred filter '{"ids":["recurrence-patterns","detail-code"],"freshness":null}')"
case_end

case_begin "row5a-newer-audit-unsettled" "hooks/lib/null-freshness.js"
NU="approve=false;kind=artifact-side;refusal=newer-audit-unsettled;moved="
for ph in pending in_progress frozen; do
    check "P17: artifact side — an unsettled $ph run refuses" "$NU" "$(pred eval "{\"unsettled\":{\"id\":\"run-0012\",\"phase\":\"$ph\"}}")"
done
check "P17d: code side — an unsettled pending run refuses too" \
    "approve=false;kind=code-side;refusal=newer-audit-unsettled;moved=" \
    "$(pred eval '{"kind":"code","unsettled":{"id":"run-0012","phase":"pending"}}')"
check "P17e: a later BLOCK is reported before an unsettled run (row 5 precedes 5a)" \
    "approve=false;kind=artifact-side;refusal=later-block;moved=" \
    "$(pred eval '{"later":true,"unsettled":{"id":"run-0012","phase":"pending"}}')"
check "P17f: an unsettled run is reported before a moved artifact (5a precedes 6-8)" "$NU" \
    "$(pred eval '{"unsettled":{"id":"run-0012","phase":"pending"},"fSet":{"artifact_keys.detail":"h-detail-2"}}')"
check "P17g: an omitted unsettledRun key defaults to none (baseline still approves)" \
    "approve=true;kind=artifact-side;refusal=null;moved=" "$(pred eval '{}')"
case_end

case_begin "unsettled-audit-run-helper" "hooks/lib/null-freshness.js"
for ph in pending in_progress frozen; do
    check "P18: unsettledAuditRun — $ph slot yields the run" "run-0012/$ph" \
        "$(pred unsettled "{\"audit\":{\"audit_phase\":\"$ph\",\"audit_run_id\":\"run-0012\"}}")"
done
check "P18d: a done slot is settled" "null" "$(pred unsettled '{"audit":{"audit_phase":"done","audit_run_id":"run-0012"}}')"
check "P18e: a null phase is settled" "null" "$(pred unsettled '{"audit":{"audit_phase":null,"audit_run_id":"run-0012"}}')"
check "P18f: an undefined audit is settled" "null" "$(pred unsettled '{}')"
check "P18g: a pending slot without an id still refuses (id null)" "null/pending" "$(pred unsettled '{"audit":{"audit_phase":"pending"}}')"
case_end

case_begin "unsettled-refusal-wording" "hooks/lib/null-freshness.js"
d_pend="$(pred describe '{"unsettled":{"id":"run-0012","phase":"pending"}}')"
check_match "P19a: pending names the run, phase, and missing verdict" 'newer audit run \(run-0012, pending\) has no verdict yet' "$d_pend"
check_match "P19a2: pending points at the audit agent for that run" 'Run agents/supervisor-audit\.md for run-0012, then retry\.' "$d_pend"
if printf '%s' "$d_pend" | grep -q 'USER_VERIFIED'; then fail "P19a3: pending does not suggest the sentinel" "$d_pend"; else pass "P19a3: pending does not suggest the sentinel"; fi
d_frz="$(pred describe '{"unsettled":{"id":"run-0012","phase":"frozen"}}')"
check_match "P19b: frozen points at re-issuing the USER_VERIFIED sentinel" 'USER_VERIFIED' "$d_frz"
if printf '%s' "$d_frz" | grep -q 'supervisor-audit\.md'; then fail "P19b2: frozen does not suggest the audit agent" "$d_frz"; else pass "P19b2: frozen does not suggest the audit agent"; fi
case_end

case_begin "unreadable-artifacts" "hooks/lib/null-freshness.js"
UNR='{"freshness":{"freshness_key":null,"input_version":"iv","artifact_keys":null,"unreadable_artifacts":["detail"]}}'
UNAVAIL_TXT="the freshness key could not be computed for this working tree (fail-closed)."
check "P20a: an unreadable artifact classifies as unavailable" "unavailable" "$(pred classify "$UNR")"
d_unr="$(pred describe "$UNR")"
check_match "P20b: the refusal names the unreadable artifact" 'detail.*could not be read' "$d_unr"
if [ "$d_unr" != "$UNAVAIL_TXT" ]; then pass "P20b2: the unreadable wording differs from the generic one"; else fail "P20b2: the unreadable wording differs from the generic one" "$d_unr"; fi
check "P20c: no unreadable_artifacts field yields none" "" "$(pred unreadable '{"freshness":{"freshness_key":null}}')"
check "P20c2: only string entries are kept" "detail" "$(pred unreadable '{"freshness":{"unreadable_artifacts":["detail",42]}}')"
check "P20d: a null freshness yields none" "" "$(pred unreadable '{"freshness":null}')"
check "P20d2: an undefined freshness yields none" "" "$(pred unreadable '{"freshness":"__UNDEF__"}')"
check "P20d3: a null freshness evaluates unavailable with an empty unreadable list" \
    "refusal=freshness-unavailable;unreadable=[]" "$(pred evalu '{"freshness":null}')"
check "P20d4: a null freshness keeps the generic wording" "$UNAVAIL_TXT" "$(pred describe '{"freshness":null}')"
case_end

# P16 SSOT guard: no gate keeps a private copy of the policy.
case_begin "ssot-user-verified-audit" "hooks/workflow-gate/user-verified-audit.js"
file_lacks "P16a: user-verified-audit.js defines no private filterNullKeySubChecks / inputVersionMatches" '^[[:space:]]*function (filterNullKeySubChecks|inputVersionMatches)\b' "$UVA"
file_has "P16b: user-verified-audit.js requires the shared lib" "$REQ_LIB_RE" "$UVA"
file_has "P16f: user-verified-audit.js passes the unsettled audit run to the predicate" 'unsettledAuditRun\(' "$UVA"
file_has "P16g: user-verified-audit.js holds on unreadable artifacts" 'unreadableArtifacts\(' "$UVA"
case_end

case_begin "ssot-audit-arm" "hooks/supervisor-guard/audit-arm.js"
file_lacks "P16c: audit-arm.js defines no private filterNullKeySubChecks" '^[[:space:]]*function filterNullKeySubChecks\b' "$ARM"
file_has "P16d: audit-arm.js requires the shared lib" "$REQ_LIB_RE" "$ARM"
file_has "P16h: audit-arm.js reads the unsettled phase set from the schema" 'UNSETTLED_AUDIT_PHASES' "$ARM"
file_lacks "P16i: audit-arm.js keeps no literal unsettled-phase enumeration" '"frozen"\) return null' "$ARM"
case_end

case_begin "ssot-supervisor-check" "hooks/workflow-gate/supervisor-check.js"
file_has "P16e: supervisor-check.js requires the shared lib" "$REQ_LIB_RE" "$SUPC"
file_has "P16j: supervisor-check.js passes the unsettled audit run to the predicate" 'unsettledAuditRun\(' "$SUPC"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
