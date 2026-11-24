"use strict";
// bin/lib/review-threat-metrics/cli.js — entry of bin/review-threat-metrics (#2020). Reads the
// state and the issues; writes only the classifier caches under the plans dir (and --out).
// usage: review-threat-metrics `pre-boundary`|`post-boundary` [--json] [--seed N]
//        [--repo OWNER/REPO] [--plans-dir DIR] [--out FILE]
// Exit: 0 ok, 2 usage, 5 a source (gh, state, cache) could not be read or written.
const fs = require("node:fs");
const { preBoundary } = require("./pre-boundary-stats");
const { postBoundary } = require("./post-boundary-stats");
const { render } = require("./report");
const { readFailures } = require("./common");
const { toWindowsPath } = require("../../../hooks/lib/branch-diff");

const MODES = { "pre-boundary": preBoundary, "post-boundary": postBoundary };
const USAGE = "usage: review-threat-metrics <pre-boundary|post-boundary> [--json] [--seed N] [--repo OWNER/REPO] [--plans-dir DIR] [--out FILE]";

function parse(argv) {
  const o = { mode: argv[0], json: false, seed: 2020, repo: "{owner}/{repo}", plansDir: null, out: null };
  for (let i = 1; i < argv.length; i++) {
    const a = argv[i];
    const next = argv[i + 1] || "";
    if (a === "--json") o.json = true;
    else if (a === "--seed" && /^\d+$/.test(next)) o.seed = Number(argv[++i]);
    else if (a === "--repo" && /^[\w.-]+\/[\w.-]+$/.test(next)) o.repo = argv[++i];
    else if (a === "--plans-dir" && next) o.plansDir = toWindowsPath(argv[++i]);
    else if (a === "--out" && next) o.out = toWindowsPath(argv[++i]);
    else return null;
  }
  return Object.hasOwn(MODES, o.mode || "") ? o : null;
}

function main(argv) {
  const o = parse(argv);
  if (!o) {
    process.stderr.write(`${USAGE}\n`);
    return 2;
  }
  let text;
  try {
    if (!o.plansDir) o.plansDir = require("../../../hooks/lib/workflow-plans-dir").getWorkflowPlansDir();
    const result = MODES[o.mode](o);
    if (readFailures.length) throw new Error(`source files could not be read: ${readFailures.join("; ")}`);
    text = render(result, o.json);
    if (o.out) fs.writeFileSync(o.out, text);
  } catch (e) {
    process.stderr.write(`review-threat-metrics: ${e.message}\n`);
    return 5;
  }
  process.stdout.write(text);
  return 0;
}

process.exitCode = main(process.argv.slice(2));
