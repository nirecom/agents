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
  return out;
}

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
}
if (failed) { process.stderr.write("fake gh: HTTP 502\n"); process.exit(1); }
if (Object.keys(data).length === 0) { process.stderr.write(`fake gh: cannot read the query: ${query}\n`); process.exit(1); }
process.stdout.write(`${JSON.stringify({ data })}\n`);
