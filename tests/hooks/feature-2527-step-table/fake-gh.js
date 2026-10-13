"use strict";
// Arg-aware fake gh preload for resume-from-v4.sh (not a test); modelled on tests/lib/cli-stub.sh.
// Inert unless this node process runs as `gh`; FAKE_GH_STATE=OPEN|MERGED|CLOSED|NONE|FAIL, FAKE_GH_LOG appends calls.
const path = require("path");
const fs = require("fs");

const base = (p) => path.basename(String(p || "")).replace(/\.exe$/i, "").toLowerCase();
if (base(process.execPath) === "gh" || base(process.argv0) === "gh") {
  const a = process.argv.slice(1);
  if (a.length) a[0] = path.basename(a[0]);
  if (process.env.FAKE_GH_LOG) fs.appendFileSync(process.env.FAKE_GH_LOG, ["gh"].concat(a).join(" ") + "\n");
  const state = process.env.FAKE_GH_STATE || "NONE";
  const say = (s, rc) => { fs.writeSync(rc ? 2 : 1, s + "\n"); process.exit(rc); };
  if (state === "FAIL") say("fake gh: simulated API failure", 1);
  if (a[0] === "auth") say("Logged in to github.com", 0);
  if (a[0] === "issue") say(JSON.stringify({ number: 2527, title: "fixture", state: "OPEN" }), 0);
  if (a[0] === "pr") {
    const pr = {
      number: 7,
      state,
      url: "https://github.com/acme/widgets/pull/7",
      headRefName: "feature/2527-fixture",
      mergedAt: state === "MERGED" ? "2026-01-01T00:00:00Z" : null,
      mergeStateStatus: "CLEAN",
    };
    // FAKE_GH_HEAD: the PR's head commit; unset = the forge reports none.
    if (process.env.FAKE_GH_HEAD) pr.headRefOid = process.env.FAKE_GH_HEAD;
    const jq = a.includes("--jq") || a.includes("-q");
    if (a[1] === "list") {
      if (jq) say(state === "NONE" ? "" : state, 0);
      say(JSON.stringify(state === "NONE" ? [] : [pr]), 0);
    }
    if (a[1] === "view") {
      if (state === "NONE") say("no pull requests found for branch", 1);
      say(jq ? state : JSON.stringify(pr), 0);
    }
  }
  say("", 0);
}
