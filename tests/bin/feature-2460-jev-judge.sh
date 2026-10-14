#!/usr/bin/env bash
# Tests: bin/workflow/jev-judge, hooks/lib/jev/two-stage/gate.js, hooks/workflow-state/complexity-routing/deterministic-signals.js, bin/workflow/normalize-judge-signals, hooks/lib/jev/two-stage/snapshot.js, hooks/lib/jev/two-stage/query.js, hooks/lib/jev/two-stage/replay.js, hooks/lib/jev/two-stage/finalize.js, hooks/lib/jev/two-stage/settle-complexity.js, bin/workflow/lib/jev-skip-adapter.js
# Tags: TL2, bin, jev, two-stage, skip-gate, skip-threshold, skip-record, skip-owner, sources-snapshot, required-sections, crash-consistency, frozen-mode, bound-read, superseded, cli-args, usage-error, complexity-gate, gate, threshold-by-answer, short-circuit, deterministic-signals, owner-marker, idempotent, failsafe, normalize, untrusted-input, secret-leak, mock-server, scope:issue-specific, pwsh-not-required

# The two-stage Jev broker (#2460): `jev-judge query` asks Jev once and adopts only answers
# that clear the per-direction threshold, `finalize` merges the subagent's answer for the rest,
# and the caller gets the exact CSV written to the fixed signals file. A module that does not
# exist yet fails its fragment with one MODULE_MISSING line instead of crashing the suite.

# TL3 gap (what this test does NOT catch): a real Jev endpoint and a real complexity-judge
# subagent writing the answer file; the mock answers whatever keys the request asks.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# Pin before _lib.sh starts the mock; fx_new re-pins per fixture.
JJ_PRE_ISO="$(make_tmp)"
harness_isolate "$JJ_PRE_ISO"
# Pattern A dispatcher: fragments are sourced in order into this process (one mock, one total).
SUITE_DIR="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2460-jev-judge"
. "$SUITE_DIR/_lib.sh"
rm -rf "$JJ_PRE_ISO"

case_begin "jj-a-cli-args" "bin/workflow/jev-judge"
. "$SUITE_DIR/a-cli-args.sh"
case_end
case_begin "jj-b-complexity-gate" "bin/workflow/jev-judge"
. "$SUITE_DIR/b-complexity-gate.sh"
case_end
case_begin "jj-c-deterministic" "hooks/workflow-state/complexity-routing/deterministic-signals.js"
. "$SUITE_DIR/c-deterministic.sh"
case_end
case_begin "jj-g-gate" "hooks/lib/jev/two-stage/gate.js"
. "$SUITE_DIR/g-gate.sh"
case_end
case_begin "jj-i-idempotent" "bin/workflow/jev-judge"
. "$SUITE_DIR/i-idempotent.sh"
case_end
case_begin "jj-n-normalize-unchanged" "bin/workflow/normalize-judge-signals"
. "$SUITE_DIR/n-normalize-unchanged.sh"
case_end
case_begin "jj-q-failsafe" "bin/workflow/jev-judge"
. "$SUITE_DIR/q-failsafe.sh"
case_end
case_begin "jj-d-sources" "hooks/lib/jev/two-stage/snapshot.js"
. "$SUITE_DIR/d-sources.sh"
case_end
case_begin "jj-e-required-sections" "hooks/lib/jev/two-stage/query.js"
. "$SUITE_DIR/e-required-sections.sh"
case_end
case_begin "jj-k-caller-failsafe" "bin/workflow/jev-judge"
. "$SUITE_DIR/k-caller-failsafe.sh"
case_end
case_begin "jj-l-crash-consistency" "hooks/lib/jev/two-stage/replay.js"
. "$SUITE_DIR/l-crash-consistency.sh"
case_end
case_begin "jj-o-frozen-mode" "hooks/lib/jev/two-stage/finalize.js"
. "$SUITE_DIR/o-frozen-mode.sh"
case_end
case_begin "jj-p-owner" "hooks/lib/jev/two-stage/settle-complexity.js"
. "$SUITE_DIR/p-owner.sh"
case_end
case_begin "jj-r-bound-read" "bin/workflow/jev-judge"
. "$SUITE_DIR/r-bound-read.sh"
case_end
case_begin "jj-f-skip-gate" "bin/workflow/lib/jev-skip-adapter.js"
. "$SUITE_DIR/f-skip-gate.sh"
case_end
case_begin "jj-g-skip-threshold" "bin/workflow/lib/jev-skip-adapter.js"
. "$SUITE_DIR/g-skip-threshold.sh"
case_end
case_begin "jj-h-skip-record" "bin/workflow/jev-judge"
. "$SUITE_DIR/h-skip-record.sh"
case_end
case_begin "jj-l-skip-crash" "hooks/lib/jev/two-stage/replay.js"
. "$SUITE_DIR/l-skip-crash.sh"
case_end
case_begin "jj-m-superseded" "bin/workflow/jev-judge"
. "$SUITE_DIR/m-superseded.sh"
case_end
case_begin "jj-o-skip-frozen-mode" "hooks/lib/jev/two-stage/finalize.js"
. "$SUITE_DIR/o-skip-frozen-mode.sh"
case_end

finish
