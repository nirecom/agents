"use strict";
// #3135 board mode of fake-gh.js. With $PM_FAKE_GH_BOARD (a JSON file {fields:[{id, name, dataType, options?}]})
// the fake answers the Projects v2 board calls of ensure-project-ready.sh and of the tracker judge: auth status,
// the repository's linked boards (#3142: board #1 open and linked; no title is matched), project view, the repo
// node id, the repo link, a field list (any `fields(` query without an `issue(`), createProjectV2Field /
// updateProjectV2Field (they rewrite the file), the view list (none) and viewer.
// --jq runs through the jq on PATH, compact as gh prints it. $PM_FAKE_GH_BOARD_FAIL=create fails every createProjectV2Field.
// A board file without a `pm` field also puts every issue's card on a board without it (fake-gh.js pmItems).
const cp = require("node:child_process");
const fs = require("node:fs");

const boardOf = () => {
  const f = process.env.PM_FAKE_GH_BOARD;
  if (!f) return null;
  try { return JSON.parse(fs.readFileSync(f, "utf8")); } catch (_) { return null; }
};
const save = (b) => fs.writeFileSync(process.env.PM_FAKE_GH_BOARD, JSON.stringify(b));
const flag = (args, name) => {
  for (let i = 0; i < args.length - 1; i++) {
    if (["-f", "-F", "--raw-field", "--field"].includes(args[i]) && args[i + 1].startsWith(`${name}=`)) return args[i + 1].slice(name.length + 1);
  }
  return undefined;
};

// out(args, body) prints body (through `jq -r <expr>` when --jq is given) and exits 0.
function out(args, body) {
  let text = JSON.stringify(body);
  const i = args.indexOf("--jq");
  if (i >= 0) {
    const r = cp.spawnSync("jq", ["-rc", args[i + 1]], { input: text, encoding: "utf8", windowsHide: true });
    if (r.status !== 0) { process.stderr.write(`fake gh: jq failed: ${r.stderr}`); process.exit(1); }
    process.stdout.write(r.stdout);
  } else process.stdout.write(`${text}\n`);
  process.exit(0);
}

const nodeOf = (f) => Object.assign({ __typename: f.dataType === "SINGLE_SELECT" ? "ProjectV2SingleSelectField" : "ProjectV2Field", id: f.id, name: f.name, dataType: f.dataType },
  f.dataType === "SINGLE_SELECT" ? { options: f.options || [] } : {});

function create(args, query, b) {
  if (process.env.PM_FAKE_GH_BOARD_FAIL === "create") { process.stderr.write("fake gh: createProjectV2Field HTTP 502\n"); process.exit(1); }
  const m = /name:\s*"([^"]+)"/.exec(query);
  const name = m ? m[1] : flag(args, "name");
  const dataType = (/dataType:\s*(\w+)/.exec(query) || [])[1] || "TEXT";
  const f = { id: `PVTF_${String(name).replace(/\W/g, "_")}`, name, dataType };
  if (dataType === "SINGLE_SELECT") f.options = [];
  b.fields = (b.fields || []).concat([f]);
  save(b);
  out(args, { data: { createProjectV2Field: { projectV2Field: { id: f.id, name } } } });
}

function update(args, b) {
  let opts = [];
  try { opts = JSON.parse(flag(args, "opts") || "[]"); } catch (_) { opts = []; }
  const f = (b.fields || []).find((x) => x.id === flag(args, "fieldId"));
  if (!f) { process.stderr.write("fake gh: updateProjectV2Field: no such field\n"); process.exit(1); }
  f.options = opts.map((o) => ({ id: `OPT_${String(o.name).replace(/\W/g, "_")}`, name: o.name }));
  save(b);
  out(args, { data: { updateProjectV2Field: { projectV2Field: { id: f.id, options: f.options } } } });
}

// handle(args, query) answers a board call and exits; it returns only when the call is not one (or no board is set).
function handle(args, query) {
  const b = boardOf();
  if (!b) return;
  if (args[0] === "auth" && args[1] === "status") { process.stdout.write("Token scopes: 'gist', 'project', 'repo'\n"); process.exit(0); }
  if (args[0] === "project" && args[1] === "view") out(args, { id: "PVT_fake", number: 1 });
  if (args[0] === "api" && /^repos\//.test(args[1] || "")) out(args, { node_id: "R_fake" });
  if (args[0] !== "api" || args[1] !== "graphql") return;
  if (/\bprojectsV2\s*\(/.test(query)) {
    const login = flag(args, "owner") || "o";
    out(args, { data: { repository: { projectsV2: { nodes: [{ id: "PVT_fake", number: 1, closed: false, owner: { login } }], pageInfo: { hasNextPage: false, endCursor: null } } } } });
  }
  if (/createProjectV2Field\b/.test(query)) create(args, query, b);
  if (/updateProjectV2Field\b/.test(query)) update(args, b);
  if (/linkProjectV2ToRepository\b/.test(query)) out(args, { data: { linkProjectV2ToRepository: { repository: { id: "R_fake" } } } });
  if (/\bviews\s*\(/.test(query)) out(args, { data: { node: { views: { nodes: [], pageInfo: { hasNextPage: false, endCursor: null } } } } });
  if (/\bfields\s*\(/.test(query) && !/\bissue\s*\(/.test(query)) {
    out(args, { data: { node: { fields: { nodes: (b.fields || []).map(nodeOf), pageInfo: { hasNextPage: false, endCursor: null } } } } });
  }
  if (/\bviewer\b/.test(query)) out(args, { data: { viewer: { id: "U_fake" } } });
}

// pmFieldOf() -> undefined (no board mode), null (the board has no `pm` field) or the pm field's id.
function pmFieldOf() {
  const b = boardOf();
  if (!b) return undefined;
  const f = (b.fields || []).find((x) => x.name === "pm");
  return f ? f.id : null;
}

module.exports = { handle, pmFieldOf };
