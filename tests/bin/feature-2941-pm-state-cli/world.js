"use strict";
// The seeded PM world and forge tree of tests/bin/feature-2941-pm-state-cli.js (#2941). No case markers.
//   PM-cliA (active, current)  #100 (meta, init 11-01), #300 (labels overflow)   old generation: #100, #150
//   PM-cliB (active)           #200 (meta, init 11-03)      PM-cliC (archived): #400
//   PM-cliE (active)           x/y#950 (plain)              PM-cliF (active): #103 (direct, also under meta #100)
//   PM-tieA / PM-tieB          both hold #960 at the same time (PM-tieB has the smaller sid)
//   PM-early / PM-late         hold #970 directly, PM-early assigned first; plain session D (no pm)
// Forge: 101->100, 102->101, 103->100, 202->200->100, 301->300, 500->501 (root, out of range),
// 600<->601 (cycle), 700->…->715 (deeper than 10), 800 fails the call, 111/112->110->100,
// x/y#900 -> o/r#100 (cross-repo), x/y#951 -> x/y#950, 1000+i -> 100 for i < CAP_CHAINS.
const { parent } = require("./fixture");
const P = require("../../lib/pm-state-fixture");

const SID = {
  A: P.uuid(0x29416001), Aold: P.uuid(0x29416002), B: P.uuid(0x29416003), C: P.uuid(0x29416004), D: P.uuid(0x29416005),
  E: P.uuid(0x29416006), F: P.uuid(0x29416007), tieB: P.uuid(0x29416008), tieA: P.uuid(0x29416009),
  early: P.uuid(0x2941600b), late: P.uuid(0x2941600a),
};
const TAG = { A: "PM-cliA", B: "PM-cliB", C: "PM-cliC", E: "PM-cliE", F: "PM-cliF", tieA: "PM-tieA", tieB: "PM-tieB", early: "PM-early", late: "PM-late" };
const CAP_CHAINS = 51;
const logAt = (at, issues) => [{ at, op: "init", issues: issues.map((n) => (typeof n === "object" ? n : { number: n })), reason: "fixture" }];
const held = (tag, issues, at, extra) => P.pm(Object.assign({ tag, issues, current_since: at, assignment_log: logAt(at, issues) }, extra || {}));

function seedWorld(F) {
  P.seedPm(SID.Aold, held(TAG.A, [100, 150], "2026-10-01T00:00:00.000Z"));
  P.seedPm(SID.A, held(TAG.A, [100, 300], "2026-11-01T00:00:00.000Z", { upstream_session_id: SID.Aold }));
  P.seedPm(SID.B, held(TAG.B, [200], "2026-11-03T00:00:00.000Z"));
  P.seedPm(SID.C, held(TAG.C, [400], "2026-11-01T00:00:00.000Z", { archived_at: "2026-11-02T00:00:00.000Z" }));
  P.seedState(SID.D);
  P.seedPm(SID.E, held(TAG.E, [{ number: 950, repo: "x/y" }], "2026-11-01T00:00:00.000Z"));
  P.seedPm(SID.F, held(TAG.F, [103], "2026-11-04T00:00:00.000Z"));
  P.seedPm(SID.tieB, held(TAG.tieB, [960], "2026-11-05T00:00:00.000Z"));
  P.seedPm(SID.tieA, held(TAG.tieA, [960], "2026-11-05T00:00:00.000Z"));
  P.seedPm(SID.late, held(TAG.late, [970], "2026-11-06T00:00:00.000Z"));
  P.seedPm(SID.early, held(TAG.early, [970], "2026-11-02T00:00:00.000Z"));
  const meta = (p) => Object.assign(p || { parent: null }, { labels: ["meta"] });
  const map = {
    "o/r#100": meta(), "o/r#101": parent(100), "o/r#102": parent(101), "o/r#103": parent(100),
    "o/r#200": meta(parent(100)), "o/r#202": parent(200),
    "o/r#300": { parent: null, labels: ["a"], more: true }, "o/r#301": parent(300),
    "o/r#500": parent(501), "o/r#501": { parent: null },
    "o/r#600": parent(601), "o/r#601": parent(600),
    "o/r#800": { fail: true },
    "o/r#111": parent(110), "o/r#112": parent(110), "o/r#110": parent(100),
  };
  for (let i = 700; i < 715; i++) map[`o/r#${i}`] = parent(i + 1);
  map["x/y#900"] = parent(100, "o/r");
  map["x/y#100"] = { parent: null };
  map["x/y#951"] = parent(950, "x/y");
  for (let i = 0; i < CAP_CHAINS; i++) map[`o/r#${1000 + i}`] = parent(100);
  F.setMap(map);
}

module.exports = { SID, TAG, CAP_CHAINS, seedWorld };
