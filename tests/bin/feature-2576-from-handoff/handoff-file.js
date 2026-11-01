"use strict";
// Non-regular handoff.md cases of feature-2576-from-handoff.js: a directory or a symlink named
// handoff.md is no handoff.

const path = require("path");
const fs = require("fs");
const { SCRATCH, mod, fx, STATE_DIR, CLI, totals, check, show, eq, slash, spawnNode, parseOut } = require("./common");

function directoryIsNotAHandoff() {
  const view = mod("bin/lib/resume-session/upstream-view");
  const sid = "f2576-c2-handoff-dir";
  const dirAsHandoff = fx.legacyHandoffPath(sid);
  fs.mkdirSync(dirAsHandoff, { recursive: true });
  check("D0: fixture anchor — handoff.md is a directory and no state file exists", () => {
    eq(fs.statSync(dirAsHandoff).isDirectory(), true, "handoff.md is a directory");
    eq(fs.existsSync(path.join(STATE_DIR, `${sid}.json`)), false, "state file exists");
  });
  check("D1: the state handoff reader returns no entry for a directory named handoff.md", () => {
    eq(mod("hooks/lib/state-handoff-record").readStateHandoff(sid).entries, [], "entries");
  });
  check("D3: buildUpstreamView does not report the directory as a handoff", () => {
    const v = view.buildUpstreamView({ heirSid: null, upstreamSid: sid });
    eq(v.availability, "none", "availability");
    eq(v.handoff_rendered, null, "handoff_rendered");
  });
}

// A handoff.md symlink would let the control dir disclose any file it points at, so only
// a regular file (lstat) counts. The regular-file positive control is T23f.
// Returns the skip reason when the platform refuses to create the symlink, else null.
function symlinkIsNotAHandoff() {
  const view = mod("bin/lib/resume-session/upstream-view");
  const sid = "f2576-s-handoff-symlink";
  const marker = "F2576-S-SYMLINK-TARGET-MARKER";
  const target = path.join(SCRATCH, "outside-control", "secret.md");
  const link = fx.legacyHandoffPath(sid);
  // The target is a well-formed legacy handoff.md, so following the link WOULD render the marker.
  const donorSid = "f2576-s-symlink-target-src";
  const donorFile = fx.writeLegacyHandoff(donorSid, [{ cls: "A", at: fx.isoAt(1), step: "-", key: "s-symlink", summary: marker }]);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, fs.readFileSync(donorFile, "utf8"));
  fs.rmSync(path.dirname(donorFile), { recursive: true, force: true });
  fs.mkdirSync(path.dirname(link), { recursive: true });
  try {
    fs.symlinkSync(target, link, "file");
  } catch (e) {
    if (!e || (e.code !== "EPERM" && e.code !== "EACCES")) throw e;
    totals.skipped += 4;
    const reason = `S0-S3 handoff-symlink cases — symlink creation refused (${e.code}); enable Windows developer mode to run them`;
    process.stdout.write(`SKIP: ${reason}\n`);
    process.stderr.write(`SKIP: ${reason}\n`);
    return reason;
  }
  check("S0: fixture anchor — handoff.md is a symlink to a well-formed handoff outside the control dir carrying the marker", () => {
    eq(fs.lstatSync(link).isSymbolicLink(), true, "handoff.md is a symlink");
    eq(fs.existsSync(path.dirname(donorFile)), false, "scratch donor control dir removed");
    eq(fs.readFileSync(link, "utf8").indexOf(marker) !== -1, true, "marker readable through the link");
    eq(slash(path.relative(path.dirname(link), target)).startsWith(".."), true, "target is outside the control dir");
    eq(fs.existsSync(path.join(STATE_DIR, `${sid}.json`)), false, "state file exists");
  });
  check("S1: the state handoff reader does not follow a symlinked handoff.md", () => {
    const out = mod("hooks/lib/state-handoff-record").readStateHandoff(sid);
    eq(out.entries, [], "entries");
    eq(JSON.stringify(out).indexOf(marker) === -1, true, "target marker absent");
  });
  check("S2: buildUpstreamView reports no handoff and discloses nothing of the link target", () => {
    const v = view.buildUpstreamView({ heirSid: null, upstreamSid: sid });
    eq(JSON.stringify(v).indexOf(marker) === -1, true, "target marker absent from the view");
    eq(v.availability, "none", "availability");
    eq(v.handoff_rendered == null, true, "handoff_rendered is null (" + show(v.handoff_rendered) + ")");
  });
  check("S3: --from on the real CLI reports no handoff and discloses neither the marker nor the target path", () => {
    const run = spawnNode([CLI, "--from", sid]);
    const d = parseOut(run);
    const out = (run.stdout || "") + (run.stderr || "");
    const flat = slash(out).replace(/\/\//g, "/");
    if (out.indexOf(marker) !== -1) return "target marker disclosed by the CLI";
    for (const p of [target, fs.realpathSync(target)]) {
      if (out.indexOf(p) !== -1 || flat.indexOf(slash(p)) !== -1) return "target path disclosed by the CLI: " + p;
    }
    eq(d.handoff_rendered == null, true, "handoff_rendered is null (" + show(d.handoff_rendered) + ")");
    return undefined;
  });
  return null;
}

module.exports = { directoryIsNotAHandoff, symlinkIsNotAHandoff };
