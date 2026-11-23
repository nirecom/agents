"use strict";
// The local active PMs that hold issues of one repo (#3135): the tracker judge's unbackfilled check and the
// backfill both read this one listing, so they agree on which issue has which local holder.
//   holdersOf(repo, {entries?, homeRepo?}) -> {"<repo>#N": [tag, ...]} (current generation, not archived)
//   refsOf(holders, repo) -> [{repo, number}] in key order

const path = require("path");
const HOOKS = path.join(__dirname, "..", "..", "..", "hooks");
const scan = require(path.join(HOOKS, "pm-session", "scan"));
const S = require(path.join(HOOKS, "pm-session", "schema"));
const { resolveOwnerRepoFromOrigin } = require("../forge-issue-links");

// A stored issue without a repo belongs to the home repo of the checkout that recorded it (the cwd's origin).
function defaultHome() {
  try { const r = resolveOwnerRepoFromOrigin(); return r && r.ok ? r.ownerRepo : ""; } catch { return ""; }
}

function holdersOf(repo, opts) {
  const o = opts || {};
  const want = String(repo).toLowerCase();
  const pms = scan.listActivePms(o.entries || scan.listPmFiles());
  let home = typeof o.homeRepo === "string" ? o.homeRepo : null;
  const out = {};
  for (const p of pms) {
    for (const i of p.issues) {
      if (!i || typeof i !== "object" || !Number.isInteger(Number(i.number))) continue;
      if (!i.repo && home === null) home = defaultHome();
      if (String(S.resolveRepo(i, home || "")).toLowerCase() !== want) continue;
      const key = `${repo}#${Number(i.number)}`;
      const tags = out[key] || (out[key] = []);
      if (!tags.some((t) => S.sameTag(t, p.tag))) tags.push(p.tag);
    }
  }
  return out;
}

const refsOf = (holders, repo) => Object.keys(holders).map((k) => ({ repo, number: Number(k.slice(k.lastIndexOf("#") + 1)) }));

module.exports = { holdersOf, refsOf };
