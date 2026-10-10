"use strict";
// tests/bin/feature-2561-worker-child-roots/check-records.js
// Judges the JSONL written by tests/fixtures/spawn-record-preload.js against the roots of the
// fixture. Prints one line per check: ok<TAB>name  or  ng<TAB>name<TAB>detail. Always exits 0.
// Options (each takes one value): --label --records --agents-main --checkout --target-main
//   --target-linked --launcher --retired <csv> [--report <stage-one json>] [--scripts <csv rel>]
//   [--family-scripts <csv rel>] [--gate-marker <v>] [--state-dir <dir>] [--held-git-verb <verb>]
//   [--agents-main-key absent]

const fs = require("fs");
const path = require("path");

const opt = {};
const argv = process.argv.slice(2);
for (let i = 0; i + 1 < argv.length; i += 2) opt[argv[i].replace(/^--/, "")] = argv[i + 1];

const out = [];
const flat = (v) => String(v).replace(/\s+/g, " ").slice(0, 400);
const check = (name, cond, detail) =>
  out.push(cond ? `ok\t${opt.label}/${name}` : `ng\t${opt.label}/${name}\t${flat(detail === undefined ? "" : detail)}`);
const finish = () => {
  process.stdout.write(`${out.join("\n")}\n`);
  process.exit(0);
};
const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
const csv = (v) => String(v || "").split(",").filter((s) => s !== "");

// Real path of the deepest existing ancestor, forward slashes, lower case.
function canon(p) {
  if (typeof p !== "string" || p === "") return "";
  let cur = path.resolve(p);
  const tail = [];
  for (let i = 0; i < 64; i += 1) {
    try {
      cur = fs.realpathSync(cur);
      break;
    } catch (_e) {
      const parent = path.dirname(cur);
      if (parent === cur) break;
      tail.unshift(path.basename(cur));
      cur = parent;
    }
  }
  return path.join(cur, ...tail).replace(/\\/g, "/").replace(/\/+$/, "").toLowerCase();
}
const looksAbsolute = (s) => typeof s === "string" && (/^[A-Za-z]:[\\/]/.test(s) || s.startsWith("/"));
const inside = (child, parent) => child === parent || child.startsWith(`${parent}/`);

const roots = {
  agentsMain: canon(opt["agents-main"]),
  checkout: canon(opt.checkout),
  targetMain: canon(opt["target-main"]),
  targetLinked: canon(opt["target-linked"]),
  launcher: canon(opt.launcher),
};
const retired = csv(opt.retired);
check("setup:every-root-and-the-retired-names-are-known", Object.values(roots).every((r) => r !== "") && retired.length > 0, JSON.stringify(roots));

let records = [];
try {
  records = fs
    .readFileSync(opt.records, "utf8")
    .split("\n")
    .filter((l) => l.trim() !== "")
    .map((l) => JSON.parse(l));
} catch (e) {
  check("setup:records-readable", false, e.message);
  finish();
}
const started = records.filter((r) => r.envExplicit === true);
check("setup:the-dispatcher-started-at-least-one-child", started.length > 0, `${records.length} record(s), none with an explicit env`);

const describe = (r) => `${r.tag || path.basename(r.command)} ${r.args.slice(0, 2).join(" ")}`;
const offenders = (list, bad) => {
  const hit = list.filter(bad);
  return { n: hit.length, text: `${hit.length} of ${list.length}: ${hit.slice(0, 3).map(describe).join(" | ")}` };
};
const rootOf = (r) => (has(r.env, "AGENTS_MAIN_ROOT") ? canon(r.env.AGENTS_MAIN_ROOT) : null);

// --- child environment ------------------------------------------------------------------
// --agents-main-key absent: no agents main worktree can be proven, so the key must be missing.
let o = null;
if (opt["agents-main-key"] === "absent") {
  o = offenders(started, (r) => has(r.env, "AGENTS_MAIN_ROOT"));
  check("env:AGENTS_MAIN_ROOT-is-absent", started.length > 0 && o.n === 0, `${o.text} — first value: ${started.length ? started[0].env.AGENTS_MAIN_ROOT : ""}`);
} else {
  o = offenders(started, (r) => rootOf(r) !== roots.agentsMain);
  check("env:AGENTS_MAIN_ROOT-is-the-agents-main-worktree", started.length > 0 && o.n === 0, `${o.text} — first value: ${started.length ? started[0].env.AGENTS_MAIN_ROOT : ""}`);
}
// A dispatcher launched from a main worktree is its own agents main worktree: not a wrong root.
const wrongRoots = [roots.launcher, roots.checkout, roots.targetMain, roots.targetLinked].filter((w) => w !== roots.agentsMain);
o = offenders(started, (r) => rootOf(r) !== null && wrongRoots.some((w) => inside(rootOf(r), w)));
check("env:AGENTS_MAIN_ROOT-is-not-another-root", o.n === 0, o.text);
o = offenders(started, (r) => ["SCRIPT_CHECKOUT_ROOT", "TARGET_MAIN_ROOT", "TARGET_CHECKOUT_ROOT"].some((k) => has(r.env, k)));
check("env:no-other-root-name-is-handed-down", o.n === 0, o.text);
o = offenders(started, (r) => retired.some((k) => has(r.env, k)));
check("env:no-retired-name-is-handed-down", o.n === 0, o.text);
const flatValue = (v) => String(v).replace(/\\/g, "/").toLowerCase();
// A value may spell the launcher root another way (a `..` detour, a link), alone or in a list.
const namesLauncher = (v) =>
  flatValue(v).includes(roots.launcher) ||
  String(v).split(path.delimiter).some((p) => looksAbsolute(p) && inside(canon(p), roots.launcher));
o = offenders(started, (r) => Object.keys(r.env).some((k) => namesLauncher(r.env[k])));
check("env:nothing-from-the-launcher-environment-roots", o.n === 0, o.text);

// --- where the children run and what they are -----------------------------------------------
// Only worker-started children are held to the target repository: the dispatcher's own anchor
// probe asks git about its script checkout, by design, and carries no explicit environment.
const inTarget = (p) => inside(p, roots.targetMain) || inside(p, roots.targetLinked);
o = offenders(started, (r) => typeof r.cwd !== "string" || !inTarget(canon(r.cwd)));
check("path:every-child-works-inside-the-target-repository", started.length > 0 && o.n === 0, o.text);
const dashC = (r) => r.args.filter((a, i) => i > 0 && r.args[i - 1] === "-C");
o = offenders(started, (r) => /(^|[\\/])git(\.exe)?$/i.test(r.command) && dashC(r).some((p) => !inTarget(canon(p))));
check("path:every-git-dash-C-names-the-target-repository", o.n === 0, o.text);
const strays = [roots.agentsMain, roots.launcher].filter((s) => s !== roots.checkout);
o = offenders(records, (r) => [r.command].concat(r.args).some((a) => looksAbsolute(a) && strays.some((s) => inside(canon(a), s))));
check("path:no-command-or-argument-points-into-an-agents-main-tree", o.n === 0, o.text);
const firstArgs = started.map((r) => (r.args.length ? canon(r.args[0]) : ""));
for (const rel of csv(opt.scripts)) {
  check(`path:${rel}-is-launched-from-the-dispatcher-checkout`, firstArgs.includes(canon(path.join(opt.checkout, rel))), "no such child was started");
}
for (const rel of csv(opt["family-scripts"])) {
  check(`path:${rel}-is-launched-from-the-target-worktree`, firstArgs.includes(canon(path.join(opt["target-linked"], rel))), "no such child was started");
}

// --- commit-push gate child ---------------------------------------------------------------
if (opt["gate-marker"] !== undefined) {
  const gates = started.filter((r) => r.args.length > 0 && canon(r.args[0]).endsWith("/hooks/workflow-gate.js"));
  check("gate:asked-before-the-commit-and-before-the-push", gates.length === 2, `${gates.length} gate child(ren)`);
  o = offenders(gates, (r) => r.env.DEFAULT_BRANCHES !== opt["gate-marker"]);
  check("gate:DEFAULT_BRANCHES-comes-from-the-dispatcher-checkout-env-file", gates.length > 0 && o.n === 0, `${o.text} — got ${gates.length ? gates[0].env.DEFAULT_BRANCHES : ""}`);
  o = offenders(gates, (r) => canon(r.env.WORKFLOW_STATE_DIR) !== canon(opt["state-dir"]));
  check("gate:WORKFLOW_STATE_DIR-comes-from-the-dispatcher-checkout-env-file", gates.length > 0 && o.n === 0, o.text);
}
if (opt["held-git-verb"] !== undefined) {
  const verbRecords = records.filter((r) => /(^|[\\/])git(\.exe)?$/i.test(r.command) && r.args.includes(opt["held-git-verb"]));
  check(`held:git-${opt["held-git-verb"]}-was-reached`, verbRecords.length > 0, "no such call recorded");
  check(`held:git-${opt["held-git-verb"]}-was-never-run`, verbRecords.every((r) => r.held === true), "a call was run for real");
}

// --- stage one: every declaration of every worker -------------------------------------------
if (opt.report !== undefined) {
  let report = null;
  try {
    report = JSON.parse(fs.readFileSync(opt.report, "utf8"));
  } catch (e) {
    check("count:stage-one-report-readable", false, e.message);
    finish();
  }
  check("count:dispatcher-modules-load-and-anchors-resolve", report.error === null && report.anchorsError === null, report.error || report.anchorsError);
  check("setup:the-agents-main-worktree-was-resolved-before-record-only", report.agentsMainRootResolved === true,
    `agentsMainRootResolved=${report.agentsMainRootResolved}`);
  const declared = report.declared;
  const scripts = declared.filter((d) => d.kind === "script");
  const threw = declared.filter((d) => d.threw !== null);
  check("count:no-declared-child-is-refused", threw.length === 0, threw.slice(0, 3).map((d) => `${d.worker}/${d.name}: ${d.threw}`).join(" | "));
  check("count:nine-workers-seventeen-scripts-twenty-commands",
    report.workerCount === 9 && scripts.length === 17 && declared.length - scripts.length === 20,
    `workers=${report.workerCount} scripts=${scripts.length} commands=${declared.length - scripts.length}`);
  const tagOf = (d) => `${d.worker}|${d.kind}|${d.name}`;
  const unmatched = declared.filter((d) => started.filter((r) => r.tag === tagOf(d)).length !== 1);
  check("count:one-record-per-declaration", declared.length > 0 && started.length === declared.length && unmatched.length === 0,
    `declared=${declared.length} started=${started.length} unmatched=${unmatched.slice(0, 3).map(tagOf).join(",")}`);
  const badAnchor = scripts.filter((d) => d.anchor !== "script-checkout-root" && d.anchor !== "family-worktree");
  check("path:every-non-family-script-is-anchored-script-checkout-root", scripts.length > 0 && badAnchor.length === 0,
    `${badAnchor.length} of ${scripts.length}: ${badAnchor.slice(0, 3).map((d) => `${d.worker}/${d.name}=${d.anchor}`).join(" | ")}`);
  const family = scripts.filter((d) => d.anchor === "family-worktree");
  check("path:only-the-test-runner-suite-is-anchored-family-worktree", family.length === 1 && family[0].worker === "test-runner", family.map(tagOf).join(","));
  const misplaced = scripts.filter((d) => {
    const rec = started.find((r) => r.tag === tagOf(d));
    const base = d.anchor === "family-worktree" ? opt["target-linked"] : opt.checkout;
    return !rec || rec.args.length === 0 || canon(rec.args[0]) !== canon(path.join(base, d.rel));
  });
  check("path:each-script-resolves-under-its-own-root", scripts.length > 0 && misplaced.length === 0,
    `${misplaced.length} of ${scripts.length}: ${misplaced.slice(0, 3).map(tagOf).join(" | ")}`);
}
finish();
