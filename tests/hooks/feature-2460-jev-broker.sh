#!/usr/bin/env bash
# Tests: hooks/lib/jev/broker.js, hooks/lib/jev/registry.js
# Tags: TL2, hooks, jev, broker, registry, prototype-pollution, temp-dir, hook-timeout-budget, mock-server, scope:issue-specific, pwsh-not-required, jev-gate, claim-release, orphan-retry, latency, llm-observed, untrusted-claim-content, unlogged-record, forged-claim, resolve-step, notes-session-binding, parse-fallback, in-process-normalize, no-file-write, normalizer-failure

# The broker's library surface, called directly: a point name is a registry key only when
# it is an own key (never "constructor" or "__proto__"), the normalizer runs in-process and
# writes no file anywhere, and probe + query fit inside the hook timeout that settings.json registers.

# TL3 gap (what this test does NOT catch): a real host killing the hook at its timeout;
# only the budget arithmetic is pinned here, with a mock Jev on 127.0.0.1.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# Pattern A dispatcher: fragments are sourced in order into this process (one mock, one BP_JEV, one total).
SUITE_DIR="$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-2460-jev-broker"
. "$SUITE_DIR/_lib.sh"

case_begin "broker-a-normalize" "hooks/lib/jev/registry.js"
. "$SUITE_DIR/a-normalize.sh"
case_end
case_begin "broker-b-query-record" "hooks/lib/jev/broker.js"
. "$SUITE_DIR/b-query-record.sh"
case_end
case_begin "broker-c-claim" "hooks/lib/jev/broker.js"
. "$SUITE_DIR/c-claim.sh"
case_end
case_begin "broker-d-forged" "hooks/lib/jev/broker.js"
. "$SUITE_DIR/d-forged.sh"
case_end

finish
