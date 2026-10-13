#!/usr/bin/env bash
# Tests: hooks/lib/jev/two-stage/query.js, bin/workflow/lib/jev-request-common.js
# Tags: TL2, bin, jev, two-stage, required-sections, section-exemptions, read-cap, copy-failure, input-insufficient, mock-server, scope:issue-specific, pwsh-not-required
# Fragment of tests/bin/feature-2460-jev-judge.sh, sourced after _lib.sh (not standalone):
# Jev is asked only when every required section of the point x stage is full in the
# snapshot and was copied whole; otherwise every key goes to the subagent and the record
# names what was missing, exempt (a named exemption) or failed to copy.

echo "=== jev-judge: required sections per stage ==="
need_mod bin/workflow/jev-judge || return 0
need_mod hooks/lib/jev/two-stage/query.js || return 0
need_mod bin/workflow/lib/jev-request-common.js || return 0
. "$JJ_DIR/two-stage-lib.sh"

ALL_KEYS="s2_architecture,s3_security,s5_breaking"
P_INTENT() { printf '%s' "$FX/plans/$SID-intent.md"; }
big() { head -c "$1" /dev/zero | tr '\0' "$2"; }
add_outline() { printf '# Outline\n\n%s\n' "${1:-Touch only the report CLI.}" > "$FX/plans/$SID-outline.md"; }
add_detail() { printf '# Detail\n\n%s\n' "${1:-Edit bin/report and its test.}" > "$FX/plans/$SID-detail.md"; }

# req_run <stage> <opts-json>: query with Jev ready to adopt every key (p=0.99), then
# answer "none" and finalize. Q_* hold the query view; the decision log holds the input.
# Callers pass F_PRODUCTION (or f_production_with) so the gate applies whatever the shipped mode.
req_run() {
  mock_p 0.99
  ts_query "$1" complexity-judge "$2"
  Q_RESULT="$(kv RESULT)"; Q_DELEG="$(keyset "$(kv DELEGATED)")"; Q_JEV="$(mock_count systemone)"
  answer_with "SIGNALS: none"
  jj finalize --session "$SID" --ticket "$TICKET"
}
# inp <field>: the decision record's input.<field> as JSON (arrays sorted).
inp() {
  lq "$TICKET" "r && r.input ? JSON.stringify(Array.isArray(r.input.$1) ? r.input.$1.slice().sort() : r.input.$1) : 'no-record'"
}
fb() { lq "$TICKET" 'r ? String(r.fallback_reason) : "no-record"'; }
not_asked() {
  check "$1: Jev not asked, RESULT=need-subagent" "0|need-subagent" "$Q_JEV|$Q_RESULT"
  check "$1: every judged key delegated" "$ALL_KEYS" "$Q_DELEG"
  check "$1: fallback_reason input-insufficient" "input-insufficient" "$(fb)"
  if [ -n "${2:-}" ]; then check "$1: input.missing" "$2" "$(inp missing)"; fi
}
asked() {
  check "$1: Jev asked once, RESULT=final" "1|final" "$Q_JEV|$Q_RESULT"
  if [ -n "${2:-}" ]; then check "$1: input.exempt" "$2" "$(inp exempt)"; fi
}

case_begin "e-required-constants" "bin/workflow/lib/jev-request-common.js"
jj_fx e-consts
check "STAGE_SOURCE_SECTIONS, SECTION_ORDER, read cap and NO_ISSUE_BODY" \
  '{"stage_sources":{"complexity":["intent","issue body","outline"],"detail":["intent","issue body","outline"],"outline":["intent","issue body","outline"],"write-code":["detail","intent","issue body","outline","write-code files"],"write-tests":["detail","intent","issue body","outline"]},"order":["intent","outline","write-code files","detail","issue body"],"cap":1048576,"no_issue_body":"(none — no issue)"}' \
  "$(tpb consts)"
case_end

case_begin "e-required-intent" "hooks/lib/jev/two-stage/query.js"
jj_fx e-full
req_run complexity "$F_PRODUCTION"
asked "complexity, intent and issue body full"
check "complexity full: input.missing empty" "[]" "$(inp missing)"
jj_fx e-outline-stage
req_run outline "$F_PRODUCTION"
asked "outline stage, intent and issue body full"
jj_fx e-no-intent
rm -f "$(P_INTENT)"
req_run complexity "$F_PRODUCTION"
not_asked "intent.md absent" '["intent"]'
jj_fx e-empty-intent
: > "$(P_INTENT)"
req_run complexity "$F_PRODUCTION"
not_asked "intent.md empty" '["intent"]'
jj_fx e-big-intent
printf '# Intent\n\n%s\n' "$(big 20000 i)" > "$(P_INTENT)"
req_run complexity "$F_PRODUCTION"
not_asked "intent over the budget (truncated; issue body pushed out)" '["intent","issue body"]'
case_end

case_begin "e-required-issue-body" "hooks/lib/jev/two-stage/query.js"
jj_fx e-big-body "$(big 20000 b)"
req_run complexity "$F_PRODUCTION"
not_asked "issue body over the budget" '["issue body"]'
jj_fx e-no-issue "(none — no issue)"
printf '# Intent\n\n%s\n' "$(big 12000 i)" > "$(P_INTENT)"
req_run complexity "$F_PRODUCTION"
asked "NO_ISSUE_BODY context with a 12000-char intent" '["issue body"]'
jj_fx e-no-issue-ctl
printf '# Intent\n\n%s\n' "$(big 12000 i)" > "$(P_INTENT)"
req_run complexity "$F_PRODUCTION"
asked "same 12000-char intent with a real issue body"
check "real issue body: nothing exempt" "[]" "$(inp exempt)"
jj_fx e-no-context
rm -f "$FX/plans/$SID-context.md"
req_run complexity "$F_PRODUCTION"
not_asked "context.md absent is not exempt" '["issue body"]'
jj_fx e-detail-pushed
printf '# Intent\n\n%s\n' "$(big 7500 i)" > "$(P_INTENT)"
add_outline "$(big 9000 o)"
req_run detail "$F_PRODUCTION"
not_asked "detail stage, intent + outline use the budget"
check "detail stage: issue body is among the missing" "1" "$(inp missing | grep -c '"issue body"')"
case_end

case_begin "e-required-outline-exemption" "hooks/lib/jev/two-stage/query.js"
for st in pending complete; do
  jj_fx "e-outline-$st"
  seed_steps "{\"outline\":\"$st\"}"
  req_run detail "$F_PRODUCTION"
  not_asked "detail stage, outline.md absent, outline step $st" '["outline"]'
done
jj_fx e-outline-skipped
seed_steps '{"outline":"skipped"}'
req_run detail "$F_PRODUCTION"
asked "detail stage, outline.md absent, outline step skipped" '["outline"]'
jj_fx e-outline-badstate
seed_steps '{"outline":"skipped"}'
printf '{not json' > "$FX/wf/$SID.json"
req_run detail "$F_PRODUCTION"
not_asked "unreadable workflow state: outline is not exempt" '["outline"]'
case_end

case_begin "e-required-detail-stages" "hooks/lib/jev/two-stage/query.js"
jj_fx e-big-detail
add_outline
add_detail "$(big 20000 d)"
req_run write-tests "$F_PRODUCTION"
not_asked "write-tests, detail over the budget"
check "write-tests: detail is among the missing" "1" "$(inp missing | grep -c '"detail"')"
jj_fx e-detail-skipped
add_outline
seed_steps '{"detail":"skipped"}'
req_run write-tests "$F_PRODUCTION"
asked "write-tests, detail.md absent, detail step skipped"
check "write-tests: detail is exempt" "1" "$(inp exempt | grep -c '"detail"')"
jj_fx e-wc-full
add_outline; add_detail
printf 'bin/report\n' > "$FX/plans/$SID-write-code-files.txt"
req_run write-code "$F_PRODUCTION"
asked "write-code, intent / outline / detail / issue body full"
case_end

case_begin "e-required-copy-failure" "hooks/lib/jev/two-stage/query.js"
jj_fx e-copyfail-intent
req_run complexity "$(f_production_with '"failCopyFor":["intent"]')"
not_asked "failCopyFor intent (full in the snapshot)" '["intent"]'
check "failCopyFor intent: sources_failed and reason" '["intent"]|{"intent":"copy-failed"}' \
  "$(inp sources_failed)|$(inp sources_failed_reasons)"
jj_fx e-copyfail-outline
add_outline
req_run complexity "$(f_production_with '"failCopyFor":["outline"]')"
asked "failCopyFor outline at complexity (outline not required)"
check "failCopyFor outline: sources_failed outline, missing empty" '["outline"]|[]' \
  "$(inp sources_failed)|$(inp missing)"
case_end

case_begin "e-required-over-cap" "hooks/lib/jev/two-stage/query.js"
jj_fx e-overcap
mk_bytes "$(P_INTENT)" 4097
req_run complexity "$(f_production_with '"maxArtifactBytes":4096')"
not_asked "intent one byte over the read cap"
check "over-cap intent: missing and sources_failed name intent, reason over-cap" '1|1|"over-cap"' \
  "$(inp missing | grep -c '"intent"')|$(inp sources_failed | grep -c '"intent"')|$(lq "$TICKET" 'r && r.input && JSON.stringify(r.input.sources_failed_reasons.intent)')"
check "over-cap intent: p=0.99 never adopted (ADOPTED is not jev)" "no" "$([ "$(kv ADOPTED)" = "jev" ] && echo yes || echo no)"
no_secret_leak "e-required"
case_end
