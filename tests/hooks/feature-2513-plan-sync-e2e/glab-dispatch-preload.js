// Test-only glab stub for plan-sync-init-glab.sh: answers only when the running binary is a
// node link named glab / glab.exe (NODE_OPTIONS=--require), inert in every other node process.
// Env: GLAB_DISPATCH_LOGIN (username, default test-owner); GLAB_DISPATCH_PROJECT absent|private|
// internal|public (state of <login>/agent-plans); GLAB_DISPATCH_AUTH=no (every call fails 401);
// GLAB_DISPATCH_CREATE=fail; GLAB_DISPATCH_CREATED_AS (visibility once created, default private);
// GLAB_DISPATCH_STATE (file marking that the create call ran); GLAB_DISPATCH_LOG (JSON argv per
// call); GLAB_DISPATCH_CALLS (one "<kind> <--hostname value or -> <detail>" line per call).
// `glab api` has no --jq flag: any --jq is rejected with "Unknown flag" (exit 1); output is JSON.
"use strict";
const path = require("path");
const fs = require("fs");

const base = (p) => path.basename(String(p || "")).replace(/\.exe$/i, "").toLowerCase();
if (base(process.execPath) === "glab" || base(process.argv0) === "glab") {
  // node resolves the first argument as a script path; its basename is the glab subcommand.
  const args = process.argv.slice(1);
  if (args.length) args[0] = path.basename(args[0]);
  const env = process.env;
  if (env.GLAB_DISPATCH_LOG) fs.appendFileSync(env.GLAB_DISPATCH_LOG, JSON.stringify(args) + "\n");
  const out = (s) => fs.writeSync(1, s);
  const err = (s) => fs.writeSync(2, s);

  const VALUE_FLAGS = { "--hostname": "host", "-X": "method", "--method": "method",
    "-f": "field", "--raw-field": "field", "-F": "field", "--field": "field",
    "-H": "header", "--header": "header", "--input": "input" };
  const seen = { host: "-", method: null, fields: {}, positional: [] };
  const take = (kind, value) => {
    if (kind === "field") {
      const eq = String(value).indexOf("=");
      if (eq > 0) seen.fields[value.slice(0, eq)] = value.slice(eq + 1);
    } else if (kind === "host" || kind === "method") seen[kind] = value;
  };
  const call = (kind, detail) => {
    if (env.GLAB_DISPATCH_CALLS) fs.appendFileSync(env.GLAB_DISPATCH_CALLS, `${kind} ${seen.host} ${detail}\n`);
  };
  for (let i = 1; i < args.length; i++) {
    const a = args[i];
    if (a === "--jq" || a.startsWith("--jq=")) {
      call("rejected", "--jq");
      err("Unknown flag: --jq\n");
      process.exit(1);
    }
    const eq = a.startsWith("--") ? a.indexOf("=") : -1;
    if (eq > 0 && VALUE_FLAGS[a.slice(0, eq)]) take(VALUE_FLAGS[a.slice(0, eq)], a.slice(eq + 1));
    else if (VALUE_FLAGS[a]) take(VALUE_FLAGS[a], args[++i]);
    else if (!a.startsWith("-")) seen.positional.push(a);
  }

  const login = env.GLAB_DISPATCH_LOGIN || "test-owner";
  const target = `${login}/agent-plans`;
  const created = !!(env.GLAB_DISPATCH_STATE && fs.existsSync(env.GLAB_DISPATCH_STATE));
  const state = created ? (env.GLAB_DISPATCH_CREATED_AS || "private") : (env.GLAB_DISPATCH_PROJECT || "absent");
  const unauthenticated = () => {
    out('{"message":"401 Unauthorized"}\n');
    err("glab: 401 Unauthorized (HTTP 401)\n");
    process.exit(1);
  };
  const projectJson = (visibility) => ({ id: 1, name: "agent-plans", path: "agent-plans",
    path_with_namespace: target, visibility });
  const emit = (obj) => out(JSON.stringify(obj) + "\n");

  const [c0, c1] = args;
  if (c0 === "auth" && c1 === "status") {
    call("auth", "-");
    if (env.GLAB_DISPATCH_AUTH === "no") unauthenticated();
    out(`Logged in as ${login}\n`);
    process.exit(0);
  }
  if (c0 !== "api" || seen.positional.length !== 1) {
    call("other", JSON.stringify(args));
    err(`glab-dispatch: unsupported call: ${JSON.stringify(args)}\n`);
    process.exit(1);
  }
  const endpoint = seen.positional[0].replace(/^\//, "");
  const method = (seen.method || (Object.keys(seen.fields).length ? "POST" : "GET")).toUpperCase();

  if (endpoint === "user" && method === "GET") {
    call("user", "-");
    if (env.GLAB_DISPATCH_AUTH === "no") unauthenticated();
    emit({ id: 7, username: login, name: "Test Owner" });
    process.exit(0);
  }
  if (endpoint === "projects" && method === "POST") {
    call("create", `visibility=${seen.fields.visibility || "-"} name=${seen.fields.name || seen.fields.path || "-"}`);
    if (env.GLAB_DISPATCH_AUTH === "no") unauthenticated();
    if (env.GLAB_DISPATCH_CREATE === "fail" || state !== "absent") {
      out('{"message":{"name":["has already been taken"]}}\n');
      err("glab: 400 Bad Request (HTTP 400)\n");
      process.exit(1);
    }
    if (env.GLAB_DISPATCH_STATE) fs.writeFileSync(env.GLAB_DISPATCH_STATE, "created\n");
    emit(projectJson(env.GLAB_DISPATCH_CREATED_AS || "private"));
    process.exit(0);
  }
  if (endpoint.startsWith("projects?") && method === "GET") {
    call("list", "-");
    if (env.GLAB_DISPATCH_AUTH === "no") unauthenticated();
    out(state !== "absent" ? JSON.stringify([projectJson(state)]) + "\n" : "[]\n");
    process.exit(0);
  }
  if (endpoint.startsWith("projects/") && method === "GET") {
    let name;
    try { name = decodeURIComponent(endpoint.slice("projects/".length)); } catch (e) { name = endpoint; }
    call("lookup", name);
    if (env.GLAB_DISPATCH_AUTH === "no") unauthenticated();
    if (name !== target || state === "absent") {
      out('{"message":"404 Project Not Found"}\n');
      err("glab: 404 Project Not Found (HTTP 404)\n");
      process.exit(1);
    }
    emit(projectJson(state));
    process.exit(0);
  }
  call("other", JSON.stringify(args));
  err(`glab-dispatch: unsupported call: ${JSON.stringify(args)}\n`);
  process.exit(1);
}
