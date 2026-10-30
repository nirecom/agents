"use strict";
// Tests: hooks/lib/test-gates/case-records.js
// Tags: TL1, bin, parity, fixture, test-lang-exception:symmetry, scope:issue-specific
// Node side of bash-driver.sh (#2507 S4 parity). Holds no case markers. ask(requests, kind)
// writes the requests to one file, runs the driver once under the kind's PATH, and returns one
// { rc, out } per request in order. Requests run in one shell, so a crr row leaves the TRP_CASE_*
// globals a later embed row reads, as in the CLIs.
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const F = require("./fixture");

const DRIVER = path.join(__dirname, "bash-driver.sh").replace(/\\/g, "/");
const fwd = (p) => String(p).replace(/\\/g, "/");

function ask(requests, kind = "full") {
  const env = F.childEnv(kind);
  if (env === null) return null;
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "test-gates-2507-drv-"));
  try {
    const req = path.join(dir, "requests.tsv");
    fs.writeFileSync(req, `${requests.map((r) => r.map(fwd).join("\t")).join("\n")}\n`);
    const r = spawnSync(F.BASH, [DRIVER, fwd(req)], { env, encoding: "utf8", timeout: 120000 });
    if (r.error || r.status !== 0) throw new Error(`bash-driver failed: rc=${r.status} ${r.error || ""} ${r.stderr}`);
    const answers = [];
    let buf = [];
    // Split on LF only: a CR inside an answer (a CRLF header line) is part of what is compared.
    for (const line of r.stdout.split("\n")) {
      const m = /^@@END\t(\d+)$/.exec(line);
      if (m) {
        answers.push({ rc: Number(m[1]), out: buf.length ? `${buf.join("\n")}\n` : "" });
        buf = [];
      } else buf.push(line);
    }
    if (answers.length !== requests.length) throw new Error(`bash-driver answered ${answers.length} of ${requests.length}`);
    return answers;
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

// withPath(kind, fn) — runs fn with process.env PATH set to the kind's PATH (the Node modules
// resolve runtimes from process.env); null when that PATH cannot be built here.
async function withPath(kind, fn) {
  const env = F.childEnv(kind);
  if (env === null) return null;
  const key = Object.keys(process.env).find((k) => k.toUpperCase() === "PATH") || "PATH";
  const saved = process.env[key];
  const pathKey = Object.keys(env).find((k) => k.toUpperCase() === "PATH");
  process.env[key] = env[pathKey];
  try {
    return await fn();
  } finally {
    process.env[key] = saved;
  }
}

module.exports = { ask, withPath, DRIVER };
