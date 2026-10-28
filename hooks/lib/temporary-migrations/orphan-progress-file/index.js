"use strict";
// Temporary (#2748): deleted with this folder per the deletion-condition in bin/migrate-orphan-progress-files.
// run(argv, hooks) folds every orphan progress file of a session chain into the first generation's
// progress file, renames own-name plans to the first_session_id names, re-points approval records
// and sidecar pins, then deletes the orphans. Every write is checked against what step 0 read.
// hooks (tests): beforeCommit({ firstSid, firstPath }), beforeRename(), beforeDelete().

const fs = require("fs");
const path = require("path");
const { SESSION_ID_VALID_RE } = require("../../../workflow-state/state-io/core");
const { getPlansArtifactPath } = require("../../plans-artifact-registry");
const { renderTemplate } = require("../../progress-file");
const { buildMerged, existingPlanLines } = require("./merge");
const { renamePlans, repointApprovals, repin } = require("./rename");
const { STAGES, discover, isFile } = require("./discover");

const USAGE = "usage: migrate-orphan-progress-files [--apply] [--include-active] [--session <sid>]";

class UsageError extends Error {}

function parseArgs(argv) {
  const o = { apply: false, includeActive: false, session: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--apply") o.apply = true;
    else if (a === "--include-active") o.includeActive = true;
    else if (a === "--session") {
      const v = argv[++i];
      if (typeof v !== "string" || !SESSION_ID_VALID_RE.test(v)) throw new UsageError("--session needs a valid session id");
      o.session = v;
    } else throw new UsageError(`unknown argument: ${a}`);
  }
  return o;
}

function snap(file) {
  try {
    const st = fs.lstatSync(file);
    return st.isFile() ? { mtimeMs: st.mtimeMs, size: st.size } : null;
  } catch (_) {
    return null;
  }
}
const sameSnap = (a, b) => !!a && !!b && a.mtimeMs === b.mtimeMs && a.size === b.size;

// Step 0: everything the writes depend on, read before the first write.
function readChain(chain, plansDir) {
  const firstPath = getPlansArtifactPath(chain.firstSid, "progress");
  const firstSnap = snap(firstPath);
  const base = firstSnap ? fs.readFileSync(firstPath, "utf8") : null;
  const renames = [];
  for (const d of chain.downstreams) {
    for (const stage of STAGES) {
      const from = getPlansArtifactPath(d.sid, stage);
      if (isFile(from)) renames.push({ from, to: getPlansArtifactPath(chain.firstSid, stage) });
    }
  }
  // A Plan files line is re-pointed only at a first_session_id plan that exists after the renames.
  const willExist = (stage) => {
    const to = getPlansArtifactPath(chain.firstSid, stage);
    return isFile(to) || renames.some((r) => r.to === to);
  };
  const orphans = [];
  for (const d of chain.downstreams) {
    const s = snap(d.orphan);
    if (!s) continue;
    const text = fs.readFileSync(d.orphan, "utf8");
    orphans.push({ sid: d.sid, path: d.orphan, snap: s, text, stages: existingPlanLines(text, plansDir).filter(willExist) });
  }
  let currentState = null;
  let newest = firstSnap ? firstSnap.mtimeMs : -Infinity;
  for (const o of orphans) {
    if (o.snap.mtimeMs > newest) {
      newest = o.snap.mtimeMs;
      currentState = o.text;
    }
  }
  return { firstPath, firstSnap, base, orphans, currentState, renames };
}

function commitFirst(firstPath, firstSnap, text) {
  fs.mkdirSync(path.dirname(firstPath), { recursive: true });
  const tmp = `${firstPath}.${process.pid}.${Date.now()}.migrating.tmp`;
  fs.writeFileSync(tmp, text, { flag: "wx" });
  try {
    if (firstSnap === null) {
      try {
        fs.linkSync(tmp, firstPath);
      } catch (e) {
        if (e && e.code === "EEXIST") throw new Error("the first generation's progress file appeared during the migration", { cause: e });
        fs.writeFileSync(firstPath, text, { flag: "wx" });
      }
    } else {
      if (!sameSnap(snap(firstPath), firstSnap)) throw new Error("the first generation's progress file changed during the migration");
      fs.renameSync(tmp, firstPath);
    }
  } finally {
    try { fs.unlinkSync(tmp); } catch (_) { /* renamed away */ }
  }
}

function applyChain(chain, plansDir, hooks) {
  const h = hooks || {};
  const r = readChain(chain, plansDir);
  if (r.orphans.length > 0) {
    const base = r.base === null ? renderTemplate(chain.firstSid) : r.base;
    const merged = buildMerged({
      base,
      orphans: r.orphans,
      currentState: r.currentState,
      planPathFor: (stage) => getPlansArtifactPath(chain.firstSid, stage),
    });
    if (r.base === null || merged !== r.base) {
      if (typeof h.beforeCommit === "function") h.beforeCommit({ firstSid: chain.firstSid, firstPath: r.firstPath });
      commitFirst(r.firstPath, r.firstSnap, merged);
    }
  }
  if (typeof h.beforeRename === "function") h.beforeRename();
  renamePlans(r.renames);
  const sids = new Set([chain.firstSid, ...chain.downstreams.map((d) => d.sid)]);
  const states = [chain.firstSid, ...chain.downstreams.map((d) => d.sid)]
    .filter((sid) => chain.states.has(sid)).map((sid) => [sid, chain.states.get(sid)]);
  repointApprovals(states, sids, chain.firstSid);
  const unpinned = repin(chain.downstreams.map((d) => d.sid), chain.firstSid);
  if (unpinned.length) throw new Error(`could not re-pin the sidecar of ${unpinned.join(", ")}`);
  if (typeof h.beforeDelete === "function") h.beforeDelete();
  const kept = [];
  for (const o of r.orphans) {
    if (sameSnap(snap(o.path), o.snap)) fs.unlinkSync(o.path);
    else kept.push(o.sid);
  }
  if (kept.length) throw new Error(`orphan progress file of ${kept.join(", ")} changed after the merge; kept for a re-run`);
}

const out = (s) => process.stdout.write(`${s}\n`);
const err = (s) => process.stderr.write(`migrate-orphan-progress-files: ${s}\n`);

function run(argv, hooks) {
  let opts;
  try {
    opts = parseArgs(argv || []);
  } catch (e) {
    if (!(e instanceof UsageError)) throw e;
    err(`${e.message}\n${USAGE}`);
    return { exitCode: 2 };
  }
  let found;
  try {
    found = discover({ session: opts.session });
  } catch (e) {
    err(`cannot list the session chains: ${(e && e.message) || e}`);
    return { exitCode: 1 };
  }
  let exitCode = 0;
  for (const chain of found.chains) {
    const status = !chain.work ? "clean" : chain.active && !opts.includeActive ? "skip-active" : "merge";
    for (const d of chain.downstreams) out(`${chain.firstSid} <- ${d.sid} (${status})`);
    if (!opts.apply || status !== "merge") continue;
    try {
      applyChain(chain, found.plansDir, hooks);
    } catch (e) {
      exitCode = 1;
      err(`${chain.firstSid}: ${(e && e.message) || e}`);
    }
  }
  for (const sid of found.unknown) out(`? <- ${sid} (unknown)`);
  // A state that cannot be read may hide a session chain, so the run is not a success.
  for (const sid of found.unreadable) {
    exitCode = 1;
    err(`${sid}: cannot read the state; its session chain was not migrated`);
  }
  return { exitCode };
}

module.exports = { run, parseArgs };
