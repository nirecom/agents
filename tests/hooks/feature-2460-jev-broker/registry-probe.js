"use strict";
// tests/hooks/feature-2460-jev-broker/registry-probe.js — e-registry.sh's probe (#2460).
// node registry-probe.js <repo> <cmd> [args...]
//   exports                         -> "validateRegistry,recordingOwner" presence as true|false pairs
//   v <point> [<dotted> <json|__delete__>]...
//                                   -> accept|reject for a deep copy of REGISTRY[point] after the edits
//   defaults <point>                -> JSON of the calibration fields the spec pins
//   owner <entryJson> | owner-of <name> -> recordingOwner of that entry / of registryEntry(name)
//   entry <name>                    -> null | object (registryEntry)
//   sections                        -> JSON of STAGE_SOURCE_SECTIONS
// A module that cannot load prints MODULE_MISSING:<rel> and exits 3.
const path = require("path");
const fs = require("fs");
const [repo, cmd, ...args] = process.argv.slice(2);
function load(rel) {
  try { return require(path.join(repo, rel)); } catch (e) {
    process.stdout.write("MODULE_MISSING:" + rel); process.exit(3);
  }
}
const reg = load("hooks/lib/jev/registry.js");
const out = (s) => process.stdout.write(typeof s === "string" ? s : JSON.stringify(s));
const clone = (o) => JSON.parse(JSON.stringify(o));

// The spec fixes what validateRegistry checks, not its return shape: true / {ok:true} / []
// mean accept; false / {ok:false} / a non-empty array / a throw mean reject.
function verdict(entry) {
  let r;
  try { r = reg.validateRegistry(entry); } catch (e) { return "reject"; }
  if (r === true) return "accept";
  if (Array.isArray(r)) return r.length === 0 ? "accept" : "reject";
  if (r && typeof r === "object" && "ok" in r) return r.ok === true ? "accept" : "reject";
  if (r === false || r === null || r === undefined) return "reject";
  return "unknown:" + typeof r;
}
function setPath(obj, dotted, raw) {
  const ks = dotted.split(".");
  let o = obj;
  for (let i = 0; i < ks.length - 1; i++) {
    if (o[ks[i]] === null || typeof o[ks[i]] !== "object") o[ks[i]] = {};
    o = o[ks[i]];
  }
  const last = ks[ks.length - 1];
  if (raw === "__delete__") delete o[last];
  else if (raw === "__inf__") o[last] = Infinity;
  else if (raw === "__nan__") o[last] = NaN;
  else o[last] = JSON.parse(raw);
}

if (cmd === "exports") {
  out(["validateRegistry", "recordingOwner"].map((k) => k + "=" + (typeof reg[k] === "function")).join(","));
} else if (cmd === "v") {
  const R = reg.REGISTRY || {};
  if (!Object.prototype.hasOwnProperty.call(R, args[0])) { out("NO-ENTRY"); process.exit(0); }
  const e = clone(R[args[0]]);
  for (let i = 1; i + 1 < args.length; i += 2) setPath(e, args[i], args[i + 1]);
  out(verdict(e));
} else if (cmd === "defaults") {
  const e = reg.registryEntry(args[0]);
  if (e === null) { out("null"); process.exit(0); }
  const exists = (p) => typeof p === "string" && fs.existsSync(p);
  out({
    adapter: e.adapter ? path.basename(e.adapter) : null,
    adapter_exists: exists(e.adapter),
    target: e.target === undefined ? "<absent>" : e.target,
    normalizer: e.normalizer ? path.basename(e.normalizer) : "<absent>",
    threshold: e.confidence_threshold_by_answer,
    short_circuit_answer: "short_circuit_answer" in e ? e.short_circuit_answer : "<absent>",
    backup_subagent: e.backup_subagent,
    subagent_type: e.subagent_type === undefined ? "<absent>" : e.subagent_type,
    fallback: e.fallback,
    stages: e.stages,
    required: e.required_sections_by_stage,
    retired: ["confidence_threshold", "required_sections", "sampling_rate"].filter((k) => k in e),
  });
} else if (cmd === "mode") {
  const e = reg.registryEntry(args[0]);
  out(e === null ? "null" : String(e.mode));
} else if (cmd === "owner") {
  try { out(String(reg.recordingOwner(JSON.parse(args[0])))); } catch (e) { out("THREW"); }
} else if (cmd === "owner-of") {
  const e = reg.registryEntry(args[0]);
  try { out(e === null ? "null" : String(reg.recordingOwner(e))); } catch (_e) { out("THREW"); }
} else if (cmd === "entry") {
  out(reg.registryEntry(JSON.parse(args[0])) === null ? "null" : "object");
} else if (cmd === "sections") {
  const c = load("bin/workflow/lib/jev-request-common.js");
  out(c.STAGE_SOURCE_SECTIONS === undefined ? "absent" : c.STAGE_SOURCE_SECTIONS);
}
