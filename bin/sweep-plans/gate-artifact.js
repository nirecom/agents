#!/usr/bin/env node
// bin/sweep-plans/gate-artifact.js — the approval gate artifact of sweep-plans.
//   write <path> <plans-dir>          stdin rows "token\tnewest_epoch\tbasename:epoch,..." -> artifact; prints the gate id
//   verify <path> <id> <plans-dir>    exit 0 + rows on stdout when the artifact exists, carries <id>, was written
//                                     for the same <plans-dir>, and is untampered; else exit 3
// Gate id = first 32 hex chars of sha256(nonce + plans-dir + rows); plans-dir is normalized by plansDirForm.
// Layout: docs/architecture/claude-code/state-dirs.md (Control files).
"use strict";

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const ID_RE = /^[0-9a-f]{32}$/;

// One canonical spelling per directory: the MSYS drive form, forward-slash and backslash
// drive paths all become the forward-slash drive form on Windows.
function plansDirForm(dir) {
  let d = String(dir || "");
  if (d === "" || /[\r\n]/.test(d)) return null;
  if (process.platform !== "win32") return path.posix.resolve(d);
  const msys = /^\/([A-Za-z])(\/|$)(.*)$/.exec(d);
  if (msys) d = `${msys[1]}:/${msys[3]}`;
  return path.win32.resolve(d).replace(/\\/g, "/").replace(/^([a-z]):/, (_, c) => `${c.toUpperCase()}:`);
}

function gateId(nonce, plansDir, rows) {
  return crypto.createHash("sha256").update(nonce + plansDir + rows).digest("hex").slice(0, 32);
}

function normalizeRows(text) {
  const lines = text.replace(/\r/g, "").split("\n").filter((l) => l !== "");
  return lines.map((l) => `${l}\n`).join("");
}

function write(file, plansDir) {
  const dir = plansDirForm(plansDir);
  if (dir === null) return 2;
  const rows = normalizeRows(fs.readFileSync(0, "utf8"));
  const nonce = crypto.randomBytes(16).toString("hex");
  const id = gateId(nonce, dir, rows);
  const tmp = path.join(path.dirname(file), `.${path.basename(file)}.${process.pid}.tmp`);
  // Exclusive create: a planted file or symlink at the predictable tmp name is removed
  // (unlink never follows a link), and "wx" refuses anything that reappears.
  try { fs.unlinkSync(tmp); } catch (_) { /* absent */ }
  fs.writeFileSync(tmp, `# gate-id ${id}\n# nonce ${nonce}\n# plans-dir ${dir}\n${rows}`, { mode: 0o600, flag: "wx" });
  fs.renameSync(tmp, file);
  process.stdout.write(`${id}\n`);
  return 0;
}

function verify(file, wantId, plansDir) {
  if (!ID_RE.test(String(wantId))) return 3;
  const dir = plansDirForm(plansDir);
  if (dir === null) return 3;
  let text;
  try { text = fs.readFileSync(file, "utf8"); } catch (_) { return 3; }
  const m = /^# gate-id ([0-9a-f]{32})\n# nonce ([0-9a-f]+)\n# plans-dir ([^\n]*)\n/.exec(text);
  if (!m || m[1] !== wantId || m[3] !== dir) return 3;
  const rows = text.slice(m[0].length);
  if (gateId(m[2], m[3], rows) !== m[1]) return 3;
  process.stdout.write(rows);
  return 0;
}

function main(argv) {
  const [cmd, file, a, b] = argv;
  if (cmd === "write" && file && a && argv.length === 3) return write(file, a);
  if (cmd === "verify" && file && a && b && argv.length === 4) return verify(file, a, b);
  process.stderr.write("usage: gate-artifact.js write <path> <plans-dir> | verify <path> <gate-id> <plans-dir>\n");
  return 2;
}

process.exitCode = main(process.argv.slice(2));
