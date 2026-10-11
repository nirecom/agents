"use strict";
// Arg-aware fake gh / glab preload for preflight-exec.sh and pr-state-cli.sh (not a test);
// modelled on tests/hooks/feature-2527-step-table/fake-gh.js. Inert unless this node process
// runs as `gh` or `glab` (node copies made by tests/lib/cli-stub.sh cli_stub_make).
// Env: FAKE_FORGE_STATE = OPEN | MERGED | CLOSED | NONE (exit 1, the CLI's own no-PR/MR stderr) |
//        FAIL (exit 2) | FAIL1 (exit 1, other stderr) | MALFORMED (exit 0, non-JSON) |
//        EMPTY (exit 0, no output) | <any other raw state>;
//      FAKE_FORGE_MERGE  gh mergeStateStatus (default CLEAN);
//      FAKE_GLAB_MERGE   glab detailed_merge_status (default mergeable); FAKE_GLAB_DRAFT=1;
//      FAKE_FORGE_NUMBER PR number / MR iid (default 42); FAKE_FORGE_LOG appends "<cwd>|<name> <args>".
const path = require("path");
const fs = require("fs");

const base = (p) => path.basename(String(p || "")).replace(/\.exe$/i, "").toLowerCase();
const me = [base(process.execPath), base(process.argv0)].find((b) => b === "gh" || b === "glab");
if (me) {
  const env = process.env;
  const a = process.argv.slice(1);
  if (a.length) a[0] = path.basename(a[0]);
  if (env.FAKE_FORGE_LOG) {
    fs.appendFileSync(env.FAKE_FORGE_LOG, process.cwd().replace(/\\/g, "/") + "|" + [me].concat(a).join(" ") + "\n");
  }
  const say = (s, rc) => { if (s) fs.writeSync(rc ? 2 : 1, s + "\n"); process.exit(rc); };
  const flag = (n) => { const i = a.indexOf(n); return i >= 0 && i + 1 < a.length ? a[i + 1] : null; };
  const state = env.FAKE_FORGE_STATE || "NONE";
  const num = Number(env.FAKE_FORGE_NUMBER || "42");
  const isView = me === "gh" ? a[0] === "pr" && a[1] === "view" : a[0] === "mr" && a[1] === "view";
  if (state === "FAIL") say("fake " + me + ": simulated API failure (HTTP 502)", 2);
  if (!isView) say("fake " + me + ": unsupported: " + a.join(" "), 2);
  if (state === "FAIL1") say("fake " + me + ": could not resolve host (HTTP 502)", 1);
  if (state === "NONE") {
    say(me === "gh" ? "no pull requests found for branch \"feature/x\""
      : "no open merge request available for \"feature/x\"", 1);
  }
  if (state === "MALFORMED") say("{not json", 0);
  if (state === "EMPTY") say("", 0);
  if (me === "gh") {
    const pr = { number: num, state, mergeStateStatus: env.FAKE_FORGE_MERGE || "CLEAN" };
    const fields = String(flag("--json") || "").split(",").filter(Boolean);
    if (a.includes("--jq") || a.includes("-q")) say(fields.map((f) => String(pr[f])).join(" "), 0);
    const o = {};
    for (const f of fields.length ? fields : Object.keys(pr)) o[f] = pr[f];
    say(JSON.stringify(o), 0);
  }
  const GL = { OPEN: "opened", MERGED: "merged", CLOSED: "closed" };
  const mr = {
    iid: num,
    state: GL[state] || state.toLowerCase(),
    detailed_merge_status: env.FAKE_GLAB_MERGE || "mergeable",
    draft: env.FAKE_GLAB_DRAFT === "1",
  };
  const jq = flag("--jq");
  if (jq) say(String(mr[jq.replace(/^\./, "")]), 0);
  say(JSON.stringify(mr), 0);
}
