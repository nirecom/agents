#!/usr/bin/env bash
# Tests: bin/lib/jev-report-aggregate.js, bin/lib/jev-report-aggregate/adoption.js, bin/lib/jev-report-aggregate/retune.js
# Tags: TL2, bin, jev, report, superseded, settle-record, superseded-count, json-output, scope:issue-specific, pwsh-not-required
# Fragment of tests/bin/feature-2460-jev-report-accuracy.sh, sourced by it after _lib.sh (not
# standalone): a ticket with a settle(superseded) record never reached the workflow state, so
# its decision is left out of every rate, agreement and retune count and is reported only as
# superseded_count (per point and overall), whatever the settle detail.

echo "=== superseded: a settled ticket is out of every figure ==="
case_begin "superseded-excluded-from-rates" "bin/lib/jev-report-aggregate.js"
# 30 band records; the superseded one is also the only disagreeing answer.
fx_log sup '[
  range(29, () => D({ p: 0.75, sub: true })),
  D({ ticket: "000000000005a001", p: 0.75, sub: { sd_single_approach: false, sd_no_open_decision: true } }),
  S({ ticket: "000000000005a001" })
]'
rep_json sup
check "fixture: 31 records; --json exits 0" "31|0" "$FXL_N|$REP_RC"
check "superseded_count 1 on detail-skip and overall" "1|1|1" \
  "$(rjq 'A("detail-skip").superseded_count + "|" + AO().superseded_count + "|" + get(o, "superseded_count")')"
check "rates are over the 29 remaining decisions" "29|29|1.0000|1.0000" \
  "$(rjq '[A("detail-skip").count, A("detail-skip").adopted?.llm, f4(A("detail-skip").llm_needed_rate), f4(A("detail-skip").llm_answer_received_rate)].join("|")')"
check "agreement_by_signal excludes the superseded disagreement (29, rate 1)" "29|1.0000" \
  "$(rjq 'R("detail-skip").agreement_by_signal?.sd_single_approach?.n + "|" + f4(R("detail-skip").agreement_by_signal?.sd_single_approach?.rate)')"
check "retune: n 29, not ready" "29|false" \
  "$(rjq 'K("detail-skip", "0.7", "sd_single_approach").n + "|" + String(C("detail-skip", "0.7").retune_ready)')"
check "the settle record itself is not a decision, not a duplicate, not unknown" "0|0" \
  "$(rjq 'get(o, "duplicate_ticket_records") + "|" + get(o, "unknown_version")')"
rep_text sup
check "text: superseded_count is shown" "true" "$(tx 'lines.some((l) => /superseded/.test(l) && /\b1\b/.test(l))')"
case_end

case_begin "superseded-complexity-by-ticket" "bin/lib/jev-report-aggregate/adoption.js"
# Three complexity decisions with the same final contract line; two settled (newer-owner,
# unowned-write). Only settled tickets are excluded: matching is by ticket, never by content.
fx_log supc '[
  D({ point: "complexity-judge", ticket: "000000000005c001", p: 0.5, sub: true }),
  D({ point: "complexity-judge", ticket: "000000000005c002", p: 0.5, sub: true }),
  D({ point: "complexity-judge", ticket: "000000000005c003", p: 0.5, sub: true }),
  S({ point: "complexity-judge", ticket: "000000000005c001", detail: "newer-owner" }),
  S({ point: "complexity-judge", ticket: "000000000005c002", detail: "unowned-write", owner: null })
]'
rep_json supc
check "fixture: 5 records; --json exits 0" "5|0" "$FXL_N|$REP_RC"
check "superseded_count 2 for complexity-judge, whatever the settle detail" "2|2" \
  "$(rjq 'A("complexity-judge").superseded_count + "|" + AO().superseded_count')"
check "the unsettled decision alone remains (count 1, adopted llm 1)" "1|1" \
  "$(rjq 'A("complexity-judge").count + "|" + A("complexity-judge").adopted?.llm')"
check "no point other than complexity-judge reports a superseded ticket" "0" \
  "$(rjq 'get(o, "adoption", "points") ? Object.keys(get(o, "adoption", "points")).filter((p) => p !== "complexity-judge" && A(p).superseded_count).length : "no-adoption"')"
case_end
