#!/usr/bin/env bash
# Tests: bin/lib/jev-report-aggregate/retune.js, bin/lib/jev-report-aggregate.js
# Tags: TL2, bin, jev, report, retune, retune-policy, agreement-by-signal, skip-direction-band, run-direction, short-circuit, shadow, json-output, scope:issue-specific, pwsh-not-required
# Fragment of tests/bin/feature-2460-jev-report-accuracy.sh, sourced by it after _lib.sh (not
# standalone): the skip points' retune section. Only Jev skip-direction answers in the band
# [t, the record's own threshold.true) count toward a candidate t in {0.7, 0.8}; retune_ready
# needs >= 30 such records and >= 0.95 agreement for every key; run_direction is reported.

echo "=== retune: ready / not ready by count / not ready by agreement ==="
SA=sd_single_approach
SB=sd_no_open_decision
DSK='"detail-skip"'
# k7 <key> / k8 <key>: "n|agree|rate(4dp)" of detail-skip candidate 0.7 / 0.8 for <key>.
k7() { rjq "[K($DSK, \"0.7\", \"$1\").n, K($DSK, \"0.7\", \"$1\").agree, f4(K($DSK, \"0.7\", \"$1\").rate)].join(\"|\")"; }
k8() { rjq "[K($DSK, \"0.8\", \"$1\").n, K($DSK, \"0.8\", \"$1\").agree, f4(K($DSK, \"0.8\", \"$1\").rate)].join(\"|\")"; }
ready() { rjq "String(C($1, \"$2\").retune_ready)"; }

case_begin "retune-ready-at-0-7" "bin/lib/jev-report-aggregate/retune.js"
# 30 band answers per key on both skip points, every one agreed; plus complexity records.
fx_log ready '[
  range(30, () => D({ p: 0.75, sub: true })),
  range(30, () => D({ point: "outline-skip", p: 0.75, sub: true })),
  range(3, () => D({ point: "complexity-judge", p: 0.5, sub: true }))
]'
rep_json ready
check "fixture: 63 records; --json exits 0" "63|0" "$FXL_N|$REP_RC"
check "detail-skip t=0.7: both keys 30/30" "30|30|1.0000#30|30|1.0000" "$(k7 $SA)#$(k7 $SB)"
check "detail-skip t=0.7 retune_ready; t=0.8 (no answer in [0.8, 0.9)) not ready" "true|false" \
  "$(ready "$DSK" 0.7)|$(ready "$DSK" 0.8)"
check "outline-skip t=0.7 ready, its keys so_c1 / so_c2 each 30" "true|30|30" \
  "$(ready '"outline-skip"' 0.7)|$(rjq 'K("outline-skip", "0.7", "so_c1").n + "|" + K("outline-skip", "0.7", "so_c2").n')"
check "agreement_by_signal per key on both skip points (n 30, rate 1)" "30|1.0000|30|1.0000|30|1.0000" \
  "$(rjq '[R("detail-skip").agreement_by_signal?.sd_single_approach?.n, f4(R("detail-skip").agreement_by_signal?.sd_single_approach?.rate), R("detail-skip").agreement_by_signal?.sd_no_open_decision?.n, f4(R("detail-skip").agreement_by_signal?.sd_no_open_decision?.rate), R("outline-skip").agreement_by_signal?.so_c1?.n, f4(R("outline-skip").agreement_by_signal?.so_c1?.rate)].join("|")')"
check "the candidates are exactly 0.7 and 0.8 (no 0.9, no run-direction candidate)" "0.7,0.8|0.7,0.8" \
  "$(rjq 'Object.keys(R("detail-skip").candidates || {}).sort().join(",") + "|" + Object.keys(R("outline-skip").candidates || {}).sort().join(",")')"
check "retune covers the two skip points only (complexity-judge absent)" "detail-skip,outline-skip" \
  "$(rjq 'Object.keys(get(o, "retune", "points") || {}).sort().join(",")')"
check "production only: run_direction n 0" "0|0" \
  "$(rjq 'R("detail-skip").run_direction?.n + "|" + R("outline-skip").run_direction?.n')"
rep_text ready
check "text: each candidate names its band; no [0.9, band; the p >= current exclusion is explained" "true|true|false|true" \
  "$(tx '[text.includes("[0.7, 0.9)"), text.includes("[0.8, 0.9)"), text.includes("[0.9,"), /p\s*(≥|>=)\s*current/.test(text)].join("|")')"
check "text: run_direction with no data reads no data" "true" \
  "$(tx 'lines.some((l) => /run_direction/.test(l) && /no data/.test(l)) || lines.some((l, i) => /run_direction/.test(l) && /no data/.test(lines[i + 1] || ""))')"
check "text: the skip keys are listed by name" "true" "$(tx '["sd_single_approach", "sd_no_open_decision", "so_c1", "so_c2"].every((k) => text.includes(k))')"
case_end

case_begin "retune-not-ready-by-count" "bin/lib/jev-report-aggregate/retune.js"
# 29 records with both keys in band, one with only sd_single_approach in band (the other at 0.6).
fx_log count29 '[
  range(29, () => D({ p: 0.75, sub: true })),
  D({ p: { sd_single_approach: 0.75, sd_no_open_decision: 0.6 }, sub: true })
]'
rep_json count29
check "sd_no_open_decision has 29 band answers: not ready" "30|29|false" \
  "$(rjq 'K("detail-skip", "0.7", "sd_single_approach").n + "|" + K("detail-skip", "0.7", "sd_no_open_decision").n')|$(ready "$DSK" 0.7)"
# + 10 tickets where sd_no_open_decision was adopted at p >= 0.9 and the subagent (called for
# the other key) also said true: answers at or above the current threshold never count.
fx_log count29plus '[
  range(29, () => D({ p: 0.75, sub: true })),
  D({ p: { sd_single_approach: 0.75, sd_no_open_decision: 0.6 }, sub: true }),
  range(10, () => D({ p: { sd_single_approach: 0.75, sd_no_open_decision: 0.95 }, sub: true }))
]'
rep_json count29plus
check "+10 agreeing p>=0.9 answers: sd_no_open_decision still 29, still not ready" "40|29|false" \
  "$(rjq 'K("detail-skip", "0.7", "sd_single_approach").n + "|" + K("detail-skip", "0.7", "sd_no_open_decision").n')|$(ready "$DSK" 0.7)"
check "agreement_by_signal still counts every answered key (sd_no_open_decision n 40)" "40" \
  "$(rjq 'R("detail-skip").agreement_by_signal?.sd_no_open_decision?.n')"
case_end

case_begin "retune-not-ready-by-agreement" "bin/lib/jev-report-aggregate/retune.js"
# 30 band records; the subagent disagrees on sd_single_approach twice (28/30 < 0.95).
fx_log agree28 '[
  range(28, () => D({ p: 0.75, sub: true })),
  range(2, () => D({ p: 0.75, sub: { sd_single_approach: false, sd_no_open_decision: true } }))
]'
rep_json agree28
check "sd_single_approach 28/30 in band: not ready" "30|28|0.9333#false" "$(k7 $SA)#$(ready "$DSK" 0.7)"
fx_log agree28plus '[
  range(28, () => D({ p: 0.75, sub: true })),
  range(2, () => D({ p: 0.75, sub: { sd_single_approach: false, sd_no_open_decision: true } })),
  range(40, () => D({ p: { sd_single_approach: 0.95, sd_no_open_decision: 0.75 }, sub: true }))
]'
rep_json agree28plus
check "+40 agreeing p>=0.9 answers: the band rate stays 28/30, still not ready" "30|28|0.9333#false" \
  "$(k7 $SA)#$(ready "$DSK" 0.7)"
case_end

echo "=== retune: band edges, lowered thresholds, excluded records, run_direction ==="
case_begin "retune-band-t-0-8" "bin/lib/jev-report-aggregate/retune.js"
fx_log band08 '[
  range(30, () => D({ p: 0.85, sub: true })),
  range(20, () => D({ p: 0.75, sub: true }))
]'
rep_json band08
check "t=0.8 counts only [0.8, 0.9): 30 per key, ready" "30|30|1.0000#30|30|1.0000#true" "$(k8 $SA)#$(k8 $SB)#$(ready "$DSK" 0.8)"
check "t=0.7 counts [0.7, 0.9): 50 per key" "50|50" \
  "$(rjq 'K("detail-skip", "0.7", "sd_single_approach").n + "|" + K("detail-skip", "0.7", "sd_no_open_decision").n')"
case_end

case_begin "retune-lowered-threshold-records" "bin/lib/jev-report-aggregate/retune.js"
# Records written after threshold.true was lowered to 0.8: their band ends at 0.8.
fx_log lowered '[
  range(30, () => D({ thr: { true: 0.8, false: 0.7 }, p: 0.75, sub: true })),
  range(10, () => D({ thr: { true: 0.8, false: 0.7 }, p: { sd_single_approach: 0.85, sd_no_open_decision: 0.75 }, sub: true }))
]'
rep_json lowered
check "threshold.true 0.8 records never enter t=0.8" "0|0|false" \
  "$(rjq '["sd_single_approach", "sd_no_open_decision"].map((k) => C("detail-skip", "0.8").by_key ? (K("detail-skip", "0.8", k).n || 0) : "no-candidate").join("|")')|$(ready "$DSK" 0.8)"
check "t=0.7 counts only [0.7, 0.8): sd_single_approach 30 (0.85 excluded), sd_no_open_decision 40" "30|40" \
  "$(rjq 'K("detail-skip", "0.7", "sd_single_approach").n + "|" + K("detail-skip", "0.7", "sd_no_open_decision").n')"
case_end

case_begin "retune-excludes-final-short-circuit-run" "bin/lib/jev-report-aggregate/retune.js"
# 30 production band records, 5 all-final (llm null), 5 short-circuited (llm null), and
# shadow records: 4 + 1 run-direction answers on sd_single_approach, 3 p>=0.9 disagreements.
fx_log mixed '[
  range(30, () => D({ p: 0.75, sub: true })),
  range(5, () => D({ p: 0.95 })),
  range(5, () => D({ p: { sd_single_approach: 0.1, sd_no_open_decision: 0.75 } })),
  range(4, () => D({ mode: "shadow", p: { sd_single_approach: 0.2, sd_no_open_decision: 0.75 },
    sub: { sd_single_approach: false, sd_no_open_decision: true } })),
  D({ mode: "shadow", p: { sd_single_approach: 0.25, sd_no_open_decision: 0.75 }, sub: true }),
  range(3, () => D({ mode: "shadow", p: 0.95, sub: false }))
]'
rep_json mixed
check "fixture: 48 records; --json exits 0 (null llm records do not throw)" "48|0" "$FXL_N|$REP_RC"
check "t=0.7: run-direction and p>=0.9 answers excluded; shadow band answers included" "30|30|1.0000#35|35|1.0000#true" \
  "$(k7 $SA)#$(k7 $SB)#$(ready "$DSK" 0.7)"
check "agreement_by_signal: only records with both sides answered (n 38; 34 / 35 agree)" "38|0.8947|38|0.9211" \
  "$(rjq '[R("detail-skip").agreement_by_signal?.sd_single_approach?.n, f4(R("detail-skip").agreement_by_signal?.sd_single_approach?.rate), R("detail-skip").agreement_by_signal?.sd_no_open_decision?.n, f4(R("detail-skip").agreement_by_signal?.sd_no_open_decision?.rate)].join("|")')"
check "run_direction from shadow p<=0.3 answers: n 5, rate 4/5" "5|0.8000" \
  "$(rjq 'R("detail-skip").run_direction?.n + "|" + f4(R("detail-skip").run_direction?.rate)')"
case_end
