#!/usr/bin/env bash
# Tests: hooks/lib/jsonl-rotating-log.js, hooks/lib/rtk-guard-audit.js
# Tags: TL2, hooks, jev, jsonl-log, rotation, file-lock, fail-open, regression-2326, scope:issue-specific, pwsh-not-required

# #2460 S1: the size-rotating, lock-guarded JSONL writer moves out of
# rtk-guard-audit into a neutral shared module so the Jev decision log can
# reuse it. This file pins the shared module's contract and the rtk side's
# unchanged exports (the rtk suite feature-2326 is re-run as a regression).
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

JRL_REL="hooks/lib/jsonl-rotating-log.js"
RTK_REL="hooks/lib/rtk-guard-audit.js"
JRL="$(np "$SCRIPT_CHECKOUT_ROOT/$JRL_REL")"
RTK="$(np "$SCRIPT_CHECKOUT_ROOT/$RTK_REL")"
TMP="$(make_tmp)"
trap 'rm -rf "$TMP"' EXIT
harness_isolate "$TMP/iso"
cd "$TMP" || exit 1
PROBE="$(np "$TMP/probe.js")"

# probe.js <mode> <args...> prints one result token (or an error line).
cat > "$TMP/probe.js" <<'EOF'
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const [mode, modPath, ...rest] = process.argv.slice(2);
let m;
try { m = require(modPath); } catch (e) { console.log("LOAD-FAIL:" + (e.code || e.message)); process.exit(0); }
const lines = (p) => { try { return fs.readFileSync(p, "utf8").split("\n").filter(Boolean); } catch (_e) { return []; } };
const out = (v) => console.log(typeof v === "string" ? v : JSON.stringify(v));
const { spawn } = require("child_process");
const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
const waitFor = (pred, ms) => { const end = Date.now() + ms; while (!pred() && Date.now() < end) sleep(20); return pred(); };
const child = (...a) => spawn(process.execPath, [__filename, ...a], { stdio: "ignore" });
const age = (p, ms) => { const t = (Date.now() - ms) / 1000; fs.utimesSync(p, t, t); };
// Fails the "wx" open of lp with the code plan(n) returns for call n; a falsy code delegates.
const stubOpen = (lp, plan) => {
  const real = fs.openSync;
  let calls = 0;
  fs.openSync = (p, flag, ...a) => {
    if (p === lp && flag === "wx") {
      const code = plan(++calls);
      if (code) throw Object.assign(new Error("stub " + code), { code });
    }
    return real(p, flag, ...a);
  };
  return () => calls;
};
try {
  if (mode === "exports") {
    out([m.DEFAULT_MAX_BYTES, m.DEFAULT_MAX_ROTATED, typeof m.resolveLogDir, typeof m.withLock,
      typeof m.rotate, typeof m.appendJsonlRotating].join(","));
  } else if (mode === "append-basic") {
    const p = path.join(rest[0], "a.log");
    const r = m.appendJsonlRotating(p, { k: "v", n: 1 }, {});
    const ls = lines(p);
    out([r && r.ok, ls.length, ls.length === 1 && JSON.parse(ls[0]).k].join(","));
  } else if (mode === "rotation") {
    const p = path.join(rest[0], "r.log");
    for (let i = 0; i < 40; i++) m.appendJsonlRotating(p, { i, pad: "x".repeat(60) }, { maxBytes: 300, maxRotated: 3 });
    const names = [p, p + ".1", p + ".2", p + ".3", p + ".4"].map((f) => fs.existsSync(f) ? 1 : 0).join("");
    let broken = 0;
    for (const f of [p, p + ".1", p + ".2", p + ".3"]) for (const l of lines(f)) { try { JSON.parse(l); } catch (_e) { broken++; } }
    const last = lines(p).map((l) => JSON.parse(l).i).pop();
    const baseOk = fs.statSync(p).size <= 300 ? "within" : "over";
    out([names, broken, last, baseOk].join(","));
  } else if (mode === "rotate-direct") {
    const p = path.join(rest[0], "d.log");
    fs.writeFileSync(p, "B\n"); fs.writeFileSync(p + ".1", "R1\n"); fs.writeFileSync(p + ".2", "R2\n");
    m.rotate(p, 2);
    const rd = (f) => fs.existsSync(f) ? fs.readFileSync(f, "utf8").trim() : "-";
    out([rd(p), rd(p + ".1"), rd(p + ".2"), rd(p + ".3")].join(","));
  } else if (mode === "rotate-default") {
    const p = path.join(rest[0], "e.log");
    for (const [f, v] of [[p, "B"], [p + ".1", "R1"], [p + ".2", "R2"], [p + ".3", "R3"]]) fs.writeFileSync(f, v + "\n");
    m.rotate(p);
    const rd = (f) => fs.existsSync(f) ? fs.readFileSync(f, "utf8").trim() : "-";
    out([rd(p), rd(p + ".1"), rd(p + ".2"), rd(p + ".3"), rd(p + ".4")].join(","));
  } else if (mode === "fail-open") {
    const blocker = path.join(rest[0], "blocker");
    fs.writeFileSync(blocker, "x");
    const r = m.appendJsonlRotating(path.join(blocker, "sub", "f.log"), { a: 1 }, {});
    out([r && r.ok, typeof (r && r.error) !== "undefined" && r.error !== null].join(","));
  } else if (mode === "log-dir") {
    const inj = path.join(rest[0], "inj");
    const a = m.resolveLogDir({ logDir: inj }) === inj;
    process.env.AGENTS_STATE_DIR = path.join(rest[0], "state");
    const b = m.resolveLogDir({}) === path.join(rest[0], "state", "logs");
    delete process.env.AGENTS_STATE_DIR;
    const c = m.resolveLogDir({}) === path.join(os.homedir(), ".agents", "logs");
    out([a, b, c].join(","));
  } else if (mode === "with-lock") {
    const lp = path.join(rest[0], "w.lock");
    let ran = false, heldDuring = false;
    m.withLock(lp, {}, () => { ran = true; heldDuring = fs.existsSync(lp); });
    out([ran, heldDuring, fs.existsSync(lp)].join(","));
  } else if (mode === "lock-consts") {
    out([typeof m.LOCK_DENIED_MS === "number" && m.LOCK_DENIED_MS > 0, m.LOCK_DENIED_MS < m.LOCK_STALE_MS,
      m.LOCK_HARD_STALE_MS, typeof m.holderAlive].join(","));
  } else if (mode === "holder-alive") {
    const gone = require("child_process").spawnSync(process.execPath, ["-e", "0"]).pid;
    const live = spawn(process.execPath, ["-e", "setTimeout(()=>{},30000)"], { stdio: "ignore" });
    const rows = [[process.pid + ".00aa", true], ["999999999.x", false], ["abc", false], ["", false],
      ["0.x", false], ["-5.x", false], [gone + ".x", false], [live.pid + ".x", true]];
    const bad = rows.filter(([t, want]) => m.holderAlive(t) !== want).map(([t]) => JSON.stringify(t));
    live.kill();
    out(bad.join("|") || "all-match");
  } else if (mode === "denied-retry") {
    const lp = path.join(rest[0], rest[1] + ".lock");
    const calls = stubOpen(lp, (n) => (n <= 2 ? rest[1] : null));
    let runs = 0;
    const ret = m.withLock(lp, {}, () => { runs++; return "ret"; });
    out([runs, ret, fs.existsSync(lp), calls()].join(","));
  } else if (mode === "denied-append") {
    const p = path.join(rest[0], rest[1] + ".log");
    const calls = stubOpen(p + ".lock", (n) => (n <= 2 ? rest[1] : null));
    const r = m.appendJsonlRotating(p, { k: "v" }, {});
    const ls = lines(p);
    out([r && r.ok, String(r && r.error), ls.length, ls.length === 1 && JSON.parse(ls[0]).k, calls()].join(","));
  } else if (mode === "denied-bounded") {
    const lp = path.join(rest[0], "b.lock");
    const p = path.join(rest[0], "b.log");
    stubOpen(lp, () => "EPERM");
    stubOpen(p + ".lock", () => "EPERM");
    let ran = false, code = "no-throw";
    const t0 = Date.now();
    try { m.withLock(lp, {}, () => { ran = true; }); } catch (e) { code = e.code; }
    const ms = Date.now() - t0;
    // Upper slack absorbs scheduler stalls on a loaded host; it still ends at
    // LOCK_STALE_MS, so a denial wait bounded by the stale age instead fails here.
    const bounded = ms >= m.LOCK_DENIED_MS - m.LOCK_RETRY_MS && ms < m.LOCK_DENIED_MS + 1500
      && m.LOCK_DENIED_MS + 1500 <= m.LOCK_STALE_MS;
    const r = m.appendJsonlRotating(p, { a: 1 }, {});
    out([code, ran, bounded ? "bounded" : "ms=" + ms, r && r.ok, r && r.error, fs.existsSync(p)].join(","));
  } else if (mode === "other-error") {
    const lp = path.join(rest[0], "o.lock");
    const calls = stubOpen(lp, () => "ENOSPC");
    let ran = false, code = "no-throw";
    try { m.withLock(lp, {}, () => { ran = true; }); } catch (e) { code = e.code; }
    out([code, calls(), ran].join(","));
  } else if (mode === "denied-reset") {
    // EPERM, then a real fresh lock file held past LOCK_DENIED_MS (real EEXIST polls),
    // then EPERM again: only a window restarted by the EEXIST lets fn run.
    const lp = path.join(rest[0], "z.lock");
    const hold = m.LOCK_DENIED_MS + 100;
    let t1 = 0, denials = 0, polls = 0, gap = 0;
    stubOpen(lp, () => {
      if (!t1) { t1 = Date.now(); denials++; fs.writeFileSync(lp, ""); return "EPERM"; }
      if (Date.now() - t1 <= hold) { polls++; return null; }
      if (denials === 1) { denials++; gap = Date.now() - t1; fs.unlinkSync(lp); return "EPERM"; }
      return null;
    });
    let runs = 0;
    m.withLock(lp, { staleMs: 60000 }, () => { runs++; });
    out([runs, denials, polls > 0, gap > m.LOCK_DENIED_MS, fs.existsSync(lp)].join(","));
  } else if (mode === "worker") {
    const [p, wid, count] = rest;
    for (let i = 0; i < Number(count); i++) {
      m.appendJsonlRotating(p, { id: "W" + wid + "#" + i, pad: "y".repeat(150) }, { maxBytes: 20000, maxRotated: 3 });
    }
  } else if (mode === "collect") {
    const p = rest[0];
    const ids = []; let broken = 0;
    for (const f of [p, p + ".1", p + ".2", p + ".3"]) for (const l of lines(f)) {
      try { ids.push(JSON.parse(l).id); } catch (_e) { broken++; }
    }
    out([ids.length, new Set(ids).size, broken, fs.existsSync(p + ".1") ? "rotated" : "no-rotation"].join(","));
  } else if (mode === "plant-dead") {
    fs.mkdirSync(path.dirname(rest[0]), { recursive: true });
    fs.writeFileSync(rest[0] + ".lock", "999999999.00112233deadbeef");
    age(rest[0] + ".lock", 20000);
    out("planted");
  } else if (mode === "residue") {
    out(fs.readdirSync(rest[0]).filter((f) => !/^c\.log(\.\d+)?$/.test(f)).join("|") || "clean");
  } else if (mode === "throw-release") {
    const lp = path.join(rest[0], "t.lock");
    let msg = "no-throw", gone = "THREW";
    try { m.withLock(lp, {}, () => { throw new Error("boom"); }); } catch (e) { msg = e.message; }
    const afterThrow = fs.existsSync(lp);
    try { gone = m.withLock(lp, {}, () => { fs.renameSync(lp, lp + ".gone"); return "r"; }); } catch (e) { gone = "THREW:" + e.code; }
    const afterGone = fs.existsSync(lp);
    const tokens = [];
    for (let i = 0; i < 2; i++) m.withLock(lp, {}, () => { tokens.push(fs.readFileSync(lp, "utf8")); });
    out([msg, afterThrow, gone, afterGone, tokens[0].length > 0, tokens[0] !== tokens[1], fs.existsSync(lp)].join(","));
  } else if (mode === "replaced-release") {
    // A successor's lock under our path (ours moved away) must survive our release.
    const lp = path.join(rest[0], "s.lock");
    const ret = m.withLock(lp, {}, () => { fs.renameSync(lp, lp + ".old"); fs.writeFileSync(lp, "successor-token"); return "a"; });
    out([ret, fs.existsSync(lp) && fs.readFileSync(lp, "utf8"), fs.readdirSync(rest[0]).sort().join("|")].join(","));
  } else if (mode === "stale-dead") {
    const res = [];
    const gone = require("child_process").spawnSync(process.execPath, ["-e", "0"]).pid;
    for (const [name, body, ageMs, opts] of [["d1", "foreign-token", 10000, {}],
      ["d2", "999999999.0011223344556677", 1000, { staleMs: 100 }], ["d3", "", 10000, {}],
      ["d4", gone + ".0011223344556677", 5000, {}]]) {
      const lp = path.join(rest[0], name + ".lock");
      fs.writeFileSync(lp, body); age(lp, ageMs);
      let during = null;
      m.withLock(lp, opts, () => { during = fs.readFileSync(lp, "utf8"); });
      res.push([during !== null, during !== body, fs.existsSync(lp)].join("/"));
    }
    const ap = path.join(rest[0], "a.log");
    fs.writeFileSync(ap + ".lock", "999999999.ffeeddccbbaa9988"); age(ap + ".lock", 10000);
    const r = m.appendJsonlRotating(ap, { k: 1 }, {});
    res.push(r.ok + "/" + lines(ap).length);
    out(res.join(",") + ",residue=" + (fs.readdirSync(rest[0]).filter((f) => f !== "a.log").join("|") || "none"));
  } else if (mode === "live-stale") {
    // Past staleMs but under the hard cap, a live holder (own pid / running child) is waited on.
    const [dir, who] = rest, lp = path.join(dir, "l.lock"), f = (n) => path.join(dir, n);
    const sleeper = who === "child" ? spawn(process.execPath, ["-e", "setTimeout(()=>{},60000)"], { stdio: "ignore" }) : null;
    const pid = sleeper ? sleeper.pid : process.pid;
    fs.writeFileSync(lp, pid + ".00112233aabbccdd"); age(lp, 3000);
    const w = child("wait-child", modPath, lp, "200", dir);
    const started = waitFor(() => fs.existsSync(f("w-started")), 15000);
    sleep(1000);
    const held = fs.existsSync(lp) && fs.readFileSync(lp, "utf8") === pid + ".00112233aabbccdd" && !fs.existsSync(f("w-ran"));
    age(lp, m.LOCK_HARD_STALE_MS + 5000);
    const ran = waitFor(() => fs.existsSync(f("w-ran")), 15000);
    const released = waitFor(() => !fs.existsSync(lp), 5000);
    w.kill(); if (sleeper) sleeper.kill();
    out([started, held, ran, released, fs.readdirSync(dir).filter((n) => /\.(steal|tomb)$/.test(n)).length].join(","));
  } else if (mode === "steal-gate") {
    // A fresh foreign .steal (kept fresh by touch) blocks stealing a dead lock; aged, it is cleared.
    const dir = rest[0], lp = path.join(dir, "g.lock"), sp = lp + ".steal", f = (n) => path.join(dir, n);
    const touch = (p) => { try { fs.utimesSync(p, new Date(), new Date()); } catch (_e) { /* removed */ } };
    fs.writeFileSync(lp, "999999999.00112233aabbccdd"); age(lp, 20000);
    fs.writeFileSync(sp, "other-stealer");
    const w = child("wait-child", modPath, lp, "200", dir);
    const started = waitFor(() => (touch(sp), fs.existsSync(f("w-started"))), 15000);
    waitFor(() => (touch(sp), false), 600);
    const blocked = fs.existsSync(sp) && !fs.existsSync(f("w-ran"))
      && fs.existsSync(lp) && fs.readFileSync(lp, "utf8") === "999999999.00112233aabbccdd";
    age(sp, m.LOCK_STALE_MS + 5000);
    const ran = waitFor(() => fs.existsSync(f("w-ran")), 15000);
    const released = waitFor(() => !fs.existsSync(lp), 5000);
    w.kill();
    out([started, blocked, ran, released, fs.existsSync(sp), fs.readdirSync(dir).filter((n) => /\.tomb$/.test(n)).length].join(","));
  } else if (mode === "hold-child") {
    const [lp, staleMs, holdMs, dir] = rest;
    m.withLock(lp, { staleMs: Number(staleMs) }, () => {
      fs.writeFileSync(path.join(dir, "b-acq.tmp"), fs.readFileSync(lp, "utf8"));
      fs.renameSync(path.join(dir, "b-acq.tmp"), path.join(dir, "b-acquired"));
      sleep(Number(holdMs));
      fs.writeFileSync(path.join(dir, "b-exited"), "1");
    });
  } else if (mode === "wait-child") {
    const [lp, staleMs, dir] = rest;
    fs.writeFileSync(path.join(dir, "w-started"), "1");
    m.withLock(lp, { staleMs: Number(staleMs) }, () => { fs.writeFileSync(path.join(dir, "w-ran"), "1"); });
  } else if (mode === "steal-successor") {
    // A is delayed past the hard cap; B (child) steals and holds; A then releases;
    // C (here) must not enter until B has exited.
    const dir = rest[0];
    const lp = path.join(dir, "x.lock");
    const f = (n) => path.join(dir, n);
    let bGot = false;
    const ret = m.withLock(lp, { staleMs: 200 }, () => {
      age(lp, 20000); // A is alive, so only an age past LOCK_HARD_STALE_MS lets B steal
      child("hold-child", modPath, lp, "200", "1500", dir);
      bGot = waitFor(() => fs.existsSync(f("b-acquired")), 15000);
      return "a";
    });
    const bToken = bGot ? fs.readFileSync(f("b-acquired"), "utf8") : null;
    const kept = fs.existsSync(lp) && fs.readFileSync(lp, "utf8") === bToken;
    const cAfterB = m.withLock(lp, { staleMs: 60000 }, () => fs.existsSync(f("b-exited")));
    waitFor(() => fs.existsSync(f("b-exited")), 15000);
    out([ret, bGot, kept, cAfterB, fs.existsSync(lp)].join(","));
  } else if (mode === "fresh-not-stolen") {
    const dir = rest[0];
    const lp = path.join(dir, "f.lock");
    fs.writeFileSync(lp, "foreign-fresh");
    child("wait-child", modPath, lp, "5000", dir);
    const started = waitFor(() => fs.existsSync(path.join(dir, "w-started")), 15000);
    sleep(600);
    const held = fs.existsSync(lp) && fs.readFileSync(lp, "utf8") === "foreign-fresh"
      && !fs.existsSync(path.join(dir, "w-ran"));
    fs.unlinkSync(lp);
    const ran = waitFor(() => fs.existsSync(path.join(dir, "w-ran")), 15000);
    const released = waitFor(() => !fs.existsSync(lp), 5000);
    out([started, held, ran, released].join(","));
  } else if (mode === "rtk-rotate") {
    const p = path.join(rest[0], "rtk.log");
    for (const [f, v] of [[p, "B"], [p + ".1", "R1"], [p + ".2", "R2"], [p + ".3", "R3"]]) fs.writeFileSync(f, v + "\n");
    const arity = m.rotate.length;
    m.rotate(p);
    const rd = (f) => fs.existsSync(f) ? fs.readFileSync(f, "utf8").trim() : "-";
    out([arity, m.MAX_ROTATED, rd(p), rd(p + ".1"), rd(p + ".2"), rd(p + ".3"), rd(p + ".4")].join(","));
  } else if (mode === "rtk-name") {
    process.env.AGENTS_STATE_DIR = rest[0];
    out(path.basename(m.resolveLogPath({})) + "," + (m.resolveLogPath({}) === path.join(rest[0], "logs", "rtk-guard-audit.log")));
  }
} catch (e) { out("THREW:" + e.message); }
EOF

probe() { run_with_timeout 60 node "$PROBE" "$@" 2>/dev/null; }
D="$(np "$TMP")"

case_begin "jrl-exports-and-defaults" "hooks/lib/jsonl-rotating-log.js"
assert_eq "$(probe exports "$JRL")" "1048576,3,function,function,function,function"
case_end

case_begin "jrl-append-one-line" "hooks/lib/jsonl-rotating-log.js"
mkdir -p "$TMP/basic"
assert_eq "$(probe append-basic "$JRL" "$D/basic")" "true,1,v"
case_end

# 40 records of ~80 bytes against maxBytes=300 must cycle base -> .1..3, drop .4,
# keep every line parseable, and leave the newest record (39) in the base file.
case_begin "jrl-rotation-small-max-bytes" "hooks/lib/jsonl-rotating-log.js"
mkdir -p "$TMP/rot"
assert_eq "$(probe rotation "$JRL" "$D/rot")" "11110,0,39,within"
case_end

case_begin "jrl-rotate-explicit-max-rotated" "hooks/lib/jsonl-rotating-log.js"
mkdir -p "$TMP/rd"
assert_eq "$(probe rotate-direct "$JRL" "$D/rd")" "-,B,R1,-"
case_end

case_begin "jrl-rotate-default-three-generations" "hooks/lib/jsonl-rotating-log.js"
mkdir -p "$TMP/re"
assert_eq "$(probe rotate-default "$JRL" "$D/re")" "-,B,R1,R2,-"
case_end

case_begin "jrl-fail-open-returns-ok-false" "hooks/lib/jsonl-rotating-log.js"
mkdir -p "$TMP/fo"
assert_eq "$(probe fail-open "$JRL" "$D/fo")" "false,true"
case_end

case_begin "jrl-resolve-log-dir-order" "hooks/lib/jsonl-rotating-log.js"
mkdir -p "$TMP/ld"
assert_eq "$(env -u AGENTS_STATE_DIR bash "$RWT" 60 node "$PROBE" log-dir "$JRL" "$D/ld" 2>/dev/null)" "true,true,true"
case_end

case_begin "jrl-with-lock-runs-and-releases" "hooks/lib/jsonl-rotating-log.js"
mkdir -p "$TMP/wl"
assert_eq "$(probe with-lock "$JRL" "$D/wl")" "true,true,false"
case_end

case_begin "jrl-exports-lock-denied-ms" "hooks/lib/jsonl-rotating-log.js"
assert_eq "$(probe lock-consts "$JRL")" "true,true,10000,function"
case_end

# Table: own pid / running child alive; unparseable, non-positive, never-used and
# exited-child pids are dead. Any mismatching token is printed instead of all-match.
case_begin "jrl-holder-alive-table" "hooks/lib/jsonl-rotating-log.js"
assert_eq "$(probe holder-alive "$JRL")" "all-match"
case_end

# Windows reports a delete-pending lock file as EPERM/EACCES, not EEXIST: two
# denied opens then a real one must still run fn once (3 opens) and release.
case_begin "jrl-with-lock-retries-denied-open" "hooks/lib/jsonl-rotating-log.js"
mkdir -p "$TMP/dr"
for code in EPERM EACCES; do
  assert_eq "$(probe denied-retry "$JRL" "$D/dr" "$code")" "1,ret,false,3"
done
case_end

case_begin "jrl-append-survives-denied-open" "hooks/lib/jsonl-rotating-log.js"
mkdir -p "$TMP/da"
for code in EPERM EACCES; do
  assert_eq "$(probe denied-append "$JRL" "$D/da" "$code")" "true,null,1,v,3"
done
case_end

case_begin "jrl-with-lock-denied-open-is-bounded" "hooks/lib/jsonl-rotating-log.js"
mkdir -p "$TMP/db"
assert_eq "$(probe denied-bounded "$JRL" "$D/db")" "EPERM,false,bounded,false,EPERM,false"
case_end

case_begin "jrl-with-lock-other-errors-still-throw" "hooks/lib/jsonl-rotating-log.js"
mkdir -p "$TMP/oe"
assert_eq "$(probe other-error "$JRL" "$D/oe")" "ENOSPC,1,false"
case_end

case_begin "jrl-with-lock-denied-window-resets-on-eexist" "hooks/lib/jsonl-rotating-log.js"
mkdir -p "$TMP/dz"
assert_eq "$(probe denied-reset "$JRL" "$D/dz")" "1,2,true,true,false"
case_end

# 4 processes x 50 records (~190 bytes each, 20000-byte cap) cross at least one
# rotation; every record must survive exactly once with no torn line.
case_begin "jrl-concurrent-append-four-processes" "hooks/lib/jsonl-rotating-log.js"
mkdir -p "$TMP/conc"
if [[ "$(probe exports "$JRL")" == LOAD-FAIL* ]]; then
  fail "concurrent append" "module not loaded"
else
  pids=()
  for w in 0 1 2 3; do
    run_with_timeout 90 node "$PROBE" worker "$JRL" "$D/conc/c.log" "$w" 50 >/dev/null 2>&1 &
    pids+=("$!")
  done
  rc_all=0
  for p in "${pids[@]}"; do wait "$p" || rc_all=1; done
  assert_eq "$rc_all" "0"
  assert_eq "$(probe collect "$JRL" "$D/conc/c.log")" "200,200,0,rotated"
fi
case_end

# Lock ownership: release removes only our own token; a stolen holder's late
# release must not delete the successor's lock (third caller would enter).
case_begin "jrl-release-after-steal-keeps-successor-lock" "hooks/lib/jsonl-rotating-log.js"
mkdir -p "$TMP/ss"
assert_eq "$(probe steal-successor "$JRL" "$D/ss")" "a,true,true,true,false"
case_end

case_begin "jrl-release-skips-replaced-lock" "hooks/lib/jsonl-rotating-log.js"
mkdir -p "$TMP/rr"
assert_eq "$(probe replaced-release "$JRL" "$D/rr")" "a,successor-token,s.lock|s.lock.old"
case_end

# After throw and after an externally removed lock the release stays clean;
# each acquisition writes a non-empty token distinct from the previous one.
case_begin "jrl-normal-release-removes-own-lock" "hooks/lib/jsonl-rotating-log.js"
mkdir -p "$TMP/tr"
assert_eq "$(probe throw-release "$JRL" "$D/tr")" "boom,false,r,false,true,true,false"
case_end

# Old-mtime locks with a dead holder (unparseable token, never-used pid, legacy
# empty file, exited child) are taken over and released; an append through a
# dead stale lock succeeds; no .steal or .tomb residue remains.
case_begin "jrl-stale-dead-lock-is-stolen" "hooks/lib/jsonl-rotating-log.js"
mkdir -p "$TMP/sd"
assert_eq "$(probe stale-dead "$JRL" "$D/sd")" "true/true/false,true/true/false,true/true/false,true/true/false,true/1,residue=none"
case_end

# Live holder past staleMs is not stolen until its age passes LOCK_HARD_STALE_MS.
case_begin "jrl-live-holder-waits-for-hard-cap" "hooks/lib/jsonl-rotating-log.js"
for who in self child; do
  mkdir -p "$TMP/ls-$who"
  assert_eq "$(probe live-stale "$JRL" "$D/ls-$who" "$who")" "true,true,true,true,0"
done
case_end

case_begin "jrl-steal-lock-serializes-stealers" "hooks/lib/jsonl-rotating-log.js"
mkdir -p "$TMP/sg"
assert_eq "$(probe steal-gate "$JRL" "$D/sg")" "true,true,true,true,false,0"
case_end

case_begin "jrl-fresh-lock-not-stolen" "hooks/lib/jsonl-rotating-log.js"
mkdir -p "$TMP/fr"
assert_eq "$(probe fresh-not-stolen "$JRL" "$D/fr")" "true,true,true,true"
case_end

# Same stress, but the run starts against a dead-pid stale lock: the racing
# writers steal it once (serialized via .steal), lose nothing, leave no residue.
case_begin "jrl-concurrent-append-over-dead-stale-lock" "hooks/lib/jsonl-rotating-log.js"
mkdir -p "$TMP/cs"
if [[ "$(probe plant-dead "$JRL" "$D/cs/c.log")" != "planted" ]]; then
  fail "concurrent append over dead stale lock" "lock not planted"
else
  pids=()
  for w in 0 1 2 3; do
    run_with_timeout 90 node "$PROBE" worker "$JRL" "$D/cs/c.log" "$w" 50 >/dev/null 2>&1 &
    pids+=("$!")
  done
  rc_all=0
  for p in "${pids[@]}"; do wait "$p" || rc_all=1; done
  assert_eq "$rc_all" "0"
  assert_eq "$(probe collect "$JRL" "$D/cs/c.log")" "200,200,0,rotated"
  assert_eq "$(probe residue "$JRL" "$D/cs")" "clean"
fi
case_end

case_begin "rtk-delegates-to-shared-module" "hooks/lib/rtk-guard-audit.js"
if grep -qE "require\([^)]*jsonl-rotating-log" "$SCRIPT_CHECKOUT_ROOT/$RTK_REL"; then
  pass "rtk-guard-audit requires the shared jsonl-rotating-log module"
else
  fail "rtk-guard-audit requires the shared jsonl-rotating-log module" "no require found"
fi
case_end

case_begin "rtk-rotate-one-arg-three-generations" "hooks/lib/rtk-guard-audit.js"
mkdir -p "$TMP/rtk"
assert_eq "$(probe rtk-rotate "$RTK" "$D/rtk")" "1,3,-,B,R1,R2,-"
case_end

case_begin "rtk-log-name-unchanged" "hooks/lib/rtk-guard-audit.js"
assert_eq "$(probe rtk-name "$RTK" "$D/rtkname")" "rtk-guard-audit.log,true"
case_end

case_begin "rtk-suite-2326-regression" "hooks/lib/rtk-guard-audit.js"
if run_with_timeout 150 node "$(np "$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-2326-rtk-guard-audit.js")" >"$TMP/rtk2326.out" 2>&1; then
  pass "feature-2326-rtk-guard-audit.js stays green"
else
  fail "feature-2326-rtk-guard-audit.js stays green" "$(tail -n 3 "$TMP/rtk2326.out" | tr '\n' ' ')"
fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
