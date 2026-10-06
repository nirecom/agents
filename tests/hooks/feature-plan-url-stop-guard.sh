#!/usr/bin/env bash
# tests/hooks/feature-plan-url-stop-guard.sh
# Tests: hooks/stop-confirm-plan-guard.js, hooks/lib/plan-link-turn-check.js
# Tags: plan, hook, stop, confirm-plan, plan-url, plan-link, plan-sync, blob-url, fail-open, TL2, scope:common, path-leak
# Layer 3 of the confirm-plan Stop guard: a turn that wrote a plan artifact (turn marker) or
# CONFIRMed a plan stage must show that stage's blob URL somewhere in the turn's assistant
# text. Runs after Layers 1/2, never names the URL in its reason (points at bin/plan-link),
# and fails open whenever no URL exists (unpublished, plan-sync off, any error).
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"
# shellcheck source=../lib/plan-sync-fixture.sh
. "$AGENTS_DIR/tests/lib/plan-sync-fixture.sh"

# TL3 gap (hook-registration): the hook runs on synthetic stdin and hand-built transcripts.
# Real Stop dispatch and whether a Layer 3 block keeps a live session going are covered only
# for the unpublished fail-open path (tests/hooks/TL3-hook-stop-confirm-plan-guard/main.sh).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration.

psf_setup || { fail "setup" "psf_setup failed"; exit 1; }
trap psf_cleanup EXIT
unset PLAN_LANG DOCS_LANG_PUBLIC DOCS_LANG_PRIVATE 2>/dev/null || true
printf 'PLAN_LANG=english\n' > "$AGENTS_CONFIG_DIR/.env"
STOP_HOOK="$(psf_np "$AGENTS_DIR/hooks/stop-confirm-plan-guard.js")"
TC_LIB="$(psf_np "$AGENTS_DIR/hooks/lib/plan-link-turn-check.js")"
L3_PREFIX='[confirm-plan] Layer 3/plan-url:'
L1_PREFIX='[confirm-plan] Step 2 violation:'
L2_FOLLOWUP_PREFIX='[confirm-plan] Layer 2/follow-up:'
UPG_BLOB="https://github.com/test-owner/test-repo/blob/main"
UPG_PROSE='This artifact body is written entirely in English prose here.'
PLANS="$WORKFLOW_PLANS_DIR"
TDIR="$PSF_ROOT/transcripts"

# ══ Unit: hooks/lib/plan-link-turn-check.js ═════════════════════════════════

# Driver prelude/epilogue kept in heredocs so case-marker tooling can split cases cleanly.
IFS= read -r -d '' TC_PRELUDE <<'JS' || true
const out = [];
const ok = (n, c, d) => out.push(c ? 'PASS|' + n : 'FAIL|' + n + '|' + d);
const show = (x) => JSON.stringify(x);
const isBlock = (r) => !!r && (r.block === true || r.decision === 'block');
const U = (text) => ({ type: 'user', message: { role: 'user', content: text } });
const R = () => ({ type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't1', content: 'ok' }] } });
const RT = (text) => ({ type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't1', content: text }] } });
const A = (...content) => ({ type: 'assistant', message: { role: 'assistant', content } });
const T = (text) => ({ type: 'text', text });
const B = (command) => ({ type: 'tool_use', id: 't1', name: 'Bash', input: { command } });
const S = (skill) => ({ type: 'tool_use', id: 't2', name: 'Skill', input: { skill } });
const C = (stage) => B('echo "<<WORKFLOW_CONFIRM_' + stage.toUpperCase() + ': ok>>"');
let tc;
try { tc = require(process.env.TC_LIB); }
catch (e) { process.stdout.write('FAIL|require hooks/lib/plan-link-turn-check.js|not implemented: ' + (e.code || e.message) + '\n'); process.exit(0); }
try {
JS
IFS= read -r -d '' TC_EPILOGUE <<'JS' || true
} catch (e) { ok('driver does not throw', false, e && e.stack); }
process.stdout.write(out.join('\n') + '\n');
JS

# tc_node <js> — `tc` = the lib, ok(name, cond, detail); PASS|/FAIL| lines out.
tc_node() {
  TC_LIB="$TC_LIB" psf_timeout 60 node -e "$TC_PRELUDE$1$TC_EPILOGUE" 2>&1 || printf 'FAIL|node driver|exit=%s\n' "$?"
}

tc_report() {
  local line rest name
  [ -z "$1" ] && { fail "driver produced no assertions"; return; }
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    rest="${line#*|}"; name="${rest%%|*}"
    case "$line" in
      PASS\|*) pass "$name" ;;
      FAIL\|*) fail "$name" "${rest#*|}" ;;
      *) fail "unparsed driver line" "$line" ;;
    esac
  done <<< "$1"
}

case_begin "unit-exports" "hooks/lib/plan-link-turn-check.js"
tc_report "$(tc_node '
["collectTurnAssistantText", "stagesToCheck", "checkPlanUrlInTurn"].forEach((f) => ok(f + " is exported", typeof tc[f] === "function", typeof tc[f]));
')"
case_end

case_begin "unit-collect-turn-text" "hooks/lib/plan-link-turn-check.js"
tc_report "$(tc_node '
const s = tc.collectTurnAssistantText([U("first prompt"), A(T("OLD-TURN-TEXT")), U("second prompt"),
  A(T("EARLY-IN-TURN"), B("ls")), R(), A(T("FINAL-TEXT"))]);
ok("returns a string", typeof s === "string", show(s));
ok("includes the final assistant text", String(s).includes("FINAL-TEXT"), show(s));
ok("includes an earlier assistant entry of the same turn (across a tool_result)", String(s).includes("EARLY-IN-TURN"), show(s));
ok("excludes the previous turn", !String(s).includes("OLD-TURN-TEXT"), show(s));
ok("excludes user prompt text", !String(s).includes("second prompt"), show(s));
')"
case_end

case_begin "unit-collect-excludes-tool-io" "hooks/lib/plan-link-turn-check.js"
tc_report "$(tc_node '
const s = tc.collectTurnAssistantText([U("go"), A(T("VISIBLE-TEXT"), B("echo TOOL-INPUT-ONLY")),
  RT("TOOL-RESULT-ONLY"), A({ type: "tool_use", id: "t3", name: "Write", input: { file_path: "/x", content: "WRITE-INPUT-ONLY" } })]);
ok("keeps assistant text", String(s).includes("VISIBLE-TEXT"), show(s));
ok("excludes a Bash tool_use command", !String(s).includes("TOOL-INPUT-ONLY"), show(s));
ok("excludes any other tool_use input", !String(s).includes("WRITE-INPUT-ONLY"), show(s));
ok("excludes tool_result content", !String(s).includes("TOOL-RESULT-ONLY"), show(s));
')"
case_end

case_begin "unit-stages-to-check" "hooks/lib/plan-link-turn-check.js"
tc_report "$(tc_node '
const st = (markers, turnEntries) => { const r = tc.stagesToCheck({ markers, turnEntries }); return Array.isArray(r) ? [...r].sort() : r; };
const eq = (n, got, want) => ok(n, show(got) === show(want), "got=" + show(got) + " want=" + show(want));
eq("marker intent -> [intent]", st([{ suffix: "intent", absPath: "/x/s-intent.md" }], [A(T("hi"))]), ["intent"]);
eq("no marker + CONFIRM_OUTLINE -> [outline]", st([], [A(C("outline"), S("make-detail-plan"))]), ["outline"]);
eq("no marker + CONFIRM_DETAIL -> [detail]", st([], [A(C("detail"), S("write-tests"))]), ["detail"]);
eq("marker intent + CONFIRM_INTENT -> [intent] (deduplicated)", st([{ suffix: "intent" }], [A(C("intent"), S("make-outline-plan"))]), ["intent"]);
eq("marker intent + marker outline -> [intent, outline]", st([{ suffix: "intent" }, { suffix: "outline" }], [A(T("x"))]), ["intent", "outline"]);
eq("CONFIRM_TESTS only -> []", st([], [A(C("tests"), S("run-tests"))]), []);
eq("no marker, no CONFIRM -> []", st([], [A(T("plain answer"))]), []);
')"
case_end

case_begin "unit-check-plan-url" "hooks/lib/plan-link-turn-check.js"
tc_report "$(tc_node '
const URL_I = "https://github.com/test-owner/test-repo/blob/main/s-intent.md";
const URL_O = "https://github.com/test-owner/test-repo/blob/main/s-outline.md";
const pub = (stage) => ({ intent: { url: URL_I, kind: "blob" }, outline: { url: URL_O, kind: "blob" } })[stage] || { reason: "no-artifact" };
const run = (stages, turnText, resolve) => { try { return tc.checkPlanUrlInTurn({ stages, turnText, resolve }); } catch (e) { return { threw: e.message }; } };
const allow = (n, r) => ok(n, !isBlock(r) && !(r && r.threw), show(r));
const block = (n, r) => {
  ok(n, isBlock(r), show(r));
  const reason = r && typeof r.reason === "string" ? r.reason : "";
  ok(n + " — reason has the Layer 3/plan-url prefix", reason.startsWith("[confirm-plan] Layer 3/plan-url:"), show(reason));
  ok(n + " — reason names no URL", !/https?:\/\//.test(reason), show(reason));
  ok(n + " — reason points at bin/plan-link", reason.includes("bin/plan-link"), show(reason));
};
allow("URL present -> allow", run(["intent"], "Plan: " + URL_I, pub));
block("URL missing -> block", run(["intent"], "Plan written.", pub));
block("one of two published stages missing -> block", run(["intent", "outline"], "Plan: " + URL_I, pub));
allow("both URLs present -> allow", run(["intent", "outline"], URL_I + " and " + URL_O, pub));
allow("no stages -> allow", run([], "nothing", pub));
block("another stage URL only (intent URL, outline checked) -> block", run(["outline"], "Plan: " + URL_I, pub));
block("another session URL -> block", run(["intent"], "Plan: https://github.com/test-owner/test-repo/blob/main/other-intent.md", pub));
block("same file in another repo -> block", run(["intent"], "Plan: https://github.com/test-owner/other-repo/blob/main/s-intent.md", pub));
allow("unpublished (not-published) -> allow", run(["intent"], "Plan written.", () => ({ reason: "not-published" })));
allow("plan-sync off -> allow", run(["intent"], "Plan written.", () => ({ reason: "plan-sync-off" })));
allow("resolve throws -> allow (fail-open)", run(["intent"], "Plan written.", () => { throw new Error("boom"); }));
')"
case_end

# ══ Hook: hooks/stop-confirm-plan-guard.js ══════════════════════════════════

SID_PUB="0d2c5d7e-1111-4222-8333-444455550001"
SID_LOCAL="0d2c5d7e-1111-4222-8333-444455550002"
UPG_FIX="ok"
psf_make_provisioned "$PLANS" "$PSF_ORIGIN_E2E" >/dev/null 2>&1 || UPG_FIX="provision"
for stage in intent outline detail; do
  printf '%s\n' "$UPG_PROSE" > "$PLANS/$SID_PUB-$stage.md"
  psf_commit_file "$PLANS" "$SID_PUB-$stage.md" refs/remotes/origin/main >/dev/null 2>&1 || UPG_FIX="commit-$stage"
done
printf '%s\n' "$UPG_PROSE" > "$PLANS/$SID_LOCAL-intent.md"
export PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_E2E"
URL_INTENT="$UPG_BLOB/$SID_PUB-intent.md"
URL_OUTLINE="$UPG_BLOB/$SID_PUB-outline.md"
URL_DETAIL="$UPG_BLOB/$SID_PUB-detail.md"
if [ "$UPG_FIX" = ok ]; then pass "hook fixture built"; else fail "hook fixture built" "step=$UPG_FIX"; fi

# upg_marker <sid> <stage> — the per-turn marker show-plan-link.js drops after a plan write.
upg_marker() {
  printf '{"session_id":"%s","absPath":"%s","suffix":"%s","ts":1234567890}\n' "$1" "$PLANS/$1-$2.md" "$2" \
    > "$CLAUDE_WORKFLOW_DIR/$1.confirm-plan-turn-$RANDOM$RANDOM.json"
}

# upg_case <label> <sid> <stage-marker|-> <transcript-js> <want: allow|block> <reason-prefix|-> [stdin-extra-json]
# transcript-js: a JS array expression of transcript entries (helpers U/R/A/T/B/S/C as in tc_node;
# URL_INTENT, URL_OUTLINE, PLANS are in scope).
upg_case() {
  local label="$1" sid="$2" mstage="$3" js="$4" want="$5" prefix="$6" extra="${7:-}"
  local tpath="$TDIR/$sid-$RANDOM.jsonl" out rc reason leak ok=1
  rm -f "$CLAUDE_WORKFLOW_DIR/$sid".confirm-plan-turn-*.json
  [ "$mstage" != "-" ] && upg_marker "$sid" "$mstage"
  URL_INTENT="$URL_INTENT" URL_OUTLINE="$URL_OUTLINE" URL_DETAIL="$URL_DETAIL" PLANS="$PLANS" psf_timeout 30 node -e "
const U = (text) => ({ type: 'user', message: { role: 'user', content: text } });
const R = () => ({ type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't1', content: 'ok' }] } });
const RT = (text) => ({ type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't1', content: text }] } });
const A = (...content) => ({ type: 'assistant', message: { role: 'assistant', content } });
const T = (text) => ({ type: 'text', text });
const B = (command) => ({ type: 'tool_use', id: 't1', name: 'Bash', input: { command } });
const S = (skill) => ({ type: 'tool_use', id: 't2', name: 'Skill', input: { skill } });
const C = (stage) => B('echo \"<<WORKFLOW_CONFIRM_' + stage.toUpperCase() + ': ok>>\"');
const { URL_INTENT, URL_OUTLINE, URL_DETAIL, PLANS } = process.env;
const entries = ($js);
require('fs').writeFileSync(process.argv[1], entries.map((e) => JSON.stringify(e)).join('\n') + '\n');" "$tpath"
  if [ ! -f "$STOP_HOOK" ]; then fail "$label" "hooks/stop-confirm-plan-guard.js absent"; return; fi
  out="$(printf '{"session_id":"%s","transcript_path":"%s"%s}' "$sid" "$tpath" "$extra" | psf_timeout 60 node "$STOP_HOOK" 2>/dev/null)"
  rc=$?
  reason="$(printf '%s' "$out" | psf_timeout 30 node -e "
let o = {}; try { o = JSON.parse(require('fs').readFileSync(0, 'utf8') || '{}'); } catch (e) {}
process.stdout.write(o.decision === 'block' && typeof o.reason === 'string' ? o.reason : '');")"
  if [ "$want" = allow ]; then
    { [ "$rc" -eq 0 ] && [ -z "$out" ]; } || ok=0
  else
    [ "$rc" -eq 2 ] && [ -n "$reason" ] && [ "${reason#"$prefix"}" != "$reason" ] || ok=0
  fi
  if [ "$ok" -eq 1 ]; then pass "$label"; else fail "$label" "want=$want prefix='$prefix' rc=$rc stdout=$out"; fi
  if [ "$want" = block ] && [ "$prefix" = "$L3_PREFIX" ] && [ -z "$reason" ]; then
    fail "$label — reason content checks" "no block reason to inspect"
  elif [ "$want" = block ] && [ "$prefix" = "$L3_PREFIX" ]; then
    if printf '%s' "$reason" | grep -qE 'https?://'; then fail "$label — reason names no URL" "$reason"; else pass "$label — reason names no URL"; fi
    if printf '%s' "$reason" | grep -qF 'bin/plan-link'; then pass "$label — reason points at bin/plan-link"; else fail "$label — reason points at bin/plan-link" "$reason"; fi
    leak="$(psf_path_leak "$reason" "$PLANS")"
    if [ -z "$leak" ]; then pass "$label — reason names no local path"; else fail "$label — reason names no local path" "leaked '$leak': $reason"; fi
  fi
  rm -f "$CLAUDE_WORKFLOW_DIR/$sid".confirm-plan-turn-*.json
}

case_begin "hook-marker-url-in-final-text" "hooks/stop-confirm-plan-guard.js"
upg_case "H1 marker intent, URL in final text — allow" "$SID_PUB" intent \
  '[U("go"), A(T("Plan: " + URL_INTENT))]' allow -
upg_case "H2 marker intent, URL missing — Layer 3 block" "$SID_PUB" intent \
  '[U("go"), A(T("The intent plan is written."))]' block "$L3_PREFIX"
case_end

case_begin "hook-url-earlier-in-turn" "hooks/stop-confirm-plan-guard.js"
upg_case "H3 URL in an earlier assistant entry of the same turn — allow" "$SID_PUB" intent \
  '[U("go"), A(T("Plan: " + URL_INTENT), B("ls")), R(), A(T("All done."))]' allow -
case_end

case_begin "hook-url-only-previous-turn" "hooks/stop-confirm-plan-guard.js"
upg_case "H4 URL only in the previous turn — Layer 3 block" "$SID_PUB" intent \
  '[U("first"), A(T("Plan: " + URL_INTENT)), U("second"), A(T("Updated the plan."))]' block "$L3_PREFIX"
case_end

case_begin "hook-confirm-without-marker" "hooks/stop-confirm-plan-guard.js"
upg_case "H5 no marker, CONFIRM_OUTLINE + follow-up, no URL — Layer 3 block" "$SID_PUB" - \
  '[U("ok"), A(T("Confirmed."), C("outline"), S("make-detail-plan"))]' block "$L3_PREFIX"
upg_case "H6 no marker, CONFIRM_OUTLINE + follow-up, URL shown — allow" "$SID_PUB" - \
  '[U("ok"), A(T("Outline: " + URL_OUTLINE), C("outline"), S("make-detail-plan"))]' allow -
upg_case "H7 CONFIRM_TESTS only, no URL — not evaluated (allow)" "$SID_PUB" - \
  '[U("ok"), A(T("Tests confirmed."), C("tests"), S("run-tests"))]' allow -
case_end

case_begin "hook-confirm-intent-detail" "hooks/stop-confirm-plan-guard.js"
upg_case "H13 no marker, CONFIRM_INTENT + follow-up, no URL — Layer 3 block" "$SID_PUB" - \
  '[U("ok"), A(T("Confirmed."), C("intent"), S("make-outline-plan"))]' block "$L3_PREFIX"
upg_case "H14 no marker, CONFIRM_INTENT + follow-up, URL shown — allow" "$SID_PUB" - \
  '[U("ok"), A(T("Intent: " + URL_INTENT), C("intent"), S("make-outline-plan"))]' allow -
upg_case "H15 no marker, CONFIRM_DETAIL + follow-up, no URL — Layer 3 block" "$SID_PUB" - \
  '[U("ok"), A(T("Confirmed."), C("detail"), S("write-tests"))]' block "$L3_PREFIX"
upg_case "H16 no marker, CONFIRM_DETAIL + follow-up, URL shown — allow" "$SID_PUB" - \
  '[U("ok"), A(T("Detail: " + URL_DETAIL), C("detail"), S("write-tests"))]' allow -
case_end

case_begin "hook-wrong-or-hidden-url" "hooks/stop-confirm-plan-guard.js"
upg_case "H17 CONFIRM_OUTLINE + follow-up, only the intent URL shown — Layer 3 block" "$SID_PUB" - \
  '[U("ok"), A(T("Plan: " + URL_INTENT), C("outline"), S("make-detail-plan"))]' block "$L3_PREFIX"
upg_case "H18 marker intent, another session's blob URL shown — Layer 3 block" "$SID_PUB" intent \
  '[U("go"), A(T("Plan: " + URL_INTENT.replace("'"$SID_PUB"'", "'"$SID_LOCAL"'")))]' block "$L3_PREFIX"
upg_case "H19 marker intent, URL only in tool input and tool_result — Layer 3 block" "$SID_PUB" intent \
  '[U("go"), A(T("Running."), B("echo " + URL_INTENT)), RT(URL_INTENT), A(T("The intent plan is written."))]' block "$L3_PREFIX"
case_end

case_begin "hook-fail-open" "hooks/stop-confirm-plan-guard.js"
upg_case "H8 unpublished (local-only) intent, marker, no URL — allow (fail-open)" "$SID_LOCAL" intent \
  '[U("go"), A(T("The intent plan is written."))]' allow -
PLAN_SYNC_REMOTE_URL="" upg_case "H9 plan-sync off, marker, no URL — allow (fail-open)" "$SID_PUB" intent \
  '[U("go"), A(T("The intent plan is written."))]' allow -
upg_case "H10 stop_hook_active, marker, no URL — allow" "$SID_PUB" intent \
  '[U("go"), A(T("The intent plan is written."))]' allow - ',"stop_hook_active":true'
case_end

case_begin "hook-layer-order" "hooks/stop-confirm-plan-guard.js"
upg_case "H11 marker + leaked local path, no URL — Layer 1 reason wins" "$SID_PUB" intent \
  '[U("go"), A(T("see " + PLANS + "/x-intent.md"))]' block "$L1_PREFIX"
upg_case "H12 no marker, CONFIRM_OUTLINE without follow-up, no URL — Layer 2 reason wins" "$SID_PUB" - \
  '[U("ok"), A(T("Confirmed."), C("outline"))]' block "$L2_FOLLOWUP_PREFIX"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
