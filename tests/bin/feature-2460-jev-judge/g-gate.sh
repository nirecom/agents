#!/usr/bin/env bash
# Tests: hooks/lib/jev/two-stage/gate.js
# Tags: TL1, bin, jev, two-stage, gate, threshold-by-answer, short-circuit, boundary, scope:issue-specific, pwsh-not-required
# Fragment of tests/bin/feature-2460-jev-judge.sh, sourced after _lib.sh (not standalone):
# applyGate called directly. The outcome depends only on the policy's per-direction
# thresholds and short_circuit_answer: no point-name branch, no built-in default threshold.

echo "=== gate.js: per-direction confidence gate ==="
need_mod hooks/lib/jev/two-stage/gate.js || return 0

POL_CX='{"confidence_threshold_by_answer":{"true":0.7,"false":0.7},"short_circuit_answer":null}'
POL_SKIP='{"confidence_threshold_by_answer":{"true":0.9,"false":0.7},"short_circuit_answer":false}'
POL_BOUND='{"confidence_threshold_by_answer":{"true":0.9,"false":0.7},"short_circuit_answer":null}'
POL_SWAP='{"confidence_threshold_by_answer":{"true":0.7,"false":0.9},"short_circuit_answer":false}'
POL_CX_SC='{"confidence_threshold_by_answer":{"true":0.7,"false":0.7},"short_circuit_answer":false}'
# gate <items-json> <policy-json>
gate() { pb gate "$1" "$2"; }

case_begin "gate-complexity-symmetric" "hooks/lib/jev/two-stage/gate.js"
check "all keys confident (0.99 / 0.01 / 0.25): all adopted, final" \
  '{"adopted":{"a":true,"b":false,"c":false},"delegated":[],"unjudged":[],"short_circuited":false,"result":"final"}' \
  "$(gate '{"a":{"p":0.99},"b":{"p":0.01},"c":{"p":0.25}}' "$POL_CX")"
check "p=0.75 adopted true, p=0.65 delegated: need-subagent" \
  '{"adopted":{"a":true},"delegated":["b"],"unjudged":[],"short_circuited":false,"result":"need-subagent"}' \
  "$(gate '{"a":{"p":0.75},"b":{"p":0.65}}' "$POL_CX")"
check "short_circuit_answer null: an adopted false never short-circuits" \
  '{"adopted":{"a":false},"delegated":["b"],"unjudged":[],"short_circuited":false,"result":"need-subagent"}' \
  "$(gate '{"a":{"p":0.25},"b":{"p":0.5}}' "$POL_CX")"
case_end

case_begin "gate-skip-asymmetric" "hooks/lib/jev/two-stage/gate.js"
check "skip: one key adopted false (p=0.2) short-circuits; the other is unjudged, not delegated" \
  '{"adopted":{"x":false},"delegated":[],"unjudged":["y"],"short_circuited":true,"result":"final"}' \
  "$(gate '{"x":{"p":0.2},"y":{"p":0.5}}' "$POL_SKIP")"
check "skip: both keys p>=0.9 adopted true, final, no short circuit" \
  '{"adopted":{"x":true,"y":true},"delegated":[],"unjudged":[],"short_circuited":false,"result":"final"}' \
  "$(gate '{"x":{"p":0.95},"y":{"p":0.92}}' "$POL_SKIP")"
check "skip: p=0.75 on the skip side (conf 0.75 < 0.9) is delegated" \
  '{"adopted":{"y":true},"delegated":["x"],"unjudged":[],"short_circuited":false,"result":"need-subagent"}' \
  "$(gate '{"x":{"p":0.75},"y":{"p":0.95}}' "$POL_SKIP")"
case_end

case_begin "gate-boundaries-epsilon" "hooks/lib/jev/two-stage/gate.js"
check "p=0.3 and p=0.9 adopted; p=0.31 and p=0.89 held (float error does not move the edge)" \
  '{"adopted":{"a":false,"b":true},"delegated":["c","d"],"unjudged":[],"short_circuited":false,"result":"need-subagent"}' \
  "$(gate '{"a":{"p":0.3},"b":{"p":0.9},"c":{"p":0.31},"d":{"p":0.89}}' "$POL_BOUND")"
check "p=0.5 is the true direction with conf 0.5 (adopted when true needs 0.5)" \
  '{"adopted":{"a":true},"delegated":[],"unjudged":[],"short_circuited":false,"result":"final"}' \
  "$(gate '{"a":{"p":0.5}}' '{"confidence_threshold_by_answer":{"true":0.5,"false":0.9},"short_circuit_answer":null}')"
check "p=0.5 held when the true direction needs 0.6 even though false needs only 0.5" \
  '{"adopted":{},"delegated":["a"],"unjudged":[],"short_circuited":false,"result":"need-subagent"}' \
  "$(gate '{"a":{"p":0.5}}' '{"confidence_threshold_by_answer":{"true":0.6,"false":0.5},"short_circuit_answer":null}')"
case_end

case_begin "gate-data-only" "hooks/lib/jev/two-stage/gate.js"
check "no thresholds in the policy: every key held, no built-in default fills in" \
  '{"adopted":{},"delegated":["a","b"],"unjudged":[],"short_circuited":false,"result":"need-subagent"}' \
  "$(gate '{"a":{"p":0.99},"b":{"p":0.01}}' '{"short_circuit_answer":null}')"
check "swapped thresholds (true 0.7 / false 0.9): all p=0.2 delegated" \
  '{"adopted":{},"delegated":["x","y"],"unjudged":[],"short_circuited":false,"result":"need-subagent"}' \
  "$(gate '{"x":{"p":0.2},"y":{"p":0.2}}' "$POL_SWAP")"
check "swapped thresholds: all p=0.75 adopted true, final" \
  '{"adopted":{"x":true,"y":true},"delegated":[],"unjudged":[],"short_circuited":false,"result":"final"}' \
  "$(gate '{"x":{"p":0.75},"y":{"p":0.75}}' "$POL_SWAP")"
check "complexity thresholds with short_circuit_answer false: short-circuits on data alone" \
  '{"adopted":{"a":false},"delegated":[],"unjudged":["b","c"],"short_circuited":true,"result":"final"}' \
  "$(gate '{"a":{"p":0.25},"b":{"p":0.5},"c":{"p":0.5}}' "$POL_CX_SC")"
check "short_circuit_answer false: an adopted true does not short-circuit" \
  '{"adopted":{"a":true},"delegated":["b"],"unjudged":[],"short_circuited":false,"result":"need-subagent"}' \
  "$(gate '{"a":{"p":0.95},"b":{"p":0.5}}' "$POL_SKIP")"
case_end
