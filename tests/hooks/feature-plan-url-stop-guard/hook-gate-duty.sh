# shellcheck shell=bash
# #2729 stage 2: the Stop guard's plan-link duty follows each stage's gate. OFF needs the link
# anywhere in the turn's assistant text; ON / ERROR (probe failure, exhausted deadline) need it in
# the last text block. intent is never OFF. Sourced by ../feature-plan-url-stop-guard.sh after
# hook-fixture.sh; CONFIRM_OUTLINE=off is written to $AGENTS_MAIN_ROOT/.env (file-only key).

UPG_ENV_SAVED="$(cat "$AGENTS_MAIN_ROOT/.env")"
unset CONFIRM_INTENT CONFIRM_OUTLINE CONFIRM_DETAIL 2>/dev/null || true
printf '%s\nCONFIRM_OUTLINE=off\n' "$UPG_ENV_SAVED" > "$AGENTS_MAIN_ROOT/.env"
UPG_STUB="$(psf_np "$SUB_DIR/probe-error-stub.js")"
UPG_MID='[U("go"), A(T("Outline written. Summary: " + URL_OUTLINE + " covers the steps."), B("ls")), R(), A(T("I continue with the detail plan next."))]'

upg_case "GD1 outline OFF, link only mid-summary in an earlier entry — allow" "$SID_PUB" outline "$UPG_MID" allow -
upg_case "GD2 outline OFF, link mid-text in the last block, prose after it — allow" "$SID_PUB" outline \
  '[U("go"), A(T("Summary: " + URL_OUTLINE + "\n\nNext I continue with the detail plan."))]' allow -
upg_case "GD3 outline OFF, no link anywhere in the turn — plan-link block" "$SID_PUB" outline \
  '[U("go"), A(T("Outline written."), B("ls")), R(), A(T("I continue."))]' block "$PL_PREFIX"
upg_case "GD4 outline OFF, link only in the previous turn — plan-link block" "$SID_PUB" outline \
  '[U("first"), A(T("Plan: " + URL_OUTLINE)), U("second"), A(T("Updated the outline."))]' block "$PL_PREFIX"
upg_case "GD5 intent (never OFF), link only mid-summary in an earlier entry — plan-link block" "$SID_PUB" intent \
  '[U("go"), A(T("Summary: " + URL_INTENT + " covers it."), B("ls")), R(), A(T("I continue."))]' block "$PL_PREFIX"

export NODE_OPTIONS="--require=$UPG_STUB"
upg_case "GD6 outline gate ERROR (probe stubbed), link only mid-summary — treated as ON: plan-link block" \
  "$SID_PUB" outline "$UPG_MID" block "$PL_PREFIX"
unset NODE_OPTIONS

export STOP_CONFIRM_CONTINUE_T0_OFFSET_MS=100000
upg_case "GD7 outline OFF but the Stop budget is spent, link only mid-summary — treated as ON: plan-link block" \
  "$SID_PUB" outline "$UPG_MID" block "$PL_PREFIX"
unset STOP_CONFIRM_CONTINUE_T0_OFFSET_MS

printf '%s\n' "$UPG_ENV_SAVED" > "$AGENTS_MAIN_ROOT/.env"
