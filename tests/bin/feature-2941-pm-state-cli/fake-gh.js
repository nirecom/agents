"use strict";
// Fake gh of the #2941 PM tests (pm-state-cli, forge-issue-links, pm-state-ancestry), first on PATH via a bash shim.
// Logs each call's args (plus a `--input` stdin query) as one JSON line to $PM_FAKE_GH_LOG and answers a
// batched `api graphql`: each `<alias>: issue(number:N)` under `<alias>: repository(owner:"o", name:"r")`
// gets its ancestor chain nested under `parent` (bounded at NEST, so a cycle or a too-deep chain shows a
// parent at the cap level); nodes carry number, repository.nameWithOwner, labels{nodes{name} pageInfo}.
// $PM_FAKE_GH_MAP {"o/r#N": {parent:{number,repo}|null, labels?, more?, missing?, fail?}}: absent = no
// parent, no label; missing -> null alias; fail -> the call fails. $PM_FAKE_GH_MODE fail|garbage; $PM_FAKE_GH_SLEEP_MS.
// $PM_FAKE_GH_SIDE: a one-shot {file, patch} file; the call merges patch into file's pm key, then deletes it.
const fs = require("node:fs");

// #2942 PM field: each issue node carries projectItems.nodes[0] {id: PVTI_<owner>_<repo>_<N>,
// fieldValueByName/pm: {text}|null}, from $PM_FAKE_GH_PM_STORE[id] when set, else the map entry's `pm`.
// `project item-edit --id <item> --text <v> | --clear` writes that store. $PM_FAKE_GH_EDIT_SLEEP_MS delays the
// edit before the write (a hung write), $PM_FAKE_GH_EDIT_PID_FILE gets the pid, $PM_FAKE_GH_EDIT_MODE=fail exits 1.
// Each node also carries subIssues.nodes: the map entries whose parent is that issue, nested (fetchSubIssueTree),
// and state: the map entry's `state` (OPEN|CLOSED, default OPEN) for the notifications tied to a forge state.
// A map entry's `noCard` drops the card (see noCardNow) for the card-creation path of createPmField.prepare;
// `noPmField` keeps the card but on a Project without the `pm` field (pmItems).
const NEST = 14;
const args = process.argv.slice(2);
let stdinQuery = null;
if (args.includes("--input")) {
  try { const b = JSON.parse(fs.readFileSync(0, "utf8")); stdinQuery = b && b.query; } catch (_) { stdinQuery = null; }
}
const logged = stdinQuery ? args.concat([`stdin-query=${stdinQuery}`]) : args;
try { fs.appendFileSync(process.env.PM_FAKE_GH_LOG, `${JSON.stringify(logged)}\n`); } catch (_) { /* no log */ }
const sidePath = process.env.PM_FAKE_GH_SIDE;
if (sidePath && fs.existsSync(sidePath)) {
  const side = JSON.parse(fs.readFileSync(sidePath, "utf8"));
  fs.rmSync(sidePath, { force: true });
  const st = JSON.parse(fs.readFileSync(side.file, "utf8"));
  st.pm = Object.assign({}, st.pm, side.patch);
  fs.writeFileSync(side.file, JSON.stringify(st, null, 2));
}
const sleep = Number(process.env.PM_FAKE_GH_SLEEP_MS || 0);
if (sleep > 0) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, sleep);
const storePath = process.env.PM_FAKE_GH_PM_STORE;
const readStore = () => { try { return JSON.parse(fs.readFileSync(storePath, "utf8")); } catch (_) { return {}; } };
if (args[0] === "project" && args[1] === "item-edit") {
  if (process.env.PM_FAKE_GH_EDIT_PID_FILE) fs.writeFileSync(process.env.PM_FAKE_GH_EDIT_PID_FILE, String(process.pid));
  const editSleep = Number(process.env.PM_FAKE_GH_EDIT_SLEEP_MS || 0);
  if (editSleep > 0) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, editSleep);
  if (process.env.PM_FAKE_GH_EDIT_MODE === "fail") { process.stderr.write("fake gh: item-edit HTTP 502\n"); process.exit(1); }
  const at = (flag) => { const i = args.indexOf(flag); return i >= 0 ? args[i + 1] : undefined; };
  const id = at("--id");
  if (!id || !storePath) { process.stderr.write("fake gh: item-edit needs --id and a store\n"); process.exit(1); }
  const store = readStore();
  if (args.includes("--clear")) store[id] = null;
  else if (at("--text") !== undefined) store[id] = at("--text");
  else { process.stderr.write("fake gh: item-edit needs --text or --clear\n"); process.exit(1); }
  fs.writeFileSync(storePath, JSON.stringify(store));
  process.stdout.write(`${JSON.stringify({ id })}\n`);
  process.exit(0);
}
if (args[0] !== "api" || args[1] !== "graphql") process.exit(1);
if (process.env.PM_FAKE_GH_MODE === "fail") { process.stderr.write("fake gh: HTTP 502\n"); process.exit(1); }
if (process.env.PM_FAKE_GH_MODE === "garbage") { process.stdout.write("<html>not json</html>\n"); process.exit(0); }

const qArg = args.find((a) => /^query=/.test(a));
const query = stdinQuery || (qArg ? qArg.slice("query=".length) : "");
let map = {};
try { map = JSON.parse(fs.readFileSync(process.env.PM_FAKE_GH_MAP, "utf8")); } catch (_) { /* empty map */ }

// node(repo, n, depth) -> the GraphQL issue object with its ancestors nested under parent.
function node(repo, n, depth) {
  const a = map[`${repo}#${n}`] || {};
  const labels = a.labels || [];
  const out = { number: n, repository: { nameWithOwner: repo }, labels: { nodes: labels.map((name) => ({ name })), totalCount: labels.length + (a.more ? 100 : 0), pageInfo: { hasNextPage: Boolean(a.more) } } };
  const p = a.parent;
  out.parent = p && depth < NEST ? node(p.repo || repo, p.number, depth + 1) : (p ? { number: p.number } : null);
  out.projectItems = pmItems(repo, n, a);
  out.state = a.state || "OPEN";
  out.subIssues = { nodes: depth < NEST ? childrenOf(repo, n).map((c) => child(c.repo, c.number, depth + 1)) : [], pageInfo: { hasNextPage: false } };
  return out;
}

// childrenOf(repo, n) -> the map entries whose parent is repo#n (the sub-issues of #2942 fetchSubIssueTree).
function childrenOf(repo, n) {
  return Object.keys(map).filter((k) => {
    const p = map[k].parent;
    return p && Number(p.number) === Number(n) && (p.repo || k.split("#")[0]) === repo;
  }).map((k) => ({ repo: k.split("#")[0], number: Number(k.split("#")[1]) }));
}

// child(repo, n, depth) -> a sub-issue node with its PM field and its own sub-issues (no parent chain).
function child(repo, n, depth) {
  const a = map[`${repo}#${n}`] || {};
  const kids = depth < NEST ? childrenOf(repo, n).map((c) => child(c.repo, c.number, depth + 1)) : [];
  return { number: n, state: a.state || "OPEN", repository: { nameWithOwner: repo }, labels: { nodes: (a.labels || []).map((name) => ({ name })) }, projectItems: pmItems(repo, n, a), subIssues: { nodes: kids, pageInfo: { hasNextPage: false } } };
}

// A map entry's noCard: true -> the issue has no card (projectItems.nodes []); noCard: K (a number) -> no card
// for its first K node builds, counted in "<store>.nocard.json", then the card (a card added between reads).
function noCardNow(key, a) {
  if (a.noCard === true) return true;
  if (!Number.isFinite(a.noCard) || !storePath) return false;
  const file = `${storePath}.nocard.json`;
  let seen;
  try { seen = JSON.parse(fs.readFileSync(file, "utf8")); } catch (_) { seen = {}; }
  const k = Number(seen[key] || 0);
  seen[key] = k + 1;
  fs.writeFileSync(file, JSON.stringify(seen));
  return k < a.noCard;
}

// pmItems(repo, n, entry) -> the issue's project card with the PM field value (store first, then map).
function pmItems(repo, n, a) {
  if (noCardNow(`${repo}#${n}`, a)) return { nodes: [] };
  const id = `PVTI_${repo.replace("/", "_")}_${n}`;
  const store = readStore();
  const v = Object.prototype.hasOwnProperty.call(store, id) ? store[id] : (a.pm === undefined ? null : a.pm);
  const value = v === null || v === "" ? null : { text: v };
  // The card sits on a Project with a `pm` field; noPmField: true puts it on a Project without one.
  const project = a.noPmField ? { id: "PVT_fake_other", field: null } : { id: "PVT_fake", field: { id: "PVTF_fake_pm" } };
  const items = { nodes: [{ id, fieldValueByName: value, pm: value, project }] };
  if (a.itemsMore !== undefined) items.pageInfo = { hasNextPage: Boolean(a.itemsMore) };
  return items;
}

// A map entry's innerError: "<TYPE>" nulls its card's project and adds an errors[] entry at that path
// (inside the issue node), and gh exits 1 while still printing data, as the real gh does.
const errors = [];
const data = {};
let failed = false;
let repoAlias = null;
let repo = null;
const re = /(\w+)\s*:\s*repository\s*\(\s*owner\s*:\s*"([^"]+)"\s*,\s*name\s*:\s*"([^"]+)"\s*\)|(\w+)\s*:\s*issue\s*\(\s*number\s*:\s*(\d+)\s*\)/g;
for (let m = re.exec(query); m; m = re.exec(query)) {
  if (m[1]) { repoAlias = m[1]; repo = `${m[2]}/${m[3]}`; data[repoAlias] = data[repoAlias] || {}; continue; }
  if (!repoAlias) continue;
  const n = Number(m[5]);
  const a = map[`${repo}#${n}`] || {};
  if (a.fail) failed = true;
  data[repoAlias][m[4]] = a.missing ? null : node(repo, n, 0);
  const card = a.innerError && data[repoAlias][m[4]] && data[repoAlias][m[4]].projectItems.nodes[0];
  if (card) {
    card.project = null;
    errors.push({ type: a.innerError, path: [repoAlias, m[4], "projectItems", "nodes", 0, "project"], message: "fake inner error" });
  }
}
if (failed) { process.stderr.write("fake gh: HTTP 502\n"); process.exit(1); }
if (Object.keys(data).length === 0) { process.stderr.write(`fake gh: cannot read the query: ${query}\n`); process.exit(1); }
process.stdout.write(`${JSON.stringify(errors.length > 0 ? { data, errors } : { data })}\n`);
if (errors.length > 0) process.exit(1);
