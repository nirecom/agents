#!/usr/bin/env node
"use strict";
// Retention race probe for i-retention.sh (#2460): node retention-probe.js <retention.js> <pending.js> <cmd> ...
//   race <sid> <mode>: stale dir, beforeRemove acts between tombstone rename and re-check;
//     modes none|live|both|tomb|tomb-file|conflict (see raceHook). Prints
//     "<removed>|<hook seen>|<live dir>|<live pending>|<.tomb-* count>|<mode extra>".
//   tombs: leftover .tomb-* dirs of several ages and contents, one default due sweep;
//     prints "<removed>|<.tomb-* left>|<bbb pending>|<ddd pending>".
//   tomb-restore <sid> | tomb-merge <sid> | tomb-invalid: leftover tombs holding entries (see each function).
//   ticket-files <sid>: stage-2 versioned and ticket files in a stale and a fresh session (see ticketFiles).
const fs = require("fs");
const path = require("path");

const [retPath, pendPath, cmd, ...a] = process.argv.slice(2);
const retention = require(retPath);
const pending = require(pendPath);
const root = path.join(process.env.AGENTS_STATE_DIR, "jev");
const DAY = 86400000;
const setAge = (p, ms) => { const t = (Date.now() - ms) / 1000; fs.utimesSync(p, t, t); };
const list = (d) => { try { return fs.readdirSync(d).sort().join(","); } catch (_e) { return ""; } };
const tombs = () => { try { return fs.readdirSync(root).filter((n) => n.startsWith(".tomb-")).sort(); } catch (_e) { return []; } };
const put = (dir, name, text) => { fs.mkdirSync(dir, { recursive: true }); fs.writeFileSync(path.join(dir, name), text); };
const read = (p) => { try { return fs.readFileSync(p, "utf8"); } catch (_e) { return "-"; } };

function ageAll(p, ms) {
  for (const e of fs.readdirSync(p)) {
    const c = path.join(p, e);
    if (fs.statSync(c).isDirectory()) ageAll(c, ms);
    else setAge(c, ms);
  }
  setAge(p, ms);
}

// none: nothing written. live: a pending into the recreated ORIGINAL path. both: a pending in
// the tombstone and another in the recreated live dir. tomb: a pending in the tombstone only.
// tomb-file: a fresh non-pending file in the tombstone. conflict: same-name pending in both.
function raceHook(mode, live, tomb) {
  const tp = path.join(tomb, "pending");
  if (mode === "live" || mode === "both") put(path.join(live, "pending"), "toolu_i_live.json", "{}");
  if (mode === "both" || mode === "tomb") put(tp, "toolu_i_tomb.json", "{}");
  if (mode === "tomb-file") put(tomb, "late-write.json", "{}");
  if (mode === "conflict") {
    put(tp, "toolu_i_x.json", "TOMB");
    put(path.join(live, "pending"), "toolu_i_x.json", "LIVE");
  }
}

function race(sid, mode) {
  const live = path.join(root, sid);
  const pd = pending.pendingDir(sid);
  fs.mkdirSync(pd, { recursive: true });
  fs.writeFileSync(path.join(pd, "toolu_i_seed.json"), JSON.stringify({ point: "complexity-judge" }));
  ageAll(live, 2 * 3600000);
  let seen = "hook-not-called";
  const beforeRemove = (s, tomb) => {
    const base = path.basename(tomb);
    seen = [s === sid && base.startsWith(".tomb-" + sid + "-") && /^\d+$/.test(base.slice(7 + sid.length)),
      fs.existsSync(tomb), !fs.existsSync(live)].join(",");
    raceHook(mode, live, tomb);
  };
  const removed = retention.sweepStateDirs({ maxAgeDays: 0.0001, onOrphan: () => ({ ok: true }), beforeRemove });
  let extra = "";
  if (mode === "tomb-file") extra = fs.existsSync(path.join(live, "late-write.json")) ? "file-kept" : "file-lost";
  if (mode === "conflict") {
    const t = tombs()[0];
    extra = read(path.join(live, "pending", "toolu_i_x.json")) + "/" + (t ? read(path.join(root, t, "pending", "toolu_i_x.json")) : "-");
  }
  process.stdout.write([removed.join(","), seen, fs.existsSync(live) ? "present" : "absent", list(path.join(live, "pending")),
    tombs().length, extra].join("|"));
}

function leftovers() {
  const mk = (name, rel, ageMs) => {
    const d = path.join(root, name);
    if (rel) put(path.join(d, path.dirname(rel)), path.basename(rel), "{}");
    else fs.mkdirSync(d, { recursive: true });
    ageAll(d, ageMs);
  };
  mk(".tomb-aaa-123", "stale.json", 10 * DAY);
  mk(".tomb-bbb-456", "pending/toolu_k.json", 10 * DAY);
  mk(".tomb-ccc-789", null, DAY);
  mk(".tomb-ddd-111", "pending/toolu_k.unlogged-1-2", 10 * DAY);
  const removed = retention.sweepStateDirs({ onOrphan: () => ({ ok: true }) });
  process.stdout.write([removed.join(","), tombs().join(","), list(path.join(root, "bbb", "pending")),
    list(path.join(root, "ddd", "pending"))].join("|"));
}

const HAND = JSON.stringify({ point: "complexity-judge" });
function staleTomb(name, entries) {
  const d = path.join(root, name);
  for (const [n, text] of entries) put(path.join(d, "pending"), n, text);
  ageAll(d, 10 * DAY);
  return d;
}

// Stale tomb with an unlogged entry, no live dir; a due sweep, then one 8 days on.
// Prints "<removed1>|<calls1>|<live pending>|<tomb left>|<removed2>|<calls2>".
function tombRestore(sid) {
  const tomb = staleTomb(".tomb-" + sid + "-1234567", [["toolu_r.unlogged-1-2", HAND]]);
  const calls = [];
  const onOrphan = (s, tid) => { calls.push(s + ":" + tid); return { ok: true }; };
  const now = Date.now();
  const r1 = retention.sweepStateDirs({ now: () => now, onOrphan });
  const first = [r1.join(","), calls.splice(0).join(","), list(path.join(root, sid, "pending")), fs.existsSync(tomb)];
  const r2 = retention.sweepStateDirs({ now: () => now + 8 * DAY, onOrphan });
  process.stdout.write(first.concat([r2.join(","), calls.join(",")]).join("|"));
}

// Beside a fresh live dir sharing one entry name. Prints "<live pending>|<live shared copy>|<tomb left>|<tomb pending>".
function tombMerge(sid) {
  put(path.join(root, sid, "pending"), "toolu_m_x.json", "LIVE");
  const tomb = staleTomb(".tomb-" + sid + "-7654321", [["toolu_m_x.json", "TOMB"], ["toolu_m_y.json", HAND]]);
  retention.sweepStateDirs({ onOrphan: () => ({ ok: true }) });
  process.stdout.write([list(path.join(root, sid, "pending")), read(path.join(root, sid, "pending", "toolu_m_x.json")),
    fs.existsSync(tomb), list(path.join(tomb, "pending"))].join("|"));
}

// Sid part invalid or no -<digits> suffix. Prints "<.tomb-* left>|<non-dot root entries>|<tomb pending>".
function tombInvalid() {
  const names = [".tomb-a..b-123", ".tomb--456", ".tomb-nodigits"];
  for (const n of names) staleTomb(n, [["toolu_v.json", HAND]]);
  retention.sweepStateDirs({ onOrphan: () => ({ ok: true }) });
  let rootNames = [];
  try { rootNames = fs.readdirSync(root).filter((n) => !n.startsWith(".")).sort(); } catch (_e) { rootNames = []; }
  process.stdout.write([tombs().join(","), rootNames.join(","),
    names.map((n) => list(path.join(root, n, "pending"))).join(",")].join("|"));
}

// A stale session holding every stage-2 file kind (versioned pending ticket hand, breaker and
// liveness, ticket snapshot/answer/merged files, a done marker, jev-sources/<ticket>/) beside a
// fresh session holding the same kinds. Prints
// "<removed>|<stale dir>|<onOrphan calls>|<fresh dir>|<fresh files>".
function ticketFiles(sid) {
  const T = "tkt-2460-i";
  const seed = (s) => {
    const d = path.join(root, s);
    put(path.join(d, "pending"), T + ".json",
      JSON.stringify({ version: 2, kind: "cli-ticket", point: "complexity-judge", stage: "outline", mode: "shadow" }));
    put(d, "breaker.json", JSON.stringify({ version: 2, count: 0, open_until: 0 }));
    put(d, "breaker-complexity-judge.json", JSON.stringify({ version: 2, count: 0, open_until: 0 }));
    put(d, "liveness.json", JSON.stringify({ version: 1, ok_ms: 0 }));
    put(path.join(d, "tickets"), T + ".snapshot.md", "# snapshot\n");
    put(path.join(d, "tickets"), T + ".answer.json", "{}");
    put(path.join(d, "tickets"), T + ".merged.json", "{}");
    put(path.join(d, "tickets-done"), T + ".json",
      JSON.stringify({ version: 1, point: "complexity-judge", stage: "outline", created_ms: 1, exit: 0, stdout_lines: [] }));
    put(path.join(d, "jev-sources", T), "intent.md", "# intent\n");
    return d;
  };
  const stale = seed(sid);
  ageAll(stale, 10 * DAY);
  const fresh = seed(sid + "-fresh");
  const calls = [];
  const removed = retention.sweepStateDirs({ onOrphan: (s, tid) => { calls.push(s + ":" + tid); return { ok: true }; } });
  const walk = (d, pre) => {
    let out = [];
    for (const e of fs.readdirSync(d).sort()) {
      const c = path.join(d, e);
      out = fs.statSync(c).isDirectory() ? out.concat(walk(c, pre + e + "/")) : out.concat(pre + e);
    }
    return out;
  };
  process.stdout.write([removed.join(","), fs.existsSync(stale) ? "present" : "absent", calls.join(","),
    fs.existsSync(fresh) ? "present" : "absent", fs.existsSync(fresh) ? walk(fresh, "").length : 0].join("|"));
}

try {
  if (cmd === "ticket-files") ticketFiles(a[0]);
  else if (cmd === "race") race(a[0], a[1]);
  else if (cmd === "tombs") leftovers();
  else if (cmd === "tomb-restore") tombRestore(a[0]);
  else if (cmd === "tomb-merge") tombMerge(a[0]);
  else if (cmd === "tomb-invalid") tombInvalid();
} catch (e) {
  process.stdout.write("THREW:" + e.message);
}
