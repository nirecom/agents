"use strict";
// node probe.js <SCRIPT_CHECKOUT_ROOT> <mode> [args...] — one call into the code under test.
// Prints one result line with "\" folded to "/"; a throw prints ERR:<name>:<message>.
const fs = require("fs");
const path = require("path");

const [A, mode, ...args] = process.argv.slice(2);
const io = (rel) => require(path.join(A, "hooks", "workflow-state", "state-io", rel));
const lib = (rel) => require(path.join(A, "hooks", rel));
const norm = (v) => String(v).replace(/\\/g, "/");
const opts = (s) => (s ? JSON.parse(s) : undefined);
const out = (v) => process.stdout.write(`${norm(v)}\n`);
const root = () => io("state-root");

function tryOk(fn) {
  try { fn(); return "ok"; } catch (_) { return "err"; }
}

function seed(dir, sid, extra) {
  const core = io("core");
  const st = Object.assign(core.createInitialState(sid, { cwd: null }), extra ? JSON.parse(extra) : {});
  fs.mkdirSync(dir, { recursive: true });
  let body;
  try { body = io("projection").serializeStateForPersist(st); } catch (_) { body = JSON.stringify(st); }
  fs.writeFileSync(path.join(dir, `${sid}.json`), body);
  return path.join(dir, `${sid}.json`);
}

const MODES = {
  root: () => root().getStateRoot(opts(args[0])),
  dir: () => root().getSessionStateDir(args[0], opts(args[1])),
  roots: () => JSON.stringify(root().listStateRoots(opts(args[0])).map(norm)),
  // C5: the env pin as a native parent passes it — `/` + args[0] is assembled here, so
  // Git Bash never rewrites a driveless `/tmp/x` into its drive form on the way in.
  rawpin: () => { process.env.WORKFLOW_STATE_DIR = `/${args[0]}`; return root().getStateRoot(); },
  envpin: () => process.env.WORKFLOW_STATE_DIR,
  // R7: resolve, move the legacy json into the new root, resolve again (same process).
  dirtwice: () => {
    const [sid, newRoot, legacyRoot] = args;
    const a = root().getSessionStateDir(sid);
    fs.mkdirSync(newRoot, { recursive: true });
    fs.renameSync(path.join(legacyRoot, `${sid}.json`), path.join(newRoot, `${sid}.json`));
    const b = root().getSessionStateDir(sid);
    fs.rmSync(path.join(newRoot, `${sid}.json`));
    const c = root().getSessionStateDir(sid);
    return [a, b, c].map(norm).join("|");
  },
  validate: () => [
    tryOk(() => root().getSessionStateDir(args[0])),
    tryOk(() => io("control-dir").getSessionControlDir(args[0])),
    tryOk(() => io("core").getStatePath(args[0])),
    tryOk(() => root().assertValidStateSid(args[0])),
  ].join(","),
  cdexports: () => {
    const cd = io("control-dir");
    const sr = root();
    return [cd.CONTROL_SID_RE instanceof RegExp, cd.CONTROL_SID_RE.test("a.b-1"),
      tryOk(() => cd.assertValidControlSid("a.b-1")), tryOk(() => cd.assertValidControlSid("a..b")),
      String(cd.CONTROL_SID_RE) === String(sr.CONTROL_SID_RE || sr.STATE_SID_RE)].join(",");
  },
  seed: () => seed(args[0], args[1], args[2]),
  update: () => { io("core").updateTopLevel(args[0], (s) => { s.closes_issues = [2511]; }); return "done"; },
  writestate: () => {
    const core = io("core");
    const s = core.readState(args[0]);
    if (!s) return "no-state";
    s.verbose_prompt = true;
    core.writeState(args[0], s);
    return "done";
  },
  markstep: () => { io("core").markStep(args[0], "research", "complete"); return "done"; },
  worktree: () => { io("session-fields").recordSessionWorktree(args[0], args[1]); return "done"; },
  read: () => JSON.stringify(io("core").readRawState(args[0])),
  finding: () => String(lib("lib/supervisor-state-writer/append").appendFinding(args[0],
    { categories: ["workflow"], severity: "notice", detail: args[1] || "d", reporter: "test" })),
  sesslock: () => {
    let called = false;
    const r = lib("lib/supervisor-state-writer/lock").withSessionStateLock(args[0], () => { called = true; return "ran"; });
    return `${String(r)}|called=${called}`;
  },
  markergate: () => {
    const mg = lib("enforce-worktree/bash-write-scope/marker-gate");
    const ctx = { sessionId: args[1] };
    return [mg.areAllBashTargetsUnderWorkflowDir([args[0]], { sessionCtx: ctx }),
      mg.targetsHitOtherSessionWorkflowState([args[0]], ctx)].join(",");
  },
  placement: () => lib("block-clearance-token-write/placement-guard").classifyPlacement(args[0], {}),
  scan: () => lib("block-clearance-token-write/bash-scan/scan").bashHitsProtected(args[0],
    { cwd: args[1] || process.cwd(), sessionCtx: { sessionId: "s1" } }),
  expand: () => {
    const d = lib("lib/bash-write-targets/detection-expand").expandForDetection(args[0], { cwd: process.cwd() });
    return `${norm(d.path)}|${d.aliasUnresolved}`;
  },
  zombies: () => { io("zombie-cleanup").cleanupZombies(7); return "done"; },
  active: () => [...lib("lib/active-session-ids").observeActiveSessionIds({ sessionId: args[0] }).sids].sort().join(","),
  activecomplete: () => String(lib("lib/active-session-ids").observeActiveSessionIds({ sessionId: args[0] }).complete),
  ghsave: () => JSON.stringify(lib("confirm-forge-target-ownership/gh-env-state").saveSessionGhEnv(args[0], { GH_REPO: "acme/demo" })),
  bashplacement: () => lib("block-clearance-token-write/placement-guard").classifyBashPlacement(args[0], { cwd: args[1] || process.cwd() }),
  // A directory junction (a symlink off Windows): no privilege needed on either host.
  link: () => { fs.symlinkSync(args[0], args[1], "junction"); return "linked"; },
  gateenv: () => {
    const gate = require(path.join(A, "bin", "worker-dispatch", "workers", "commit-push", "gate.js"));
    const env = gate.resolveGateEnv({ session_id: args[1], worktree_path: args[2] || A },
      { anchors: { scriptCheckoutRoot: args[0], plansDir: args[3] || path.join(args[0], "plans") } });
    return JSON.stringify(Object.fromEntries(Object.entries(env).map(([k, v]) => [k, norm(v)])));
  },
  turnmarker: () => lib("lib/turn-marker").writeTurnMarker(args[0], { probe: true }),
  isoff: () => lib("lib/session-markers").isWorkflowOff(args[0]),
  // R21: the "State file:" path inside a hook's JSON stdout (saved to a file).
  stateline: () => {
    const strs = [];
    const walk = (v) => { if (typeof v === "string") strs.push(v); else if (v && typeof v === "object") Object.values(v).forEach(walk); };
    walk(JSON.parse(fs.readFileSync(args[0], "utf8")));
    const m = strs.map((s) => /State file: (\S+\.json)/.exec(s)).find(Boolean);
    return m ? m[1] : "none";
  },
  notneeded: () => {
    lib("workflow-mark/not-needed-handlers").handle({ cmd: 'echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: probe>>"',
      sessionId: args[0], pushMessage: () => {}, signalFatal: () => {}, repoCwd: args[1] || process.cwd() });
    return "done";
  },
};

try {
  if (!MODES[mode]) throw new Error(`unknown probe mode ${mode}`);
  out(MODES[mode]());
} catch (e) {
  out(`ERR:${(e && e.name) || "Error"}:${String((e && e.message) || e).split("\n")[0]}`);
}
