"use strict";
// Arg-aware fake gh / glab preload for the release-phase suites (not a test); inert unless this
// node process runs as `gh` / `glab` (tests/lib/cli-stub.sh node copies) or as bin/workflow/pr-state.
// Env: FAKE_FORGE_STATE = OPEN | MERGED | CLOSED | NONE (exit 1, no-PR/MR stderr) | FAIL (exit 2) |
//        FAIL1 (exit 1) | MALFORMED | EMPTY | RATELIMIT (exit 1, HTTP 403) | AUTH (exit 1, HTTP 401);
//      FAKE_FORGE_MERGE gh mergeStateStatus (default CLEAN); FAKE_GLAB_MERGE glab
//        detailed_merge_status (default mergeable); FAKE_GLAB_DRAFT=1; FAKE_FORGE_NUMBER (default 42);
//      FAKE_FORGE_LOG appends "<cwd>|<name> <args>"; FAKE_FORGE_DELAY_MS delays gh / glab.
const path = require("path");
const fs = require("fs");

const base = (p) => path.basename(String(p || "")).replace(/\.exe$/i, "").toLowerCase();
const me = [base(process.execPath), base(process.argv0)].find((b) => b === "gh" || b === "glab");
const env = process.env;

// FAKE_PRSTATE_SEQ: a file of states, one per line. Each pr-state run pops the first line into
// <file>.cur (the last line is sticky); gh / glab then answer from <file>.cur instead of
// FAKE_FORGE_STATE. FAKE_PRSTATE_LOG appends "<epoch ms>|<cwd>" per pr-state run.
if (!me && base(process.argv[1]) === "pr-state") {
  if (env.FAKE_PRSTATE_LOG) {
    fs.appendFileSync(env.FAKE_PRSTATE_LOG, Date.now() + "|" + process.cwd().replace(/\\/g, "/") + "\n");
  }
  if (env.FAKE_PRSTATE_SEQ) {
    let lines = [];
    try { lines = fs.readFileSync(env.FAKE_PRSTATE_SEQ, "utf8").split(/\r?\n/).filter(Boolean); } catch (_) { /* no seq */ }
    if (lines.length) {
      fs.writeFileSync(env.FAKE_PRSTATE_SEQ + ".cur", lines[0]);
      if (lines.length > 1) fs.writeFileSync(env.FAKE_PRSTATE_SEQ, lines.slice(1).join("\n") + "\n");
    }
  }
}

if (me) {
  const a = process.argv.slice(1);
  if (a.length) a[0] = path.basename(a[0]);
  if (env.FAKE_FORGE_LOG) {
    fs.appendFileSync(env.FAKE_FORGE_LOG, process.cwd().replace(/\\/g, "/") + "|" + [me].concat(a).join(" ") + "\n");
  }
  const delay = Number(env.FAKE_FORGE_DELAY_MS || "0");
  if (delay > 0) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, delay);
  const say = (s, rc) => { if (s) fs.writeSync(rc ? 2 : 1, s + "\n"); process.exit(rc); };
  const flag = (n) => { const i = a.indexOf(n); return i >= 0 && i + 1 < a.length ? a[i + 1] : null; };
  let state = env.FAKE_FORGE_STATE || "NONE";
  if (env.FAKE_PRSTATE_SEQ) {
    try { state = fs.readFileSync(env.FAKE_PRSTATE_SEQ + ".cur", "utf8").trim() || state; } catch (_) { /* no .cur yet */ }
  }
  const num = Number(env.FAKE_FORGE_NUMBER || "42");
  const isView = me === "gh" ? a[0] === "pr" && a[1] === "view" : a[0] === "mr" && a[1] === "view";
  if (state === "FAIL") say("fake " + me + ": simulated API failure (HTTP 502)", 2);
  if (!isView) say("fake " + me + ": unsupported: " + a.join(" "), 2);
  if (state === "FAIL1") say("fake " + me + ": could not resolve host (HTTP 502)", 1);
  if (state === "RATELIMIT") say("API rate limit exceeded (HTTP 403)", 1);
  if (state === "AUTH") say("HTTP 401: Bad credentials", 1);
  if (state === "NONE") {
    say(me === "gh" ? "no pull requests found for branch \"feature/x\""
      : "no open merge request available for \"feature/x\"", 1);
  }
  if (state === "MALFORMED") say("{not json", 0);
  if (state === "EMPTY") say("", 0);
  if (me === "gh") {
    const pr = { number: num, state, mergeStateStatus: env.FAKE_FORGE_MERGE || "CLEAN",
      url: "https://github.com/example/repo/pull/" + num };
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
    web_url: "https://gitlab.com/example/repo/-/merge_requests/" + num,
  };
  const jq = flag("--jq");
  if (jq) say(String(mr[jq.replace(/^\./, "")]), 0);
  say(JSON.stringify(mr), 0);
}
