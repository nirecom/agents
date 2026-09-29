"use strict";
// Tests: install/codegraph-mcp.js
// Tags: codegraph, installer, stub, cli-emulator, TL2, scope:issue-specific
// claude CLI write emulator for tests/install/feature-codegraph-bootstrap (#2254).
// The claude stub calls it only when its configured rc is 0. It reproduces what
// `claude mcp add|remove --scope user` does to ~/.claude.json, so the suite can
// judge the helper's own alwaysLoad write against a realistic baseline.
// CLAUDE_STUB_EMU picks the add behaviour; remove is the same in every mode.
const fs = require("fs");
const os = require("os");
const path = require("path");

const canonical = (obj) => JSON.stringify(obj, null, 2) + "\n";

// Entry shapers: (obj, name, entry) -> obj to serialize, or null for "write nothing".
const SHAPERS = {
  write: (obj, name, entry) => { servers(obj)[name] = entry; return obj; },
  nowrite: () => null,
  alwaysload: (obj, name, entry) => { servers(obj)[name] = Object.assign({}, entry, { alwaysLoad: true }); return obj; },
  foreign: (obj, name, entry) => { servers(obj)[name] = Object.assign({}, entry, { command: "not-codegraph" }); return obj; },
  noservers: (obj) => { delete obj.mcpServers; return obj; },
  nullservers: (obj) => { obj.mcpServers = null; return obj; },
  nullentry: (obj, name) => { servers(obj)[name] = null; return obj; },
};

// Serializers: obj -> file text. The root modes never read the existing file.
const SERIALIZERS = {
  garbage: (obj) => canonical(obj).slice(0, -4),
  noncanon: (obj) => JSON.stringify(obj, null, "\t").replace(/é/g, "\\u00e9").replace(/\n/g, "\r\n"),
  compact: (obj) => JSON.stringify(obj) + "\n",
};
const ROOT_TEXT = { rootnull: "null\n", rootarray: "[]\n", rootscalar: "42\n" };

function servers(obj) {
  if (!obj.mcpServers || typeof obj.mcpServers !== "object") obj.mcpServers = {};
  return obj.mcpServers;
}

function configPath() {
  // The same resolution install/codegraph-mcp.js uses (the harness preflight proves
  // it lands on the fixture home).
  return path.join(os.homedir(), ".claude.json");
}

function readObj(file) {
  let text;
  try { text = fs.readFileSync(file, "utf8"); } catch (e) {
    if (e.code === "ENOENT") return {};
    throw e;
  }
  const obj = JSON.parse(text);
  if (obj === null || typeof obj !== "object" || Array.isArray(obj)) throw new Error("root not an object");
  return obj;
}

// mcp add <name> [--scope user|-s user] [--env K=V|-e K=V]... -- <cmd> <args...>
function parseAdd(argv) {
  const name = argv[2];
  const env = {};
  let i = 3;
  for (; i < argv.length && argv[i] !== "--"; i++) {
    if (argv[i] === "--scope" || argv[i] === "-s") { i++; continue; }
    if (argv[i] === "--env" || argv[i] === "-e") {
      const kv = argv[++i] || "";
      const eq = kv.indexOf("=");
      if (eq > 0) env[kv.slice(0, eq)] = kv.slice(eq + 1);
    }
  }
  const rest = argv.slice(i + 1);
  const entry = { type: "stdio", command: rest[0], args: rest.slice(1), env };
  return { name, entry };
}

function writeOut(file, text) {
  fs.writeFileSync(file, text); // follows a symlink, as the real CLI does
  const snap = process.env.CLAUDE_STUB_SNAPSHOT;
  if (snap) fs.writeFileSync(snap, text);
}

function run(argv) {
  if (argv[0] !== "mcp") return;
  const file = configPath();
  if (argv[1] === "remove") {
    let obj;
    try { obj = readObj(file); } catch (e) { return; }
    if (!obj.mcpServers || typeof obj.mcpServers !== "object" || !(argv[2] in obj.mcpServers)) return;
    delete obj.mcpServers[argv[2]];
    writeOut(file, canonical(obj));
    return;
  }
  if (argv[1] !== "add") return;
  const mode = process.env.CLAUDE_STUB_EMU || "write";
  if (Object.prototype.hasOwnProperty.call(ROOT_TEXT, mode)) { writeOut(file, ROOT_TEXT[mode]); return; }
  const { name, entry } = parseAdd(argv);
  const shaper = SHAPERS[mode] || SHAPERS.write;
  const obj = shaper(readObj(file), name, entry);
  if (obj === null) return;
  const serialize = SERIALIZERS[mode] || canonical;
  writeOut(file, serialize(obj));
  if (mode === "lockdir") fs.chmodSync(path.dirname(file), 0o555);
}

module.exports = { run };

if (require.main === module) {
  try { run(process.argv.slice(2)); } catch (e) { process.exit(97); }
}
