#!/usr/bin/env bash
# Tests: bin/lib/jev-report-aggregate.js, bin/jev-report
# Tags: TL2, bin, jev, report, aggregation, json-output, latency-percentiles, low-confidence-rate, unreadable-generations, scope:issue-specific, pwsh-not-required, low-confidence-rate-n, null-ratio, fallback-rate, terminal-sanitisation, undecidable, low-confidence-reference, timestamp-sanitiser, dedupe, merge-sides, agreement, s1b-without-s1, prototype-pollution, mock-server, cli-args, usage-error

# The report's figures must describe only what they claim: latency over completed calls
# (Jev ok / low-confidence / unmappable, LLM ok / parse-fallback), the low-confidence rate
# over answered Jev records, and a generation that exists but cannot be read is surfaced
# (JSON, text and a stderr warning) rather than silently shrinking the sample.

# TL3 gap (what this test does NOT catch): a real permission-denied log generation; the
# unreadable case uses a directory (EISDIR), which fails the same read on every platform.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$AGENTS_DIR/tests/lib/harness.sh"
# Pattern A dispatcher: _lib.sh builds one fixture dir, then each fragment is sourced in order
# into this process (one FX, one mock, one total). Each fragment documents its own scope.
SUITE_DIR="$AGENTS_DIR/tests/bin/feature-2460-jev-report-accuracy"
. "$SUITE_DIR/_lib.sh"

case_begin "report-a-aggregation" "bin/jev-report"
. "$SUITE_DIR/a-aggregation.sh"
case_end
case_begin "report-b-text-sanitise" "bin/lib/jev-report-aggregate.js"
. "$SUITE_DIR/b-text-sanitise.sh"
case_end
case_begin "report-c-proto-undecidable" "bin/lib/jev-report-aggregate.js"
. "$SUITE_DIR/c-proto-undecidable.sh"
case_end
case_begin "report-d-ts-dedupe-sweep" "bin/lib/jev-report-aggregate.js"
. "$SUITE_DIR/d-ts-dedupe-sweep.sh"
case_end
case_begin "report-e-rates-generations" "bin/lib/jev-report-aggregate.js"
. "$SUITE_DIR/e-rates-generations.sh"
case_end
case_begin "report-f-dedupe-merge" "bin/lib/jev-report-aggregate.js"
. "$SUITE_DIR/f-dedupe-merge.sh"
case_end
case_begin "report-g-s1b-without-s1" "bin/lib/jev-report-aggregate.js"
. "$SUITE_DIR/g-s1b-without-s1.sh"
case_end
case_begin "report-h-arg-errors" "bin/jev-report"
. "$SUITE_DIR/h-arg-errors.sh"
case_end

finish
