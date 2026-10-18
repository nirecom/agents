#!/usr/bin/env bash
# tests/hooks/feature-plan-url-stop-guard.sh
# Tests: hooks/stop-confirm-plan-guard.js, hooks/lib/plan-link-turn-check.js
# Tags: plan, hook, stop, confirm-plan, plan-url, plan-link, plan-sync, blob-url, fail-open, TL2, scope:common, path-leak
# Turn-end plan-link check of the confirm-plan Stop guard: a turn that wrote a plan artifact
# (turn marker) or CONFIRMed a plan stage must carry that stage's plan-link output in its
# assistant text — the blob URL when one exists, otherwise the plan's local path. Runs after
# Layer 2, blocks once, and passes when the plan file is absent or cannot be resolved.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=../lib/plan-sync-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/plan-sync-fixture.sh"

# TL3 gap (hook-registration): the hook runs on synthetic stdin and hand-built transcripts.
# Real Stop dispatch and whether a plan-link block keeps a live session going are covered only
# for the local-path pass (tests/hooks/TL3-hook-stop-confirm-plan-guard/main.sh).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration.

psf_setup || { fail "setup" "psf_setup failed"; exit 1; }
# psf_setup pins both dirs inside a function; the top-level re-export is the pin the
# isolation gate (bin/check-plans-dir-isolation.sh) sees, inherited by the sourced groups.
export WORKFLOW_STATE_DIR="$WORKFLOW_STATE_DIR" WORKFLOW_PLANS_DIR="$WORKFLOW_PLANS_DIR"
trap psf_cleanup EXIT
unset PLAN_LANG DOCS_LANG_PUBLIC DOCS_LANG_PRIVATE 2>/dev/null || true
printf 'PLAN_LANG=english\n' > "$AGENTS_MAIN_ROOT/.env"
STOP_HOOK="$(psf_np "$SCRIPT_CHECKOUT_ROOT/hooks/stop-confirm-plan-guard.js")"
SUB_DIR="$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-plan-url-stop-guard"
export TC_LIB UPG_DRIVER
TC_LIB="$(psf_np "$SCRIPT_CHECKOUT_ROOT/hooks/lib/plan-link-turn-check.js")"
UPG_DRIVER="$(psf_np "$SUB_DIR/unit-driver.js")"
PL_PREFIX='[confirm-plan] plan-link:'
L2_FOLLOWUP_PREFIX='[confirm-plan] Layer 2/follow-up:'
UPG_BLOB="https://github.com/test-owner/test-repo/blob/main"
UPG_BLOB_GL="https://gitlab.com/test-group/test-project/-/blob/main"
UPG_PROSE='This artifact body is written entirely in English prose here.'
PLANS="$WORKFLOW_PLANS_DIR"
TDIR="$PSF_ROOT/transcripts"
UPG_HOME_DIR="$PSF_ROOT/home dir"
mkdir -p "$UPG_HOME_DIR"
UPG_JS_HELPERS='const { path, U, R, RT, RTE, UMETA, UCOMPACT, A, T, B, S, C, W, fwdOf, uriOf, runUnit } = require(process.env.UPG_DRIVER); '

# tc_node <js> — runs <js> inside runUnit (tc, ok, show, isBlock in scope); PASS|/FAIL| lines out.
# The home directory is the fixture's, so a "~" path form never names a real one.
tc_node() {
  local js
  printf -v js '%srunUnit(({ tc, ok, show, isBlock }) => {\n%s\n});' "$UPG_JS_HELPERS" "$1"
  HOME="$UPG_HOME_DIR" USERPROFILE="$UPG_HOME_DIR" \
    psf_timeout 60 node -e "$js" 2>&1 || printf 'FAIL|node driver|exit=%s\n' "$?"
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

# ══ Unit: hooks/lib/plan-link-turn-check.js ═════════════════════════════════

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
eq("CONFIRM in an earlier entry of the turn -> [outline]", st([], [A(C("outline")), R(), A(T("done"), S("make-detail-plan"))]), ["outline"]);
eq("CONFIRM_TESTS only -> []", st([], [A(C("tests"), S("run-tests"))]), []);
eq("no marker, no CONFIRM -> []", st([], [A(T("plain answer"))]), []);
')"
case_end

case_begin "unit-check-plan-url" "hooks/lib/plan-link-turn-check.js"
. "$SUB_DIR/unit-check-plan-link.sh"
case_end

case_begin "unit-turn-split" "hooks/lib/plan-link-turn-check.js"
. "$SUB_DIR/unit-turn-split.sh"
. "$SUB_DIR/unit-ends-with-link-line.sh"
case_end

# ══ Hook: hooks/stop-confirm-plan-guard.js ══════════════════════════════════

. "$SUB_DIR/hook-fixture.sh"

case_begin "hook-marker-url-in-final-text" "hooks/stop-confirm-plan-guard.js"
upg_case "H1 marker intent, URL in final text without the local path — allow" "$SID_PUB" intent \
  '[U("go"), A(T("Plan: " + URL_INTENT))]' allow -
upg_case "H1b marker intent, URL and local path both in the reply — allow" "$SID_PUB" intent \
  '[U("go"), A(T("Plan: " + URL_INTENT + " (" + nat("intent") + ")"))]' allow -
upg_case "H2 marker intent, URL missing — plan-link block" "$SID_PUB" intent \
  '[U("go"), A(T("The intent plan is written."))]' block "$PL_PREFIX"
case_end

case_begin "hook-url-exists-local-path-alone" "hooks/stop-confirm-plan-guard.js"
upg_case "P1 published (match record), reply holds only the native local path — plan-link block" "$SID_PUB" intent \
  '[U("go"), A(T("Plan: " + nat("intent")))]' block "$PL_PREFIX"
upg_case "P2 published (match record), reply holds only the forward-slash local path — plan-link block" "$SID_PUB" intent \
  '[U("go"), A(T("Plan: " + fwd("intent")))]' block "$PL_PREFIX"
upg_case "P3 no record, already at the destination, reply holds only the local path — plan-link block" "$SID_NOREC_PUB" intent \
  '[U("go"), A(T("Plan: " + nat("intent")))]' block "$PL_PREFIX"
upg_case "P4 no record, already at the destination, URL in the reply — allow" "$SID_NOREC_PUB" intent \
  '[U("go"), A(T("Plan: " + url("intent")))]' allow -
case_end

case_begin "hook-url-earlier-in-turn" "hooks/stop-confirm-plan-guard.js"
upg_case "H3 URL in an earlier assistant entry, final text block without it — plan-link block (#2513)" "$SID_PUB" intent \
  '[U("go"), A(T("Plan: " + URL_INTENT), B("ls")), R(), A(T("All done."))]' block "$PL_PREFIX"
upg_case "T1 two text blocks in the final entry, URL only in the first — plan-link block" "$SID_PUB" intent \
  '[U("go"), A(T("Plan: " + URL_INTENT), T("Done."))]' block "$PL_PREFIX"
upg_case "T2 same, last_assistant_message joins both blocks — still a plan-link block" "$SID_PUB" intent \
  '[U("go"), A(T("Plan: " + URL_INTENT), T("Done."))]' block "$PL_PREFIX" ',"last_assistant_message":"Plan: '"$UPG_BLOB/$SID_PUB-intent.md"'\n\nDone."'
upg_case "T3 URL in the last text block of the final entry — allow" "$SID_PUB" intent \
  '[U("go"), A(T("Done."), T("Plan: " + URL_INTENT))]' allow -
case_end

case_begin "hook-last-assistant-message" "hooks/stop-confirm-plan-guard.js"
upg_case "LM1 last_assistant_message never matches the transcript (undecidable) — allow" "$SID_PUB" intent \
  '[U("go"), A(T("The intent plan is written."))]' allow - ',"last_assistant_message":"A final text that is never flushed."'
upg_case "LM2 last_assistant_message matches, no link — plan-link block" "$SID_PUB" intent \
  '[U("go"), A(T("The intent plan is written."))]' block "$PL_PREFIX" ',"last_assistant_message":"The intent plan is written."'
upg_case "LM3 last_assistant_message matches, link present — allow" "$SID_PUB" intent \
  '[U("go"), A(T("Plan: " + URL_INTENT))]' allow - ',"last_assistant_message":"Plan: '"$UPG_BLOB/$SID_PUB-intent.md"'"'
upg_case "E1 CONFIRM_OUTLINE denied (is_error tool_result), no follow-up — allow" "$SID_PUB" - \
  '[U("ok"), A(T("Confirmed."), C("outline")), RTE("denied by hook")]' allow -
upg_case "E2 CONFIRM_OUTLINE succeeded (tool_result ok), no follow-up — Layer 2 block" "$SID_PUB" - \
  '[U("ok"), A(T("Confirmed."), C("outline")), R()]' block "$L2_FOLLOWUP_PREFIX"
case_end

case_begin "hook-url-only-previous-turn" "hooks/stop-confirm-plan-guard.js"
upg_case "H4 URL only in the previous turn — plan-link block" "$SID_PUB" intent \
  '[U("first"), A(T("Plan: " + URL_INTENT)), U("second"), A(T("Updated the plan."))]' block "$PL_PREFIX"
case_end

case_begin "hook-confirm-without-marker" "hooks/stop-confirm-plan-guard.js"
upg_case "H5 no marker, CONFIRM_OUTLINE + follow-up, no URL — not evaluated at Stop (allow)" "$SID_PUB" - \
  '[U("ok"), A(T("Confirmed."), C("outline"), S("make-detail-plan"))]' allow -
upg_case "H6 no marker, CONFIRM_OUTLINE + follow-up, URL shown — allow" "$SID_PUB" - \
  '[U("ok"), A(T("Outline: " + URL_OUTLINE), C("outline"), S("make-detail-plan"))]' allow -
upg_case "H7 CONFIRM_TESTS only, no URL — not evaluated (allow)" "$SID_PUB" - \
  '[U("ok"), A(T("Tests confirmed."), C("tests"), S("run-tests"))]' allow -
case_end

case_begin "hook-confirm-intent-detail" "hooks/stop-confirm-plan-guard.js"
upg_case "H13 no marker, CONFIRM_INTENT + follow-up, no URL — not evaluated at Stop (allow)" "$SID_PUB" - \
  '[U("ok"), A(T("Confirmed."), C("intent"), S("make-outline-plan"))]' allow -
upg_case "H14 no marker, CONFIRM_INTENT + follow-up, URL shown — allow" "$SID_PUB" - \
  '[U("ok"), A(T("Intent: " + URL_INTENT), C("intent"), S("make-outline-plan"))]' allow -
upg_case "H15 no marker, CONFIRM_DETAIL + follow-up, no URL — not evaluated at Stop (allow)" "$SID_PUB" - \
  '[U("ok"), A(T("Confirmed."), C("detail"), S("write-tests"))]' allow -
upg_case "H16 no marker, CONFIRM_DETAIL + follow-up, URL shown — allow" "$SID_PUB" - \
  '[U("ok"), A(T("Detail: " + URL_DETAIL), C("detail"), S("write-tests"))]' allow -
case_end

case_begin "hook-wrong-or-hidden-url" "hooks/stop-confirm-plan-guard.js"
upg_case "H17 CONFIRM_OUTLINE + follow-up, only the intent URL shown — not evaluated at Stop (allow)" "$SID_PUB" - \
  '[U("ok"), A(T("Plan: " + URL_INTENT), C("outline"), S("make-detail-plan"))]' allow -
upg_case "H18 marker intent, another session's blob URL shown — plan-link block" "$SID_PUB" intent \
  '[U("go"), A(T("Plan: " + URL_INTENT.replace("'"$SID_PUB"'", "'"$SID_LOCAL"'")))]' block "$PL_PREFIX"
upg_case "H19 marker intent, URL only in tool input and tool_result — plan-link block" "$SID_PUB" intent \
  '[U("go"), A(T("Running."), B("echo " + URL_INTENT)), RT(URL_INTENT), A(T("The intent plan is written."))]' block "$PL_PREFIX"
case_end

case_begin "hook-no-url-needs-local-path" "hooks/stop-confirm-plan-guard.js"
upg_case "N1 no record, not at the destination, file URI in the reply — allow" "$SID_LOCAL" intent \
  '[U("go"), A(T("Plan: " + uri("intent")))]' allow -
upg_case "N2 no record, not at the destination, neither in the reply — plan-link block" "$SID_LOCAL" intent \
  '[U("go"), A(T("The intent plan is written."))]' block "$PL_PREFIX"
upg_case "N3 host-mismatch record, native local path in the reply — allow" "$SID_MISMATCH" intent \
  '[U("go"), A(T("Plan: " + nat("intent")))]' allow -
upg_case "N4 host-mismatch record, neither in the reply — plan-link block" "$SID_MISMATCH" intent \
  '[U("go"), A(T("The intent plan is written."))]' block "$PL_PREFIX"
upg_case "N5 no-project-host record, forward-slash local path in the reply — allow" "$SID_NOHOST" intent \
  '[U("go"), A(T("Plan: " + fwd("intent")))]' allow -
upg_case "N6 no-project-host record, neither in the reply — plan-link block" "$SID_NOHOST" intent \
  '[U("go"), A(T("The intent plan is written."))]' block "$PL_PREFIX"
upg_case "N7 match record, local content differs from the destination, local path in the reply — allow" "$SID_STALE" intent \
  '[U("go"), A(T("Plan: " + fwd("intent")))]' allow -
upg_case "N8 match record, local content differs from the destination, only a blob URL in the reply — plan-link block" "$SID_STALE" intent \
  '[U("go"), A(T("Plan: " + url("intent")))]' block "$PL_PREFIX"
case_end

case_begin "hook-plan-sync-off-path-forms" "hooks/stop-confirm-plan-guard.js"
UPG_PLANS="$PLANS_HOME" UPG_REMOTE="" UPG_HOME="$UPG_HOME_DIR" upg_case "F1 plan-sync off, absolute plans-dir path in the reply — allow" \
  "$SID_OFF" intent '[U("go"), A(T("Plan: " + nat("intent")))]' allow -
UPG_PLANS="$PLANS_HOME" UPG_REMOTE="" UPG_HOME="$UPG_HOME_DIR" upg_case "F2 plan-sync off, forward-slash form in the reply — allow" \
  "$SID_OFF" intent '[U("go"), A(T("Plan: " + fwd("intent")))]' allow -
UPG_PLANS="$PLANS_HOME" UPG_REMOTE="" UPG_HOME="$UPG_HOME_DIR" upg_case "F3 plan-sync off, ~ form in the reply — allow" \
  "$SID_OFF" intent '[U("go"), A(T("Plan: " + tilde("intent")))]' allow -
UPG_PLANS="$PLANS_HOME" UPG_REMOTE="" UPG_HOME="$UPG_HOME_DIR" upg_case "F4 plan-sync off, file URI in the reply — allow" \
  "$SID_OFF" intent '[U("go"), A(T("Open " + uri("intent") + " please"))]' allow -
UPG_PLANS="$PLANS_HOME" UPG_REMOTE="" UPG_HOME="$UPG_HOME_DIR" upg_case "F5 plan-sync off, neither in the reply — plan-link block" \
  "$SID_OFF" intent '[U("go"), A(T("The intent plan is written."))]' block "$PL_PREFIX"
case_end

case_begin "hook-mismatch-record-at-destination" "hooks/stop-confirm-plan-guard.js"
upg_case "M1 host-mismatch record, identical file at the destination, only the blob URL in the reply — plan-link block" \
  "$SID_MISMATCH_PUB" intent '[U("go"), A(T("Plan: " + url("intent")))]' block "$PL_PREFIX"
upg_case "M2 host-mismatch record, identical file at the destination, local path in the reply — allow" \
  "$SID_MISMATCH_PUB" intent '[U("go"), A(T("Plan: " + nat("intent")))]' allow -
case_end

case_begin "hook-confirm-no-url" "hooks/stop-confirm-plan-guard.js"
upg_case "K1 no marker, CONFIRM_INTENT + follow-up, no URL exists, local path in the reply — allow" "$SID_LOCAL" - \
  '[U("ok"), A(T("Intent: " + nat("intent")), C("intent"), S("make-outline-plan"))]' allow -
upg_case "K2 no marker, CONFIRM_INTENT + follow-up, no URL exists, neither in the reply — not evaluated at Stop (allow)" "$SID_LOCAL" - \
  '[U("ok"), A(T("Confirmed."), C("intent"), S("make-outline-plan"))]' allow -
case_end

case_begin "hook-unresolvable-plan-passes" "hooks/stop-confirm-plan-guard.js"
upg_case "A1 marker intent, plan file absent, nothing in the reply — allow" "$SID_ABSENT" intent \
  '[U("go"), A(T("The intent plan is written."))]' allow -
upg_case "A2 no marker, CONFIRM_OUTLINE + follow-up, outline file absent — allow" "$SID_LOCAL" - \
  '[U("ok"), A(T("Confirmed."), C("outline"), S("make-detail-plan"))]' allow -
UPG_HOOK_PLANS="relative-plans" upg_case "A3 plans dir cannot be resolved (non-absolute), marker, nothing in the reply — allow" \
  "$SID_LOCAL" intent '[U("go"), A(T("The intent plan is written."))]' allow -
case_end

case_begin "hook-blocks-once" "hooks/stop-confirm-plan-guard.js"
upg_case "H10 stop_hook_active, marker, no URL — allow" "$SID_PUB" intent \
  '[U("go"), A(T("The intent plan is written."))]' allow - ',"stop_hook_active":true'
upg_case "B1 first Stop, marker, no URL exists and no local path — plan-link block" "$SID_LOCAL" intent \
  '[U("go"), A(T("The intent plan is written."))]' block "$PL_PREFIX"
if [ "$UPG_MARKERS_LEFT" -eq 0 ]; then pass "B1 — the blocking Stop consumed the turn marker"
else fail "B1 — the blocking Stop consumed the turn marker" "left=$UPG_MARKERS_LEFT"; fi
upg_case "B2 second Stop of that turn (stop_hook_active), reply unchanged — allow" "$SID_LOCAL" - \
  '[U("go"), A(T("The intent plan is written."))]' allow - ',"stop_hook_active":true'
upg_case "B3 CONFIRM_INTENT turn, second Stop (stop_hook_active), no URL in the reply — allow" "$SID_PUB" - \
  '[U("ok"), A(T("Confirmed."), C("intent"), S("make-outline-plan"))]' allow - ',"stop_hook_active":true'
case_end

case_begin "hook-layer-order" "hooks/stop-confirm-plan-guard.js"
upg_case "H11 marker + another plan's local path, no URL — plan-link block (a local path is not refused by itself)" "$SID_PUB" intent \
  '[U("go"), A(T("see " + fwdOf(PLANS) + "/x-intent.md"))]' block "$PL_PREFIX"
upg_case "H12 no marker, CONFIRM_OUTLINE without follow-up, no URL — Layer 2 reason wins" "$SID_PUB" - \
  '[U("ok"), A(T("Confirmed."), C("outline"))]' block "$L2_FOLLOWUP_PREFIX"
case_end

case_begin "hook-gitlab-destination" "hooks/stop-confirm-plan-guard.js"
UPG_PLANS="$PLANS_GL" UPG_REMOTE="$PSF_ORIGIN_GL" UPG_BLOB_BASE="$UPG_BLOB_GL" upg_case "G1 GitLab destination, its /-/blob/main/ URL in the reply — allow" \
  "$SID_GL" intent '[U("go"), A(T("Plan: " + url("intent")))]' allow -
UPG_PLANS="$PLANS_GL" UPG_REMOTE="$PSF_ORIGIN_GL" UPG_BLOB_BASE="$UPG_BLOB_GL" upg_case "G2 GitLab destination, reply holds only the local path — plan-link block" \
  "$SID_GL" intent '[U("go"), A(T("Plan: " + nat("intent")))]' block "$PL_PREFIX"
UPG_PLANS="$PLANS_GL" UPG_REMOTE="$PSF_ORIGIN_GL" UPG_BLOB_BASE="$UPG_BLOB_GL" upg_case "G3 GitLab destination, a URL without the /-/ segment — plan-link block" \
  "$SID_GL" intent '[U("go"), A(T("Plan: " + url("intent").replace("/-/blob/", "/blob/")))]' block "$PL_PREFIX"
case_end

case_begin "hook-ssh-github-destination" "hooks/stop-confirm-plan-guard.js"
UPG_PLANS="$PLANS_SG" UPG_REMOTE="$UPG_ORIGIN_SSH_GH" upg_case "S1 ssh.github.com destination, github.com blob URL in the reply — allow" \
  "$SID_SG" intent '[U("go"), A(T("Plan: " + url("intent")))]' allow -
UPG_PLANS="$PLANS_SG" UPG_REMOTE="$UPG_ORIGIN_SSH_GH" upg_case "S2 ssh.github.com destination, reply holds only the local path — plan-link block" \
  "$SID_SG" intent '[U("go"), A(T("Plan: " + nat("intent")))]' block "$PL_PREFIX"
UPG_PLANS="$PLANS_SG" UPG_REMOTE="$UPG_ORIGIN_SSH_GH" upg_case "S3 ssh.github.com destination, a URL on the ssh host name — plan-link block" \
  "$SID_SG" intent '[U("go"), A(T("Plan: " + url("intent").replace("github.com", "ssh.github.com")))]' block "$PL_PREFIX"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
