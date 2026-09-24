# shellcheck shell=bash
# Tests: hooks/lib/instructions-loaded-receipt.js
# Tags: rules-injection, instructions-loaded, quiescence, fixtures, TL2, scope:common
#
# Writes the scenario driver and exposes run_scenario()/field() for the case files.
# Assumes BASE, RECEIPT_LIB, node_path() are defined by the dispatcher.

DRIVER="$BASE/driver.js"

cat > "$DRIVER" <<'DRIVER_EOF'
"use strict";
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const libPath = process.argv[2];
const scenario = process.argv[3];
const dir = process.argv[4];

const { waitForQuiescence } = require(libPath);

let EXPECTED = ["rules/a.md", "rules/b.md", "rules/c.md"];
const TARGET = "rules/target.md";

function key(fp) { return crypto.createHash("sha1").update(fp).digest("hex"); }
function put(fp, firedAtMs) {
  fs.mkdirSync(dir, { recursive: true });
  const entry = {
    fired_at: new Date(firedAtMs).toISOString(),
    file_path: fp,
    load_reason: null,
    verdict: "ok",
    payload_keys: ["file_path"],
  };
  const tmp = path.join(dir, `.pub-${process.pid}-${Math.random().toString(36).slice(2)}`);
  fs.writeFileSync(tmp, JSON.stringify(entry));
  fs.renameSync(tmp, path.join(dir, key(fp) + ".json"));
}

const T0 = Date.UTC(2026, 0, 1, 0, 0, 0);
let clock = T0;
let sleepCalls = 0;
let onTick = () => {};

const opts = {
  expected: EXPECTED,
  windowSec: 5,
  q1DeadlineSec: 60,
  totalDeadlineSec: 90,
  pollMs: 1000,
  now: () => clock,
  sleep: (ms) => {
    sleepCalls += 1;
    // Runaway guard: a non-advancing implementation must surface as a bounded
    // failure, never as a hung test run.
    if (sleepCalls > 5000) { console.log("RUNAWAY=yes SLEEPS=" + sleepCalls); process.exit(0); }
    clock += (typeof ms === "number" && ms > 0) ? ms : 1000;
    onTick(Math.round((clock - T0) / 1000));
  },
};

if (scenario === "dir-absent") {
  // deliberately do not create dir
} else if (scenario === "satisfied-stable") {
  EXPECTED.forEach((fp, i) => put(fp, T0 - 3000 + i * 500));
} else if (scenario === "member-missing") {
  put(EXPECTED[0], T0 - 3000);
  put(EXPECTED[1], T0 - 2500);
} else if (scenario === "late-arrival-midwindow") {
  EXPECTED.forEach((fp, i) => put(fp, T0 - 3000 + i * 500));
  let dropped = false;
  onTick = (elapsed) => {
    if (!dropped && elapsed >= 3) { dropped = true; put(TARGET, clock); }
  };
} else if (scenario === "target-just-before-deadline") {
  put(EXPECTED[0], T0 - 3000);
  put(EXPECTED[1], T0 - 2500);
  let c = false, t = false;
  onTick = (elapsed) => {
    if (!c && elapsed >= 50) { c = true; put(EXPECTED[2], clock); }
    if (!t && elapsed >= 52) { t = true; put(TARGET, clock); }
  };
} else if (scenario === "temp-file-not-aggregated") {
  EXPECTED.forEach((fp, i) => put(fp, T0 - 3000 + i * 500));
  // half-written publications: temp names that renameSync has not settled yet
  fs.writeFileSync(path.join(dir, key(TARGET) + ".json.tmp"), '{"file_path":"rules/target.md"');
  fs.writeFileSync(path.join(dir, ".pub-9999-halfwritten"), '{"file_path":"rules/targ');
} else if (scenario === "corrupt-settled-json") {
  // a.md and b.md are valid; c.md's SETTLED receipt is truncated garbage. A corrupt
  // settled entry is not a member: Q1 must stay unsatisfied instead of counting it.
  put(EXPECTED[0], T0 - 3000);
  put(EXPECTED[1], T0 - 2500);
  fs.writeFileSync(path.join(dir, key(EXPECTED[2]) + ".json"), '{"file_path": "rules/c.md", ');
} else if (scenario === "corrupt-plus-recovery") {
  // the same corrupt entry, republished correctly mid-run: the run must recover.
  put(EXPECTED[0], T0 - 3000);
  put(EXPECTED[1], T0 - 2500);
  fs.writeFileSync(path.join(dir, key(EXPECTED[2]) + ".json"), "not json at all");
  let fixed = false;
  onTick = (elapsed) => {
    if (!fixed && elapsed >= 4) { fixed = true; put(EXPECTED[2], clock); }
  };
} else if (scenario === "unreadable-entry") {
  // c.md's receipt path exists but is a DIRECTORY: readFileSync throws EISDIR.
  put(EXPECTED[0], T0 - 3000);
  put(EXPECTED[1], T0 - 2500);
  fs.mkdirSync(path.join(dir, key(EXPECTED[2]) + ".json"), { recursive: true });
} else if (scenario === "empty-json-entry") {
  put(EXPECTED[0], T0 - 3000);
  put(EXPECTED[1], T0 - 2500);
  fs.writeFileSync(path.join(dir, key(EXPECTED[2]) + ".json"), "");
} else if (scenario === "duplicate-expected") {
  // the same path listed twice must not require two receipts.
  EXPECTED = ["rules/a.md", "rules/b.md", "rules/a.md", "rules/c.md"];
  opts.expected = EXPECTED;
  ["rules/a.md", "rules/b.md", "rules/c.md"].forEach((fp, i) => put(fp, T0 - 3000 + i * 500));
} else if (scenario === "single-expected") {
  EXPECTED = ["rules/a.md"];
  opts.expected = EXPECTED;
  put("rules/a.md", T0 - 3000);
} else if (scenario === "single-expected-missing") {
  EXPECTED = ["rules/a.md"];
  opts.expected = EXPECTED;
  fs.mkdirSync(dir, { recursive: true });
} else if (scenario === "republish-newer-midwindow") {
  // Q1 is already satisfied. Mid-window the SAME key is republished with a NEWER
  // fired_at — the shape a re-fired InstructionsLoaded event produces for a file the
  // session already loaded. The receipt COUNT never changes, so an implementation
  // that watches only the entry set sees a motionless directory and settles early.
  // Stability is "set AND max timestamp", so the window must restart.
  EXPECTED.forEach((fp, i) => put(fp, T0 - 3000 + i * 500));
  let done = false;
  onTick = (elapsed) => {
    if (!done && elapsed >= 3) { done = true; put(EXPECTED[0], clock); }
  };
} else if (scenario === "republish-older-midwindow") {
  // The mirror image: the same key republished with an OLDER fired_at. The max
  // timestamp does not move, so the window must NOT restart — otherwise a
  // clock-skewed or replayed receipt could hold the gate open indefinitely.
  EXPECTED.forEach((fp, i) => put(fp, T0 - 3000 + i * 500));
  let done = false;
  onTick = (elapsed) => {
    if (!done && elapsed >= 3) { done = true; put(EXPECTED[0], T0 - 60000); }
  };
} else if (scenario === "republish-newer-forever") {
  // The same key republished with a newer fired_at on every tick: stability is never
  // demonstrated, so the run must end INCOMPLETE at the combined deadline rather than
  // report OK on a set that was in motion the whole time.
  EXPECTED.forEach((fp, i) => put(fp, T0 - 3000 + i * 500));
  onTick = (elapsed) => { if (elapsed < 90) put(EXPECTED[0], clock); };
} else if (scenario === "arrival-exactly-at-q1-deadline") {
  // the final expected member settles at exactly q1DeadlineSec. The barrier is
  // inclusive: arriving ON the deadline satisfies Q1.
  put(EXPECTED[0], T0 - 3000);
  put(EXPECTED[1], T0 - 2500);
  let c = false;
  onTick = (elapsed) => {
    if (!c && elapsed >= 60) { c = true; put(EXPECTED[2], clock); }
  };
} else if (scenario === "arrival-exactly-at-total-deadline") {
  // Q1 is met, then entries keep arriving so the stability window never closes, and
  // the target lands exactly ON the combined deadline. The run must terminate AT the
  // deadline rather than let a perpetually-resetting window run past it.
  EXPECTED.forEach((fp, i) => put(fp, T0 - 3000 + i * 500));
  let t = false, extra = 0;
  onTick = (elapsed) => {
    if (elapsed < 90) { extra += 1; put("rules/x" + extra + ".md", clock); }
    if (!t && elapsed >= 90) { t = true; put(TARGET, clock); }
  };
} else {
  console.log("SCENARIO_UNKNOWN");
  process.exit(0);
}

let res;
try {
  res = waitForQuiescence(dir, opts);
} catch (e) {
  console.log("THREW=" + e.message);
  process.exit(0);
}

const entries = (res && Array.isArray(res.entries)) ? res.entries : [];
const paths = entries.map((e) => e && e.file_path);
console.log([
  "STATUS=" + (res && res.status !== undefined ? res.status : "NO_STATUS"),
  "COUNT=" + entries.length,
  "HASTARGET=" + (paths.includes(TARGET) ? "yes" : "no"),
  "ELAPSED=" + Math.round((clock - T0) / 1000),
  "SLEEPS=" + sleepCalls,
].join(" "));
DRIVER_EOF

# Each invocation gets a FRESH receipt dir: several scenarios are run more than once
# (once in the table, once for a timing assertion), and a reused dir would start the
# second run with the previous run's late arrival already settled — which silently
# turns the window-reset assertion into a no-op.
# The counter lives in a file, not a variable: run_scenario is always called inside
# `$( )`, and a subshell's increment never reaches the caller.
echo 0 > "$BASE/.run-n"
run_scenario() {
    local scenario="$1" n
    n=$(( $(cat "$BASE/.run-n") + 1 ))
    echo "$n" > "$BASE/.run-n"
    local dir="$BASE/$scenario.$n"
    node "$(node_path "$DRIVER")" "$(node_path "$RECEIPT_LIB")" "$scenario" "$(node_path "$dir")" 2>&1
}

field() { printf '%s' "$2" | tr ' ' '\n' | grep "^$1=" | head -1 | cut -d= -f2-; }
