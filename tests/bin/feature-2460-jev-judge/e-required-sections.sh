#!/usr/bin/env bash
# Tests: hooks/lib/jev/two-stage/query.js, bin/workflow/lib/jev-request-common.js
# Tags: TL2, bin, jev, two-stage, required-sections, section-exemptions, read-cap, copy-failure, input-insufficient, plan-sections, mock-server, scope:issue-specific, pwsh-not-required
# Fragment of tests/bin/feature-2460-jev-judge.sh, sourced after _lib.sh (not standalone):
# Jev is asked only when every required section of the point x stage is full in the
# Jev input and was copied whole; otherwise every key goes to the subagent and the record
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
# B: the module's Jev input budget; oversized fixtures are sized from it, never a literal.
# B_RAW keeps what the module answered, so budget_ok judges it and not the B=0 stand-in.
B_RAW="$(jev_budget)"
budget_ok() { check "fixture: the Jev input budget is a number" "yes" "$([[ "$B_RAW" =~ ^[0-9]+$ ]] && echo yes || echo no)"; }
B="$B_RAW"
[[ "$B" =~ ^[0-9]+$ ]] || B=0

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
budget_ok
printf '# Intent\n\n%s\n' "$(big "$B" i)" > "$(P_INTENT)"
req_run complexity "$F_PRODUCTION"
not_asked "intent over the budget (truncated; issue body pushed out)" '["intent","issue body"]'
case_end

case_begin "e-required-issue-body" "hooks/lib/jev/two-stage/query.js"
budget_ok
jj_fx e-big-body "$(big "$B" b)"
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
printf '# Intent\n\n%s\n' "$(big "$((B / 2))" i)" > "$(P_INTENT)"
add_outline "$(big "$((B / 2))" o)"
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

# #2701: write-tests / write-code require only the issue body; detail, outline and intent are
# plan sections, and one of them full or truncated is enough (write-tests and write-code alike).
case_begin "e-required-detail-stages" "hooks/lib/jev/two-stage/query.js"
for st in write-tests write-code; do
  jj_fx "e-big-detail-$st"
  add_outline
  budget_ok
  add_detail "$(big "$B" d)"
  printf 'bin/report\n' > "$FX/plans/$SID-write-code-files.txt"
  req_run "$st" "$F_PRODUCTION"
  asked "$st, detail over the budget (truncated plan section counts)"
  check "$st, detail over the budget: input.missing empty" "[]" "$(inp missing)"
  check "$st, detail over the budget: detail truncated, outline and issue body full" "truncated|full|full" \
    "$(jev_input_state detail)|$(jev_input_state outline)|$(jev_input_state 'issue body')"
  jj_fx "e-no-detail-$st"
  add_outline
  printf 'bin/report\n' > "$FX/plans/$SID-write-code-files.txt"
  req_run "$st" "$F_PRODUCTION"
  asked "$st, detail.md absent, outline and intent stand in"
  check "$st, detail.md absent: input.missing empty" "[]" "$(inp missing)"
  jj_fx "e-full-$st"
  add_outline; add_detail
  printf 'bin/report\n' > "$FX/plans/$SID-write-code-files.txt"
  req_run "$st" "$F_PRODUCTION"
  asked "$st, intent / outline / detail / issue body full"
done
case_end

case_begin "e-required-plan-sections-absent" "hooks/lib/jev/two-stage/query.js"
for st in write-tests write-code; do
  jj_fx "e-no-plan-$st"
  rm -f "$(P_INTENT)"
  printf 'bin/report\n' > "$FX/plans/$SID-write-code-files.txt"
  req_run "$st" "$F_PRODUCTION"
  not_asked "$st, intent / outline / detail all absent" '["detail","intent","outline"]'
  jj_fx "e-only-intent-$st"
  printf 'bin/report\n' > "$FX/plans/$SID-write-code-files.txt"
  req_run "$st" "$F_PRODUCTION"
  asked "$st, only intent present"
  check "$st, only intent present: input.missing empty" "[]" "$(inp missing)"
  jj_fx "e-plan-no-context-$st"
  add_outline; add_detail
  rm -f "$FX/plans/$SID-context.md"
  printf 'bin/report\n' > "$FX/plans/$SID-write-code-files.txt"
  req_run "$st" "$F_PRODUCTION"
  not_asked "$st, plan sections full but context.md absent" '["issue body"]'
done
case_end

# #2701: sizes modeled on a real write-code session (intent 3700 / outline 4600 / detail 17000 /
# issue body 2500); together they exceed the old 16000 cap, so this fails on a shared budget.
# The detail fits whole, so every plan section is full.
case_begin "e-required-write-code-realistic" "hooks/lib/jev/two-stage/query.js"
jj_fx e-wc-real "$(big 2500 b)"
printf '# Intent\n\n%s\n' "$(big 3700 i)" > "$(P_INTENT)"
add_outline "$(big 4600 o)"
add_detail "$(big 17000 d)"
printf 'bin/report\n' > "$FX/plans/$SID-write-code-files.txt"
mock_mode '{"echo":true,"defaultP":0.99,"capture":true}'
ts_query write-code complexity-judge "$F_PRODUCTION"
check "realistic write-code: Jev asked exactly once" "1" "$(mock_count systemone)"
check "realistic write-code: the Jev request carries the JEV_INPUT_FILE bytes exactly" "equal" \
  "$(tpb body-match "$(np "$MOCK_REQ")" "$(np "$JEV_INPUT")")"
check "realistic write-code: the Jev input is larger than the old 16000 cap" "yes" \
  "$([ -f "$JEV_INPUT" ] && [ "$(wc -c < "$JEV_INPUT" | tr -d ' ')" -gt 16000 ] && echo yes || echo no)"
check "realistic write-code: ticket input.missing is empty" "[]" "$(tk input.missing)"
check "realistic write-code: issue body / detail / outline / intent all full" "full|full|full|full" \
  "$(jev_input_state 'issue body')|$(jev_input_state detail)|$(jev_input_state outline)|$(jev_input_state intent)"
check "realistic write-code: ticket required is the issue body only" '["issue body"]' "$(tk required)"
# Finalize: the Jev answer stands, so the decision record carries no fallback reason.
answer_with "SIGNALS: none"
jj finalize --session "$SID" --ticket "$TICKET"
check "realistic write-code: finalize records no fallback_reason (Jev ran, input sufficient)" "null" "$(fb)"
check "realistic write-code: decision record input.missing is empty" "[]" "$(inp missing)"
check "realistic write-code: decision record jev.status is ok" "ok" "$(lq "$TICKET" 'r && r.jev ? String(r.jev.status) : "no-record"')"
case_end

# #2701 plan-section copy failures: one failed plan copy leaves the others usable; every plan
# copy failing is insufficient. A failed copy never counts as a present plan section.
for st in write-tests write-code; do
  case_begin "e-required-plan-copy-failure-$st" "hooks/lib/jev/two-stage/query.js"
  jj_fx "e-plancopy-one-$st"
  add_outline
  add_detail
  printf 'bin/report\n' > "$FX/plans/$SID-write-code-files.txt"
  req_run "$st" "$(f_production_with '"failCopyFor":["detail"]')"
  asked "$st, detail copy failed but outline and intent usable"
  check "$st, detail copy failed: input.missing empty, sources_failed detail" '[]|["detail"]' "$(inp missing)|$(inp sources_failed)"
  jj_fx "e-plancopy-all-$st"
  add_outline
  add_detail
  printf 'bin/report\n' > "$FX/plans/$SID-write-code-files.txt"
  req_run "$st" "$(f_production_with '"failCopyFor":["detail","outline","intent"]')"
  not_asked "$st, every plan copy failed" '["detail","intent","outline"]'
  case_end
done

case_begin "e-required-copy-failure" "hooks/lib/jev/two-stage/query.js"
jj_fx e-copyfail-intent
req_run complexity "$(f_production_with '"failCopyFor":["intent"]')"
not_asked "failCopyFor intent (full in the Jev input)" '["intent"]'
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

# The no-issue exemption reads context.md under the read cap. A file cut at the cap has no
# trustworthy closing heading, so nothing in the prefix reads as the bare no-issue marker.
READ_CAP=1048576
NO_ISSUE="(none — no issue)"
# ctx_sized <bytes> <body>: context.md of exactly <bytes>, padded after its Issue metadata heading.
ctx_sized() {
  local f="$FX/plans/$SID-context.md" n
  printf '# Context\n\n## Issue body\n\n%s\n\n## Issue metadata\n\n' "$2" > "$f"
  n="$(wc -c < "$f" | tr -d ' ')"
  head -c "$(( $1 - n ))" /dev/zero | tr '\0' 'x' >> "$f"
  check "fixture: context.md is exactly $1 bytes" "$1" "$(wc -c < "$f" | tr -d ' ')"
}
issue_req() { tpb required "$SID" '["issue body"]' '{"issue body":"absent"}' '[]'; }
EXEMPT='{"met":true,"missing":[],"exempt":["issue body"]}'
NOT_EXEMPT='{"met":false,"missing":["issue body"],"exempt":[]}'

case_begin "e-required-issue-body-read-cap" "bin/workflow/lib/jev-request-common.js"
jj_fx e-cap-small "$NO_ISSUE"
check "control, no-issue body in a short context.md: exempt" "$EXEMPT" "$(issue_req)"
jj_fx e-cap-metadata
ctx_sized 4096 "$NO_ISSUE"
check "no-issue body closed by Issue metadata: exempt" "$EXEMPT" "$(issue_req)"
jj_fx e-cap-at
ctx_sized "$READ_CAP" "$NO_ISSUE"
check "context.md exactly at the read cap: read whole, exempt" "$EXEMPT" "$(issue_req)"
jj_fx e-cap-over
ctx_sized "$((READ_CAP + 1))" "$NO_ISSUE"
check "context.md one byte over the read cap: not exempt" "$NOT_EXEMPT" "$(issue_req)"
jj_fx e-cap-extra
ctx_sized 4096 "$NO_ISSUE and one more line"
check "body with more than the no-issue marker: not exempt" "$NOT_EXEMPT" "$(issue_req)"
jj_fx e-cap-own-heading
ctx_sized 4096 "$(printf '%s\n\n## Issue metadata\n\nAn issue that quotes the closing heading.' "$NO_ISSUE")"
check "body carrying its own Issue metadata line: the last one closes it, not exempt" "$NOT_EXEMPT" "$(issue_req)"
case_end
