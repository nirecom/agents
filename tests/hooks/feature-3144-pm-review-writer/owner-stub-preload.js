"use strict";
// Test-only preload for #3144: answers the PM owner lookup and the current-PR lookup from env so a test decides
// who the assigned PM is and which PR the branch has, without a forge. Child: NODE_OPTIONS --require; in process: install().
// PM3144_OWNER_STUB: JSON file {"<issue no>": ownerOf answer | {"throw": msg}, "__holders": {"<no>": [{tag, session_id}]}};
// a number not in the file answers {ok:true, owner:null}. PM3144_PR_STUB: JSON {state, number} for prForBranch.
// PM3144_OWNER_LOG / PM3144_FORGE_LOG: one JSON line per stubbed call. decidedOwnerOf keeps its real undecidable rule.
const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..", "..", "..");
let installed = false;

function readJson(p) {
  try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch (_) { return null; }
}
function log(envKey, rec) {
  const p = process.env[envKey];
  if (!p) return;
  try { fs.appendFileSync(p, JSON.stringify(rec) + "\n"); } catch (_) { /* a log is best effort */ }
}
// issueNo(ref) -> the issue number of any ref spelling (#N, repo#N, owner/repo#N, {number}).
function issueNo(ref) {
  if (ref && typeof ref === "object" && ref.number !== undefined) return String(ref.number);
  const m = /#?(\d+)\s*$/.exec(String(ref || ""));
  return m ? m[1] : String(ref);
}

function stubOwnerOf(ref) {
  const n = issueNo(ref);
  log("PM3144_OWNER_LOG", { fn: "ownerOf", n });
  const cfg = readJson(process.env.PM3144_OWNER_STUB) || {};
  const a = cfg[n];
  if (!a) return { ok: true, owner: null };
  if (a.throw) throw new Error(a.throw);
  return JSON.parse(JSON.stringify(a));
}

function stubHolders(ref) {
  const n = issueNo(ref);
  log("PM3144_OWNER_LOG", { fn: "directHoldersOf", n });
  const cfg = readJson(process.env.PM3144_OWNER_STUB) || {};
  const h = (cfg.__holders || {})[n];
  return Array.isArray(h) ? h.map((x) => Object.assign({}, x)) : [];
}

function stubPr() {
  log("PM3144_FORGE_LOG", { fn: "prForBranch" });
  let v = null;
  try { v = JSON.parse(process.env.PM3144_PR_STUB); } catch (_) { v = null; }
  return v && typeof v === "object" ? v : { state: "UNKNOWN", number: "" };
}

function install() {
  if (installed) return;
  installed = true;
  const common = require(path.join(ROOT, "bin", "lib", "pm-notify", "common.js"));
  common.ownerOf = stubOwnerOf;
  if (common.scan && typeof common.scan === "object") common.scan.directHoldersOf = stubHolders;
  try {
    require(path.join(ROOT, "hooks", "pm-session", "scan.js")).directHoldersOf = stubHolders;
  } catch (_) { /* common.scan above is the one decidedOwnerOf reads */ }
  require(path.join(ROOT, "hooks", "workflow-gate", "gh-detect.js")).prForBranch = stubPr;
}

if (process.env.PM3144_OWNER_STUB || process.env.PM3144_PR_STUB !== undefined) install();

module.exports = { install, issueNo };
