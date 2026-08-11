# shellcheck shell=bash
# Tests: hooks/lib/instructions-loaded-receipt.js
# Tags: rules-injection, instructions-loaded, quiescence, error-handling, boundary, table-driven, TL2, scope:common

# Error and boundary surface for waitForQuiescence(). The happy-path window cases cannot distinguish
# "entry absent" from "entry present but unreadable", and never touch the degenerate option values
# a caller can legitimately compute (W = clamp(2*S, ...) with S = 0, a one-member EXPECTED_SET,
# a deadline already in the past).

# CONTRACT NOTE (asserted here):
#   - A settled *.json that cannot be parsed/read is NOT a member: Q1 stays unsatisfied; must never throw or be counted.
#   - A corrupt entry republished correctly mid-run is picked up (recovery).
#   - opts.expected is a SET: duplicates collapse; one member is a valid set.
#   - Zero/negative windowSec, pollMs, or deadlines terminate promptly with a status, never spin
#     (driver's runaway guard reports RUNAWAY=yes instead of hanging the suite).
#   - A deadline boundary is INCLUSIVE: arriving exactly at q1DeadlineSec satisfies Q1; the run still stops at totalDeadlineSec.
#   - Stopping AT the combined deadline is INCOMPLETE, not OK: stability was never demonstrated, and
#     only a demonstrated-stable OK may prove absence downstream (see the TL3 gate).

echo ""
echo "=== quiescence error and boundary surface ==="

# --- table: name | scenario | want_status | want_count ---
while IFS='|' read -r name scenario want_status want_count; do
    [ -z "${name// /}" ] && continue
    case "$name" in \#*) continue ;; esac
    name="${name//[[:space:]]/}"; scenario="${scenario//[[:space:]]/}"
    want_status="${want_status//[[:space:]]/}"; want_count="${want_count//[[:space:]]/}"
    out="$(run_scenario "$scenario")"
    got_status="$(field STATUS "$out")"
    got_count="$(field COUNT "$out")"
    if printf '%s' "$out" | grep -q 'THREW='; then
        fail "$name: waitForQuiescence threw instead of degrading — $out"
    elif printf '%s' "$out" | grep -q 'RUNAWAY=yes'; then
        fail "$name: waitForQuiescence never terminated — $out"
    elif [ "$got_status" != "$want_status" ]; then
        fail "$name: want STATUS=$want_status, got '$got_status' — driver said: $out"
    elif [ "$got_count" != "$want_count" ]; then
        fail "$name: want COUNT=$want_count, got '$got_count' — driver said: $out"
    else
        pass "$name (STATUS=$got_status COUNT=$got_count)"
    fi
done <<'TABLE'
QE-corrupt-settled       | corrupt-settled-json            | INCOMPLETE | 2
QE-corrupt-recovered     | corrupt-plus-recovery           | OK         | 3
QE-unreadable-entry      | unreadable-entry                | INCOMPLETE | 2
QE-empty-json-entry      | empty-json-entry                | INCOMPLETE | 2
QE-duplicate-expected    | duplicate-expected              | OK         | 3
QE-single-expected       | single-expected                 | OK         | 1
QE-single-expected-miss  | single-expected-missing         | INCOMPLETE | 0
QE-q1-deadline-inclusive | arrival-exactly-at-q1-deadline  | OK         | 3
TABLE

# --- QE-total-deadline: an arrival exactly ON the combined deadline must not push the
# run past it. Terminating late is the failure this pins down. ---
out_td="$(run_scenario arrival-exactly-at-total-deadline)"
elapsed_td="$(field ELAPSED "$out_td")"
if printf '%s' "$out_td" | grep -q 'RUNAWAY=yes'; then
    fail "QE-total-deadline: the run never terminated — $out_td"
elif [ -n "$elapsed_td" ] && [ "$elapsed_td" -le 91 ] 2>/dev/null; then
    pass "QE-total-deadline: an arrival at the combined deadline still stops by 90s (${elapsed_td}s)"
else
    fail "QE-total-deadline: want ELAPSED <= 91, got '$elapsed_td' — driver said: $out_td"
fi

# --- degenerate timing options -------------------------------------------------
# A second, tiny driver: the option values are the variable here, not the receipt dir.
cat > "$BASE/opts-driver.js" <<'OPTS_EOF'
"use strict";
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { waitForQuiescence } = require(process.argv[2]);
const dir = process.argv[3];
const variant = process.argv[4];

const EXPECTED = ["rules/a.md"];
fs.mkdirSync(dir, { recursive: true });
if (variant !== "expected-missing") {
  const entry = { fired_at: new Date(0).toISOString(), file_path: "rules/a.md",
    load_reason: null, verdict: "ok", payload_keys: ["file_path"] };
  fs.writeFileSync(
    path.join(dir, crypto.createHash("sha1").update("rules/a.md").digest("hex") + ".json"),
    JSON.stringify(entry));
}

let clock = 0, sleeps = 0;
const base = {
  expected: EXPECTED, windowSec: 5, q1DeadlineSec: 60, totalDeadlineSec: 90, pollMs: 1000,
  now: () => clock,
  sleep: (ms) => {
    sleeps += 1;
    if (sleeps > 5000) { console.log("RUNAWAY=yes"); process.exit(0); }
    clock += (typeof ms === "number" && ms > 0) ? ms : 1000;
  },
};
const overrides = {
  "window-zero": { windowSec: 0 },
  "window-negative": { windowSec: -5 },
  "poll-zero": { pollMs: 0 },
  "poll-negative": { pollMs: -100 },
  "q1-zero": { q1DeadlineSec: 0 },
  "total-negative": { totalDeadlineSec: -1 },
  "expected-missing": { totalDeadlineSec: 10, q1DeadlineSec: 10 },
}[variant];
if (!overrides) { console.log("VARIANT_UNKNOWN"); process.exit(0); }

let res;
try {
  res = waitForQuiescence(dir, Object.assign({}, base, overrides));
} catch (e) { console.log("THREW=" + e.message); process.exit(0); }
console.log("STATUS=" + (res && res.status !== undefined ? res.status : "NO_STATUS")
  + " ELAPSED=" + Math.round(clock / 1000) + " SLEEPS=" + sleeps);
OPTS_EOF

OPT_N=0
while IFS='|' read -r name variant want_status; do
    [ -z "${name// /}" ] && continue
    case "$name" in \#*) continue ;; esac
    name="${name//[[:space:]]/}"; variant="${variant//[[:space:]]/}"; want_status="${want_status//[[:space:]]/}"
    OPT_N=$((OPT_N + 1))
    out="$(node "$(node_path "$BASE/opts-driver.js")" "$(node_path "$RECEIPT_LIB")" \
        "$(node_path "$BASE/opt.$OPT_N")" "$variant" 2>&1)"
    got="$(field STATUS "$out")"
    if printf '%s' "$out" | grep -q 'RUNAWAY=yes'; then
        fail "$name: degenerate option value caused an unbounded loop — $out"
    elif printf '%s' "$out" | grep -q 'THREW='; then
        fail "$name: degenerate option value threw instead of being clamped — $out"
    elif [ "$got" != "$want_status" ]; then
        fail "$name: want STATUS=$want_status, got '$got' — driver said: $out"
    else
        pass "$name ($out)"
    fi
done <<'TABLE'
QO-window-zero       | window-zero      | OK
QO-window-negative   | window-negative  | OK
QO-poll-zero         | poll-zero        | OK
QO-poll-negative     | poll-negative    | OK
QO-q1-deadline-zero  | q1-zero          | OK
QO-total-negative    | total-negative   | INCOMPLETE
QO-expected-missing  | expected-missing | INCOMPLETE
TABLE

# --- Q-empty-expected: an empty EXPECTED_SET is INCOMPLETE, never a vacuous OK ---
cat > "$BASE/empty-expected.js" <<'EOF'
"use strict";
const fs = require("fs");
const { waitForQuiescence } = require(process.argv[2]);
const dir = process.argv[3];
fs.mkdirSync(dir, { recursive: true });
let clock = 0;
let res;
try {
  res = waitForQuiescence(dir, {
    expected: [], windowSec: 5, q1DeadlineSec: 60, totalDeadlineSec: 90, pollMs: 1000,
    now: () => clock, sleep: (ms) => { clock += ms || 1000; },
  });
} catch (e) { console.log("THREW=" + e.message); process.exit(0); }
console.log("STATUS=" + (res && res.status !== undefined ? res.status : "NO_STATUS"));
EOF
out_ee="$(node "$(node_path "$BASE/empty-expected.js")" "$(node_path "$RECEIPT_LIB")" "$(node_path "$BASE/ee")" 2>&1)"
[ "$(field STATUS "$out_ee")" = "INCOMPLETE" ] \
    && pass "Q-empty-expected: an empty EXPECTED_SET yields INCOMPLETE" \
    || fail "Q-empty-expected: want STATUS=INCOMPLETE, got '$out_ee'"
