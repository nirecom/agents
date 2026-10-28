"use strict";
// Fixture builders for tests/bin/fix-2748-orphan-progress-migration.js. The caller runs
// harness.isolate() before requiring this module, so every path below is a pinned temp dir.
// A session chain is built with the real applyInheritance, then given the pre-#2748 trace: no
// first_session_id on the session-downstream and its sidecar pinned to itself.

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const F = require("../../hooks/feature-2304-inheritance-state-copy/fixture");
const PF = F.mod("hooks/lib/progress-file");
const PLANS = process.env.WORKFLOW_PLANS_DIR;
const STATES = process.env.WORKFLOW_STATE_DIR;
const CLI = path.join(F.ROOT, "bin", "migrate-orphan-progress-files");
const INDEX = path.join(F.ROOT, "hooks", "lib", "temporary-migrations", "orphan-progress-file", "index.js");

// Guarded: the module is new in #2748.
let IDX = null;
let loadError = null;
try { IDX = require(INDEX); } catch (e) { loadError = e; }
let SA = null;
try { SA = F.mod("hooks/workflow-state/state-ancestry"); } catch (_) { SA = null; }
function firstSidOf(sid) {
  if (!SA || typeof SA.resolveFirstSid !== "function") throw new Error("state-ancestry.js resolveFirstSid not loadable");
  return SA.resolveFirstSid(sid);
}

const counts = { passed: 0, failed: 0 };
function check(name, fn) {
  let why = null;
  try {
    const r = fn();
    if (typeof r === "string") why = r;
  } catch (e) {
    why = e && e.message ? e.message : String(e);
  }
  if (why === null) {
    counts.passed += 1;
    process.stdout.write(`PASS: ${name}\n`);
  } else {
    counts.failed += 1;
    process.stdout.write(`FAIL: ${name} — ${why}\n`);
  }
}
const show = (v) => (v === undefined ? "undefined" : JSON.stringify(v));

let neutral = null;
function cli(args) {
  if (!neutral) neutral = fs.mkdtempSync(path.join(path.dirname(STATES), "cwd-"));
  const env = Object.assign({}, process.env, { HOME: neutral, USERPROFILE: neutral });
  delete env.CLAUDE_CODE_SESSION_ID;
  return spawnSync(process.execPath, [CLI].concat(args), { cwd: neutral, env, encoding: "utf8", timeout: 60000 });
}
const errLine = (s) => {
  const lines = String(s || "").split(/\r?\n/);
  return lines.find((l) => /Error|Cannot/.test(l)) || lines[0];
};
const why = (r) => `exit=${r.status} stdout=${show(r.stdout)} stderr=${show(errLine(r.stderr))}`;

// runIndex(argv, hooks) — index.js run() in-process, stdout/stderr captured.
async function runIndex(argv, hooks) {
  if (!IDX || typeof IDX.run !== "function") {
    return { unavailable: `index.js run() unavailable: ${loadError ? String(loadError.message).split("\n")[0] : "no run export"}` };
  }
  let written = "";
  let code = null;
  let error = null;
  const [ow, ew] = [process.stdout.write, process.stderr.write];
  process.stdout.write = process.stderr.write = (chunk) => { written += String(chunk); return true; };
  try {
    const res = await IDX.run(argv, hooks);
    code = res && typeof res === "object" ? res.exitCode : res;
  } catch (e) {
    error = e;
  } finally {
    process.stdout.write = ow;
    process.stderr.write = ew;
  }
  return { code, written, error };
}

const progressOf = (sid) => path.join(PLANS, `${sid}-session-progress.md`);
const planOf = (sid, stage) => path.join(PLANS, `${sid}-${stage}.md`);
const read = (p) => (fs.existsSync(p) ? fs.readFileSync(p, "utf8") : null);
const pinnedSid = (sid) => (PF.readPressure(sid) || {}).root_sid;
const pin = (sid, firstSid) => {
  if (!PF.mergePressure(sid, { root_sid: firstSid })) throw new Error(`could not pin ${sid}`);
};
const noteFiles = () => fs.readdirSync(PLANS).filter((n) => n.includes("-note-"));

// resetAll() — no session chain of an earlier case is left for the CLI to pick up.
function resetAll() {
  for (const dir of [PLANS, STATES]) for (const n of fs.readdirSync(dir)) fs.rmSync(path.join(dir, n), { recursive: true, force: true });
}
function snapshot() {
  const out = {};
  const walk = (dir) => {
    for (const d of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, d.name);
      if (d.isDirectory()) walk(p);
      else out[p] = fs.readFileSync(p, "utf8");
    }
  };
  walk(PLANS);
  walk(STATES);
  return out;
}
function changedSince(before) {
  const after = snapshot();
  return Object.keys(Object.assign({}, before, after)).filter((k) => before[k] !== after[k]);
}

// adoptChain(sids) — sids[0] is the first generation; each next sid adopts from the one before it
// and is left with the pre-#2748 trace (no first_session_id, sidecar pinned to itself).
function adoptChain(sids) {
  F.seedDownstream(sids[0]);
  for (let i = 1; i < sids.length; i++) {
    const res = F.mod("hooks/workflow-state/inheritance/apply").applyInheritance(sids[i], F.seedDownstream(sids[i]), sids[i - 1]);
    if (!res || res.ok === false) throw new Error(`applyInheritance(${sids[i]}, ${sids[i - 1]}) failed: ${show(res)}`);
    const st = F.raw(sids[i]);
    delete st.first_session_id;
    F.writeRaw(sids[i], st);
    pin(sids[i], sids[i]);
  }
}
const firstText = (firstSid) => ["# progress", "", "## Current state", "", "marker-cs-first", "", "## Plan files", "",
  `- intent: ${planOf(firstSid, "intent")}`, "", "## Facts to carry over", "", "### User decisions", "",
  "- first decision", "- shared bullet", "", "### Deviations", "", "- first deviation", "", "### Rejected approaches", "",
  "### Open questions", ""].join("\n");
const downstreamText = (downstreamSid) => ["# progress", "", "## Current state", "", "marker-cs-downstream", "", "## Plan files", "",
  `- intent: ${planOf(downstreamSid, "intent")}`, `- outline: ${planOf(downstreamSid, "outline")}`,
  `- detail: ${planOf(downstreamSid, "detail")}`, "", "## Facts to carry over", "", "### User decisions", "",
  "- downstream decision", "- shared bullet  ", "","### Deviations", "", "- downstream deviation", "", "### Extra notes", "",
  "- downstream extra", ""].join("\n");
// The first generation's file as a crash after step 2 leaves it: it already carries the downstream's facts.
const mergedFirst = (firstSid) => firstText(firstSid).replace("- shared bullet\n", "- shared bullet\n- downstream decision\n")
  .replace("- first deviation\n", "- first deviation\n- downstream deviation\n")
  .replace("### Open questions\n", "### Open questions\n\n### Extra notes\n\n- downstream extra\n");

const HOUR = 3600 * 1000;
function age(file, msAgo) {
  if (!fs.existsSync(file)) return;
  const t = new Date(Date.now() - msAgo);
  fs.utimesSync(file, t, t);
}
// settle(sids, downstreamNewer) — every state, plan and progress file of the chain is past the
// 30-minute activity window; the newest generation's progress file is the newest unless
// downstreamNewer is false.
function settle(sids, downstreamNewer) {
  sids.forEach((sid, i) => {
    age(F.statePath(sid), 4 * HOUR);
    for (const stage of ["intent", "outline", "detail"]) age(planOf(sid, stage), 4 * HOUR - i * 60000);
    const rank = downstreamNewer === false ? sids.length - i : i + 1;
    age(progressOf(sid), (4 * HOUR) - rank * 20 * 60000 - HOUR);
  });
}
// setup(prefix, opts) — a fresh first generation and one session-downstream with both progress files.
// opts: firstFile (false = no first progress file), firstBody, downstreamNewer, settle (false = active),
// firstPlans / downstreamPlans ({ stage: body }).
function setup(prefix, opts) {
  const o = opts || {};
  resetAll();
  const firstSid = `${prefix}-first`;
  const downstreamSid = `${prefix}-downstream`;
  adoptChain([firstSid, downstreamSid]);
  if (o.firstFile !== false) fs.writeFileSync(progressOf(firstSid), o.firstBody || firstText(firstSid));
  fs.writeFileSync(progressOf(downstreamSid), downstreamText(downstreamSid));
  for (const [stage, body] of Object.entries(o.firstPlans || {})) fs.writeFileSync(planOf(firstSid, stage), body);
  for (const [stage, body] of Object.entries(o.downstreamPlans || {})) fs.writeFileSync(planOf(downstreamSid, stage), body);
  if (o.settle !== false) settle([firstSid, downstreamSid], o.downstreamNewer);
  return { firstSid, downstreamSid };
}
// section(text, heading) — trimmed non-empty lines under heading, up to the next heading of the same or higher level.
function section(text, heading) {
  const lines = String(text || "").split(/\r?\n/);
  const at = lines.indexOf(heading);
  if (at < 0) return null;
  const level = heading.match(/^#+/)[0].length;
  const out = [];
  for (const line of lines.slice(at + 1)) {
    const m = line.match(/^(#+) /);
    if (m && m[1].length <= level) break;
    if (line.trim()) out.push(line.trim());
  }
  return out;
}
const count = (text, needle) => String(text || "").split(needle).length - 1;

module.exports = {
  F, PF, PLANS, STATES, CLI, INDEX, firstSidOf, counts, check, show, cli, why, runIndex,
  progressOf, planOf, read, pinnedSid, pin, noteFiles, resetAll, snapshot, changedSince, adoptChain,
  firstText, downstreamText, mergedFirst, HOUR, age, settle, setup, section, count,
};
