// Test-only gh stub for the plan-sync-init interactive cases (plan-sync-init-interactive.sh).
// Loaded through NODE_OPTIONS=--require into every node process; it answers only when the
// running binary is a node link named gh / gh.exe, and stays inert everywhere else.
// Env inputs:
//   GH_DISPATCH_LOGIN  login returned by `gh api user` (default test-owner)
//   GH_DISPATCH_REPO   absent | private | public — state of <login>/agent-plans
//   GH_DISPATCH_AUTH   "no" -> every call fails as unauthenticated (exit 4)
//   GH_DISPATCH_CREATE "fail" -> `gh repo create` exits 1 and creates nothing
//   GH_DISPATCH_STATE  file whose existence means `gh repo create` already ran
//   GH_DISPATCH_LOG    file; one JSON array of argv per call is appended
"use strict";
const path = require("path");
const fs = require("fs");

const base = (p) => path.basename(String(p || "")).replace(/\.exe$/i, "").toLowerCase();
if (base(process.execPath) === "gh" || base(process.argv0) === "gh") {
  // node resolves the first argument as a script path; its basename is the gh subcommand.
  const args = process.argv.slice(1);
  if (args.length) args[0] = path.basename(args[0]);
  const env = process.env;
  if (env.GH_DISPATCH_LOG) fs.appendFileSync(env.GH_DISPATCH_LOG, JSON.stringify(args) + "\n");
  const out = (s) => fs.writeSync(1, s);
  const err = (s) => fs.writeSync(2, s);
  const login = env.GH_DISPATCH_LOGIN || "test-owner";
  const target = `${login}/agent-plans`;
  const created = !!(env.GH_DISPATCH_STATE && fs.existsSync(env.GH_DISPATCH_STATE));
  const state = created ? "private" : (env.GH_DISPATCH_REPO || "absent");
  const jqAt = args.indexOf("--jq");
  const jq = jqAt >= 0 ? args[jqAt + 1] : null;
  const notFound = () => { err("HTTP 404: Not Found\n"); process.exit(1); };
  const repoJson = (name) => ({
    full_name: name, nameWithOwner: name, name: "agent-plans", owner: { login },
    private: state !== "public", visibility: state, isPrivate: state !== "public",
  });

  if (env.GH_DISPATCH_AUTH === "no") {
    err("To get started with GitHub CLI, please run:  gh auth login\n");
    process.exit(4);
  }
  const [c0, c1, c2] = args;
  if (c0 === "auth" && c1 === "status") { out(`Logged in to github.com account ${login}\n`); process.exit(0); }
  if (c0 === "api" && c1 === "user") {
    out(jq ? `${login}\n` : JSON.stringify({ login }) + "\n");
    process.exit(0);
  }
  if (c0 === "api" && typeof c1 === "string" && c1.startsWith("repos/")) {
    const name = c1.slice("repos/".length);
    if (name !== target || state === "absent") notFound();
    const j = repoJson(name);
    if (jq === ".visibility") out(`${j.visibility}\n`);
    else if (jq === ".private") out(`${j.private}\n`);
    else out(JSON.stringify(j) + "\n");
    process.exit(0);
  }
  if (c0 === "repo" && c1 === "view") {
    if (c2 !== target || state === "absent") {
      err(`GraphQL: Could not resolve to a Repository with the name '${c2}'.\n`);
      process.exit(1);
    }
    const j = repoJson(c2);
    j.visibility = state.toUpperCase();
    if (jq) out(String(jq.includes("isPrivate") ? j.isPrivate : j.visibility) + "\n");
    else out(JSON.stringify(j) + "\n");
    process.exit(0);
  }
  if (c0 === "repo" && c1 === "create") {
    if (env.GH_DISPATCH_CREATE === "fail") {
      err("GraphQL: Name already exists on this account (createRepository)\n");
      process.exit(1);
    }
    if (env.GH_DISPATCH_STATE) fs.writeFileSync(env.GH_DISPATCH_STATE, "created\n");
    out(`https://github.com/${c2}\n`);
    process.exit(0);
  }
  if (c0 === "repo" && c1 === "list") {
    if (state !== "absent") out(`${state.toUpperCase()}\t${target}\n`);
    process.exit(0);
  }
  err(`gh-dispatch: unsupported call: ${JSON.stringify(args)}\n`);
  process.exit(1);
}
