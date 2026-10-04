#!/usr/bin/env bash
# Tests: bin/lib/jev-report-aggregate.js
# Tags: TL1, bin, jev, report, dedupe, merge-sides, agreement, scope:issue-specific, pwsh-not-required
# Fragment of tests/bin/feature-2460-jev-report-accuracy.sh, sourced by it after _lib.sh (not
# standalone). An orphan sweep (Jev side, llm missing) and a late post (LLM side, jev not-run)
# of one judgment fold into one record whose agreement is compare() recomputed, never a stored
# value; every other duplicate keeps the "most informative, earliest on a tie" rule.
# TL3 gap (what this test does NOT catch): a real orphan sweep racing a real late post;
# the split records here are hand-built in the shape the hooks write them.

PROBE_JS="$TMPROOT/dedupe-probe.js"
# probe <scenario>: aggregatePoint over the scenario's records. Prints
#   count|dropped|stages|agreement_n|agreement_rate|mismatches|jev p95|llm p95|cmp
# where mismatches is stage:jev:llm rows and cmp says whether the kept agreement and its
# per-signal ratios equal compare() of the scenario's Jev side against its LLM side
# ("-" for scenarios that must not merge).
cat > "$PROBE_JS" <<'JS'
"use strict";
const [aggPath, recPath, scenario] = process.argv.slice(2);
const { aggregatePoint } = require(aggPath);
const { compare } = require(recPath);
const S1 = "S1-multi-file";
const S1B = "S1b-wide-change";
const S2 = "S2-architecture";
const NONE = { status: "missing", answer: null, latency_ms: null };
const NOTRUN = { status: "not-run", answer: null, latency_ms: null };
// rec(stage, jev, llm, stored): one log record of sid-d/toolu_d; stored is its own agreement.
const rec = (stage, jev, llm, stored) => ({ v: 1, point: "complexity-judge", ts: "2026-10-01T00:00:01Z",
  session_id: "sid-d", tool_use_id: "toolu_d", stage, jev, llm, fallback_reason: null,
  agreement: stored === undefined ? null : stored,
  agreement_by_signal: stored === undefined ? null : { [S1]: stored } });
const jevOk = (answer, latency_ms) => ({ status: "ok", answer, latency_ms, est_cost_usd: 0.5 });
const llmOk = (answer, latency_ms) => ({ status: "ok", answer, latency_ms });
// Each scenario: [records, jev side, llm side] -- the sides only for a split that must merge.
const SC = {
  // Both records ran both sides: the earliest wins as stored (a lie on purpose: S1 vs S2
  // stored as agreeing), so a recompute would show up as agreement 0.
  "both-ran-tie": [[rec("d1", jevOk(S1, 11), llmOk(S2, 21), true), rec("d2", jevOk(S2, 12), llmOk(S2, 22), false)]],
  // A both-ran record beats an earlier LLM-only one and is kept as stored, not merged.
  "both-ran-beats-split": [[rec("d1", NOTRUN, llmOk(S1, 21)), rec("d2", jevOk(S1, 12), llmOk(S2, 22), true)]],
  "jev-only-pair": [[rec("d1", jevOk(S1, 11), NONE), rec("d2", jevOk(S2, 12), NONE)]],
  "llm-only-pair": [[rec("d1", NOTRUN, llmOk(S1, 21)), rec("d2", NOTRUN, llmOk(S2, 22))]],
  // Agreeing split: both sides answer the valid pair S1,S1b.
  "split-agree-jev-first": [[rec("d1", jevOk(S1 + "," + S1B, 11), NONE), rec("d2", NOTRUN, llmOk(S1 + "," + S1B, 22))],
    jevOk(S1 + "," + S1B, 11), llmOk(S1 + "," + S1B, 22)],
  // A merged split whose Jev side lists S1b without S1 is a rubric violation: compare() disagrees.
  "split-s1b-violation": [[rec("d1", jevOk(S1B, 11), NONE), rec("d2", NOTRUN, llmOk(S1 + "," + S1B, 22))],
    jevOk(S1B, 11), llmOk(S1 + "," + S1B, 22)],
  // Disagreeing split, LLM side logged first; the Jev-only record's stored "true" is ignored.
  "split-disagree-llm-first": [[rec("d1", NOTRUN, llmOk(S2, 21)), rec("d2", jevOk(S1, 12), NONE, true)],
    jevOk(S1, 12), llmOk(S2, 21)],
  // An S0-undecidable LLM answer is merged but not compared.
  "split-undecidable": [[rec("d1", jevOk(S1, 11), NONE), rec("d2", NOTRUN, llmOk("S0-undecidable", 22))],
    jevOk(S1, 11), llmOk("S0-undecidable", 22)],
  // Three records of one judgment: Jev-only, neither side, LLM-only -> one merged record.
  "split-three": [[rec("d1", jevOk(S2, 11), NONE), rec("d2", NOTRUN, NONE), rec("d3", NOTRUN, llmOk(S2, 23))],
    jevOk(S2, 11), llmOk(S2, 23)],
};
const [recs, jevSide, llmSide] = SC[scenario];
const p = aggregatePoint(recs, 0.9);
let cmp = "-";
if (jevSide) {
  const c = compare(jevSide, llmSide);
  const want = { rate: c.agreement === null ? null : c.agreement ? 1 : 0, n: c.agreement === null ? 0 : 1,
    bySig: Object.fromEntries(Object.keys(p.agreement_by_signal).map((id) =>
      [id, c.agreement_by_signal && typeof c.agreement_by_signal[id] === "boolean" ? (c.agreement_by_signal[id] ? 1 : 0) : null])) };
  const got = { rate: p.agreement_rate, n: p.agreement_n, bySig: p.agreement_by_signal };
  cmp = JSON.stringify(got) === JSON.stringify(want) ? "cmp-ok" : "cmp-diff want " + JSON.stringify(want) + " got " + JSON.stringify(got);
}
process.stdout.write([p.count, p.duplicates_dropped, Object.keys(p.by_stage).sort().join(","), p.agreement_n, p.agreement_rate,
  p.mismatches.map((m) => [m.stage, m.jev, m.llm].join(":")).join(","), p.latency_ms.jev.p95, p.latency_ms.llm.p95, cmp].join("|"));
JS
probe() { run_with_timeout 30 node "$(np "$PROBE_JS")" "$REPO_N/bin/lib/jev-report-aggregate.js" "$RECORD_JS" "$1" 2>&1; }

echo "=== duplicates that already carry both sides are not merged ==="
case_begin "d-both-ran-tie-keeps-earliest-as-stored" "bin/lib/jev-report-aggregate.js"
check "tie: d1 kept with its stored agreement (no recompute), d2 dropped" "1|1|d1|1|1||11|21|-" "$(probe both-ran-tie)"
case_end

case_begin "d-both-ran-beats-llm-only" "bin/lib/jev-report-aggregate.js"
check "a both-ran record beats an earlier LLM-only one; kept as stored, no merge" "1|1|d2|1|1||12|22|-" "$(probe both-ran-beats-split)"
case_end

case_begin "d-same-side-pairs-not-merged" "bin/lib/jev-report-aggregate.js"
check "two Jev-only records: the earliest is kept, nothing compared" "1|1|d1|0|||11||-" "$(probe jev-only-pair)"
check "two LLM-only records: the earliest is kept, nothing compared" "1|1|d1|0||||21|-" "$(probe llm-only-pair)"
case_end

echo "=== a Jev-only record and an LLM-only record of one judgment are merged ==="
case_begin "d-split-merge-agreeing" "bin/lib/jev-report-aggregate.js"
check "merged under the Jev record's stage; Jev latency from d1, LLM latency from d2; agreement equals compare() (true)" \
  "1|1|d1|1|1||11|22|cmp-ok" "$(probe split-agree-jev-first)"
case_end

case_begin "d-split-merge-s1b-violation-disagrees" "bin/lib/jev-report-aggregate.js"
check "merged split, Jev S1b without S1 vs LLM S1,S1b: a mismatch, as compare() says" \
  "1|1|d1|1|0|d1:S1b-wide-change:S1-multi-file,S1b-wide-change|11|22|cmp-ok" "$(probe split-s1b-violation)"
case_end

case_begin "d-split-merge-disagreeing-any-order" "bin/lib/jev-report-aggregate.js"
check "LLM side first: merged under d2 (the Jev record); agreement equals compare() (false), stored true ignored" \
  "1|1|d2|1|0|d2:S1-multi-file:S2-architecture|12|21|cmp-ok" "$(probe split-disagree-llm-first)"
case_end

case_begin "d-split-merge-undecidable-not-compared" "bin/lib/jev-report-aggregate.js"
check "an S0-undecidable LLM side is merged but not compared: agreement_n 0, as compare() says" \
  "1|1|d1|0|||11|22|cmp-ok" "$(probe split-undecidable)"
case_end

case_begin "d-split-three-records-dropped-count" "bin/lib/jev-report-aggregate.js"
check "three records of one judgment: one kept (merged), duplicates_dropped 2" \
  "1|2|d1|1|1||11|23|cmp-ok" "$(probe split-three)"
case_end
