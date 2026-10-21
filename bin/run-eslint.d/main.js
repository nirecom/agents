"use strict";
// Argument handling, grouping by lint root, and the exit code of bin/run-eslint.
const fs = require("fs");
const path = require("path");
const { locateConfig } = require("./locate-config.js");
const { provision } = require("./provision.js");
const { lintGroup } = require("./lint.js");

const SCRIPT_CHECKOUT_ROOT = path.resolve(__dirname, "..", "..");
// toWindowsPath turns an MSYS drive-letter path into a native Windows path on win32 and is a no-op elsewhere.
const { toWindowsPath } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "lib", "branch-diff.js"));

const USAGE = "usage: node bin/run-eslint <path>...\n";
const write = (text) => process.stdout.write(text);

// main(argv) -> exit code (0 clean/warn/skip, 1 errors, 2 usage or API error)
async function main(argv) {
  if (argv.length === 0) {
    process.stderr.write(USAGE);
    return 2;
  }
  const targets = [];
  for (const raw of argv) {
    const abs = path.resolve(toWindowsPath(raw));
    let st;
    try {
      st = fs.statSync(abs);
    } catch {
      process.stderr.write(`run-eslint: no such file or directory: ${raw}\n${USAGE}`);
      return 2;
    }
    targets.push({ path: abs, isDir: st.isDirectory() });
  }

  const groups = new Map();
  for (const t of targets) {
    const found = locateConfig(t.path, t.isDir);
    if (!found) {
      write(`eslint not found — check skipped (no eslint.config.* above ${t.path})\n`);
      continue;
    }
    if (!groups.has(found.configFile)) groups.set(found.configFile, { ...found, targets: [] });
    groups.get(found.configFile).targets.push(t);
  }

  let code = 0;
  for (const g of groups.values()) {
    const ready = provision(g.lintRoot);
    if (!ready.eslintPath) {
      write(`eslint not found — check skipped (${ready.reason})\n`);
      continue;
    }
    try {
      const errors = await lintGroup({ ...g, eslintPath: ready.eslintPath, write });
      if (errors > 0 && code === 0) code = 1;
    } catch (e) {
      process.stderr.write(`run-eslint: ${g.configFile}: ${e && e.message ? e.message : e}\n`);
      code = 2;
    }
  }
  return code;
}

module.exports = { main };
