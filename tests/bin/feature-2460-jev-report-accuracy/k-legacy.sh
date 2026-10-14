#!/usr/bin/env bash
# Tests: bin/lib/jev-report-aggregate.js, bin/jev-report
# Tags: TL2, bin, jev, report, legacy, version-routing, unknown-version, s1b-removed, json-output, scope:issue-specific, pwsh-not-required
# Fragment of tests/bin/feature-2460-jev-report-accuracy.sh, sourced by it after _lib.sh (not
# standalone): version routing. A v1 record lands only in the legacy summary, a v2 record only
# in the adoption / retune sections, and anything else (no version key, version 3, v "1" as a
# string) is counted as unknown_version and appears in neither.

echo "=== legacy: v1 and v2 records never mix ==="
case_begin "legacy-version-routing" "bin/lib/jev-report-aggregate.js"
fx_log legacy '[
  range(2, () => V1({})),
  range(30, () => V1({ point: "detail-skip" })),
  range(3, () => D({ p: 0.75, sub: true })),
  range(2, () => D({ point: "complexity-judge", p: 0.5, sub: true })),
  D({ p: 0.75, sub: true, top: { version: undefined } }),
  D({ p: 0.75, sub: true, top: { version: 3 } }),
  V1({ point: "detail-skip", top: { v: "1" } })
]'
rep_json legacy
check "fixture: 40 records; --json exits 0" "40|0" "$FXL_N|$REP_RC"
check "legacy summary holds only the v1 records (2 complexity-judge, 30 detail-skip)" "2|30" \
  "$(rjq 'L("complexity-judge").count + "|" + L("detail-skip").count')"
check "adoption holds only the v2 records (3 detail-skip, 2 complexity-judge, 5 overall)" "3|2|5" \
  "$(rjq 'A("detail-skip").count + "|" + A("complexity-judge").count + "|" + AO().count')"
check "retune counts only v2 band answers (3), never the 30 v1 detail-skip records" "3|3" \
  "$(rjq 'K("detail-skip", "0.7", "sd_single_approach").n + "|" + K("detail-skip", "0.7", "sd_no_open_decision").n')"
check "no version key / version 3 / v \"1\" string are unknown_version" "3" "$(rjq 'get(o, "unknown_version")')"
check "the legacy summary no longer carries an S1b-without-S1 count" "false|false" \
  "$(rjq '["complexity-judge", "detail-skip"].map((p) => JSON.stringify(L(p)).includes("s1b")).join("|")')"
rep_text legacy
check "text: exit 0" "0" "$REP_RC"
check "text: exactly one heading marks the legacy (v1) section" "1" \
  "$(tx 'lines.filter((l) => /legacy/i.test(l) && /v1/.test(l)).length')"
check "text: no S1b without S1 line" "false" "$(tx 'text.includes("S1b without S1")')"
check "text: unknown_version is shown" "true" "$(tx 'lines.some((l) => /unknown_version/.test(l) && /\b3\b/.test(l))')"
case_end
