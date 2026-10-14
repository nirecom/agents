#!/usr/bin/env bash
# Tests: bin/lib/jev-report-aggregate.js, bin/lib/jev-report-aggregate/adoption.js, bin/lib/jev-report-aggregate/retune.js
# Tags: TL2, bin, jev, report, dedupe-ticket, duplicate-ticket-records, crash-recovery, hook-record, json-output, scope:issue-specific, pwsh-not-required
# Fragment of tests/bin/feature-2460-jev-report-accuracy.sh, sourced by it after _lib.sh (not
# standalone): the same (ticket, record_type) appended twice (a finalize retried after a crash
# between the append and the state write) counts once, first record kept, and the extras are
# reported as duplicate_ticket_records. Ticket-less hook records and v1 records are never deduped.

echo "=== dedupe: one ticket, one decision ==="
case_begin "dedupe-first-record-kept" "bin/lib/jev-report-aggregate.js"
# The duplicate differs from the first record (adopted / mode) so the kept one is identifiable.
fx_log dup '[
  D({ ticket: "00000000000d0001", p: 0.75, sub: true }),
  D({ ticket: "00000000000d0001", p: 0.75, sub: true, mode: "shadow", top: { adopted: "jev" } }),
  D({ ticket: "00000000000d0002", p: { sd_single_approach: 0.1, sd_no_open_decision: 0.75 } }),
  D({ ticket: "00000000000d0002", p: { sd_single_approach: 0.1, sd_no_open_decision: 0.75 } })
]'
rep_json dup
check "fixture: 4 records; --json exits 0" "4|0" "$FXL_N|$REP_RC"
check "two tickets counted once each; duplicate_ticket_records 2" "2|2" \
  "$(rjq 'A("detail-skip").count + "|" + get(o, "duplicate_ticket_records")')"
check "the first record is kept: adopted llm 1 / jev 1, by_mode production 2, no shadow" "1|1|2|0" \
  "$(rjq '[A("detail-skip").adopted?.llm, A("detail-skip").adopted?.jev, A("detail-skip").by_mode?.production, A("detail-skip").by_mode?.shadow || 0].join("|")')"
check "llm_needed_rate and short_circuit_count use the deduped records (1/2, 1)" "0.5000|1" \
  "$(rjq 'f4(A("detail-skip").llm_needed_rate) + "|" + A("detail-skip").short_circuit_count')"
check "agreement_by_signal and retune count the duplicated band answer once" "1|1" \
  "$(rjq 'R("detail-skip").agreement_by_signal?.sd_single_approach?.n + "|" + K("detail-skip", "0.7", "sd_single_approach").n')"
rep_text dup
check "text: duplicate_ticket_records is shown with its count" "true" \
  "$(tx 'lines.some((l) => /duplicate_ticket_records/.test(l) && /\b2\b/.test(l))')"
case_end

case_begin "dedupe-scope-limits" "bin/lib/jev-report-aggregate.js"
# A decision and a settle on one ticket are different record types; ticket-less hook records
# with identical content are distinct events; v1 records are no ticket duplicates either.
fx_log scope '[
  D({ ticket: "00000000000e0001", p: 0.75, sub: true }),
  S({ ticket: "00000000000e0009", point: "outline-skip", detail: "unowned-write" }),
  D({ ticket: "00000000000e0009", point: "outline-skip", p: 0.75, sub: true }),
  D({ ticket: null, point: "complexity-judge", p: 0.5, sub: true, top: { tool_use_id: "toolu_same", ts: "2026-10-02T01:00:00Z" } }),
  D({ ticket: null, point: "complexity-judge", p: 0.5, sub: true, top: { tool_use_id: "toolu_same", ts: "2026-10-02T01:00:00Z" } }),
  V1({ top: { tool_use_id: "toolu_v1_same", ts: "2026-10-02T02:00:00Z" } }),
  V1({ top: { tool_use_id: "toolu_v1_same", ts: "2026-10-02T02:00:00Z" } })
]'
rep_json scope
check "fixture: 7 records; --json exits 0" "7|0" "$FXL_N|$REP_RC"
check "no duplicate_ticket_records for decision + settle, null tickets, or v1" "0" "$(rjq 'get(o, "duplicate_ticket_records")')"
check "ticket-null hook records both counted (complexity-judge 2)" "2" "$(rjq 'A("complexity-judge").count')"
check "v1 records sharing a tool_use_id: one judgment in legacy, by its own per-judgment rule" "1|1" \
  "$(rjq 'L("complexity-judge").count + "|" + L("complexity-judge").duplicates_dropped')"
check "detail-skip decision counted; settle record is no decision" "1" "$(rjq 'A("detail-skip").count')"
check "the settled outline-skip ticket is superseded, not a duplicate (count 0, superseded 1)" "0|1" \
  "$(rjq '(A("outline-skip").count || 0) + "|" + A("outline-skip").superseded_count')"
case_end

case_begin "dedupe-keeps-retune-below-30" "bin/lib/jev-report-aggregate/retune.js"
fx_log dup29 '[
  range(29, (i) => D({ ticket: "00000000000f" + String(i).padStart(4, "0"), p: 0.75, sub: true })),
  D({ ticket: "00000000000f0000", p: 0.75, sub: true })
]'
rep_json dup29
check "29 tickets + 1 duplicate: n 29, not ready, duplicate_ticket_records 1" "29|false|1" \
  "$(rjq 'K("detail-skip", "0.7", "sd_single_approach").n + "|" + String(C("detail-skip", "0.7").retune_ready) + "|" + get(o, "duplicate_ticket_records")')"
case_end
