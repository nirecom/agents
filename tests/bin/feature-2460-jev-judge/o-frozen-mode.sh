#!/usr/bin/env bash
# Tests: hooks/lib/jev/two-stage/finalize.js
# Tags: TL2, bin, jev, two-stage, frozen-policy, registry-change, replay, orphan, ticket-invalid, mock-server, scope:issue-specific, pwsh-not-required
# Fragment of tests/bin/feature-2460-jev-judge.sh, sourced after _lib.sh (not standalone):
# mode, recording owner, record_decision, threshold and short-circuit are frozen into the
# ticket at query time. finalize, replay and the orphan record use only those frozen values,
# and a registry change after the query matters only when the point or stage is unregistered.

echo "=== jev-judge: query-time policy freeze ==="
need_mod bin/workflow/jev-judge || return 0
need_mod hooks/lib/jev/two-stage/query.js || return 0
need_mod hooks/lib/jev/two-stage/finalize.js || return 0
. "$JJ_DIR/two-stage-lib.sh"

Q_PROD='{"entryPatch":{"complexity-judge":{"mode":"production","confidence_threshold_by_answer":{"true":0.7,"false":0.7},"short_circuit_answer":null}}}'
F_SHADOW='{"entryPatch":{"complexity-judge":{"mode":"shadow","confidence_threshold_by_answer":{"true":0.99,"false":0.99}}}}'
decisions() { lq "$TICKET" 'recs.filter(x=>x.record_type==="decision").length'; }
policy_rec() { lq "$TICKET" 'r ? [r.mode, JSON.stringify(r.threshold), String(r.short_circuit_answer)].join("|") : "no-record"'; }
PROD_POLICY='production|{"true":0.7,"false":0.7}|null'

case_begin "o-frozen-production-finalized-as-shadow" "hooks/lib/jev/two-stage/finalize.js"
jj_fx o-prod
mock_p 0.01
ts_query complexity complexity-judge "$Q_PROD"
check "production query: RESULT=final" "final" "$(kv RESULT)"
check "ticket freezes mode / recording_owner / record_decision" '"production"|"cli"|true' \
  "$(tk mode)|$(tk recording_owner)|$(tk record_decision)"
ts_fin "$F_SHADOW"
check "finalize under a shadow/0.99 entry: exit 0" "0" "$TS_RC"
check "MODE= is the frozen production" "production" "$(kv MODE)"
check "ADOPTED=jev (0.99 threshold not re-applied)" "jev" "$(kv ADOPTED)"
check "decision log: frozen mode / threshold / short_circuit_answer" "$PROD_POLICY" "$(policy_rec)"
check "decision log: CLI wrote exactly one decision (frozen recording_owner=cli)" "1" "$(decisions)"
check "fixed file follows the query-time gate (all p=0.01: none)" "" "$(fixed_csv complexity)"
case_end

case_begin "o-frozen-record-decision-vs-jev-toggle" "hooks/lib/jev/two-stage/finalize.js"
jj_fx o-jev-on
mock_p 0.01
ts_query complexity complexity-judge "$Q_PROD" -- JEV=on
check "JEV=on query: record_decision true" "true" "$(tk record_decision)"
jj finalize --session "$SID" --ticket "$TICKET" -- JEV=off
check "JEV=off at finalize: exit 0" "0" "$JJ_RC"
check "JEV=off at finalize: the frozen record_decision still writes one record" "1" "$(decisions)"
jj_fx o-jev-off
mock_p 0.01
ts_query complexity complexity-judge "$Q_PROD" -- JEV=off
check "JEV=off query: record_decision false, Jev not asked" "false|0" "$(tk record_decision)|$(mock_count systemone)"
answer_with "SIGNALS: none"
jj finalize --session "$SID" --ticket "$TICKET" -- JEV=on
check "JEV=on at finalize: exit 0" "0" "$JJ_RC"
check "JEV=on at finalize: still no decision record" "0" "$(log_count)"
case_end

case_begin "o-frozen-replay-rerun" "hooks/lib/jev/two-stage/finalize.js"
jj_fx o-rerun
mock_p 0.01
ts_query complexity complexity-judge "$Q_PROD"
ts_fin '{"crashAt":"after-wal"}'
check "crashAt after-wal: probe stopped with 99" "99" "$TS_RC"
ts_fin "$F_SHADOW"
check "re-run under a changed entry: exit 0, MODE=production" "0|production" "$TS_RC|$(kv MODE)"
check "re-run: decision log keeps the frozen policy" "$PROD_POLICY" "$(policy_rec)"
check "re-run: one decision record" "1" "$(decisions)"
case_end

case_begin "o-frozen-replay-sweep" "hooks/lib/jev/two-stage/finalize.js"
jj_fx o-sweep
mock_p 0.01
ts_query complexity complexity-judge "$Q_PROD"
ts_fin '{"crashAt":"after-wal"}'
sleep 1.1
tsp sweep "$SID" 1
check "sweep replay: exit 0" "0" "$TS_RC"
check "sweep replay: decision log keeps the frozen policy" "$PROD_POLICY" "$(policy_rec)"
check "sweep replay: one decision record" "1" "$(decisions)"
jj finalize --session "$SID" --ticket "$TICKET"
check "after the sweep replay: finalize replays MODE=production" "production" "$(kv MODE)"
jj_fx o-orphan
mock_p 0.01 S2-architecture 0.5
ts_query complexity complexity-judge "$Q_PROD"
sleep 1.1
tsp sweep "$SID" 1
check "finalize-absent orphan: mode and threshold from the ticket" "$PROD_POLICY|finalize-absent" \
  "$(policy_rec)|$(lq "$TICKET" 'r && r.fallback_reason')"
case_end

case_begin "o-frozen-invalid-only-on-registration" "hooks/lib/jev/two-stage/finalize.js"
jj_fx o-unstaged
mock_p 0.01
ts_query complexity complexity-judge "$Q_PROD"
ts_fin '{"entryPatch":{"complexity-judge":{"stages":["outline"]}}}'
check "stage no longer registered: exit 4, ticket-invalid, two lines" "4|error|ticket-invalid|2" \
  "$TS_RC|$(kv RESULT)|$(kv REASON)|$(out_lines)"
check "stage no longer registered: no decision record" "0" "$(log_count)"
jj_fx o-unregistered
mock_p 0.01
ts_query complexity complexity-judge "$Q_PROD"
ts_fin '{"entryPatch":{"complexity-judge":null}}'
check "point no longer registered: exit 4, ticket-invalid" "4|ticket-invalid" "$TS_RC|$(kv REASON)"
case_end

# Shadow on the CLI path (no subagent_type: the CLI owns the record). Jev is asked so its
# probabilities are recorded, but no key is adopted from it, even at p=0.99 / 0.01.
case_begin "o-shadow-cli-path" "hooks/lib/jev/two-stage/finalize.js"
jj_fx o-shadow-cli
mock_p 0.99 S2-architecture 0.01
ts_query complexity complexity-judge "$F_SHADOW_CLI"
check "shadow CLI query: RESULT=need-subagent at p=0.99/0.01" "0|need-subagent" "$TS_RC|$(kv RESULT)"
check "shadow CLI query: every key delegated" "s2_architecture,s3_security,s5_breaking" "$(keyset "$(kv DELEGATED)")"
check "shadow CLI query: frozen mode shadow, recording owner cli, Jev asked once" '"shadow"|"cli"|1' \
  "$(tk mode)|$(tk recording_owner)|$(mock_count systemone)"
answer_with "SIGNALS: S3-security"
jj finalize --session "$SID" --ticket "$TICKET"
check "shadow CLI finalize: ADOPTED=llm, MODE=shadow" "0|llm|shadow" "$JJ_RC|$(kv ADOPTED)|$(kv MODE)"
check "shadow CLI finalize: SIGNALS_CSV is the subagent answer, not Jev's" "S3-security" "$(kv SIGNALS_CSV)"
check "shadow CLI finalize: fixed file holds the subagent answer" "S3-security" "$(fixed_csv complexity)"
check "shadow CLI: exactly one decision record, written by the CLI" "1" "$(decisions)"
check "shadow CLI: decision record mode shadow, Jev probabilities kept" "shadow|1|1" \
  "$(lq "$TICKET" 'r && r.mode')|$(lq "$TICKET" 'r && JSON.stringify(r.jev||null).includes("0.99") ? 1 : 0')|$(lq "$TICKET" 'r && JSON.stringify(r.jev||null).includes("0.01") ? 1 : 0')"
case_end

# Mirror: shadow with a subagent_type makes the hook the recording owner, so the CLI neither
# asks Jev nor writes a decision record.
case_begin "o-shadow-hook-owner" "hooks/lib/jev/two-stage/finalize.js"
jj_fx o-shadow-hook
mock_p 0.99 S2-architecture 0.01
ts_query complexity complexity-judge "$F_SHADOW_HOOK"
check "shadow hook-owner query: exit 0, recording owner hook" '0|"hook"' "$TS_RC|$(tk recording_owner)"
check "shadow hook-owner query: Jev not asked by the CLI" "0" "$(mock_count systemone)"
answer_with "SIGNALS: S3-security"
jj finalize --session "$SID" --ticket "$TICKET"
check "shadow hook-owner finalize: exit 0, MODE=shadow" "0|shadow" "$JJ_RC|$(kv MODE)"
check "shadow hook-owner: the CLI wrote no decision record" "0" "$(log_count)"
case_end

case_begin "o-frozen-detail-skip-shadow" "hooks/lib/jev/two-stage/finalize.js"
if need_mod bin/workflow/lib/jev-skip-adapter.js; then
  jj_fx o-skip
  printf '# Outline\n\nTouch only the report CLI.\n' > "$FX/plans/$SID-outline.md"
  mock_p 0.99
  ts_query outline detail-skip '{"entryPatch":{"detail-skip":{"mode":"shadow"}}}'
  check "detail-skip shadow query: RESULT=need-subagent even at p=0.99" "need-subagent" "$(kv RESULT)"
  ts_fin '{"entryPatch":{"detail-skip":{"mode":"production"}}}'
  check "finalize under production: MODE=shadow" "shadow" "$(kv MODE)"
  check "decision log mode shadow, ADOPTED not jev" "shadow|no" \
    "$(lq "$TICKET" 'r && r.mode')|$([ "$(kv ADOPTED)" = "jev" ] && echo yes || echo no)"
fi
no_secret_leak "o-frozen"
case_end
