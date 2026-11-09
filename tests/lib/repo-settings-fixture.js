"use strict";
// Tests: tests/lib/repo-settings-fixture.js
// Tags: test-infrastructure, repo-settings, shared-lib, scope:common
// JS twin of repo-settings-fixture.sh (#2473): installs the real repo settings reader into a fixture root.
// The file set must stay in sync with repo-settings-fixture.sh (a test checks they agree).

const fs = require("node:fs");
const path = require("node:path");

const SRC_DEFAULT = path.resolve(__dirname, "..", "..");
const BASE_FILES = ["bin/repo-settings", "bin/lib/repo-settings.sh", "hooks/lib/repo-settings.js"];

// installRepoSettings(root, src, json) — copies the set into root, creating parent dirs, and writes
// root/.agents.json: json when given, else src's file. Throws when any source file is missing.
function installRepoSettings(root, src, json) {
  if (!root) throw new Error("installRepoSettings: root required");
  const from = src || SRC_DEFAULT;
  const modDir = path.join(from, "hooks", "lib", "repo-settings");
  const parts = fs.existsSync(modDir)
    ? fs.readdirSync(modDir).filter((f) => f.endsWith(".js")).sort().map((f) => `hooks/lib/repo-settings/${f}`)
    : [];
  if (parts.length === 0) throw new Error(`installRepoSettings: no modules under ${modDir}`);
  const files = BASE_FILES.concat(parts);
  if (json === undefined) files.push(".agents.json");
  for (const rel of files) {
    if (!fs.existsSync(path.join(from, rel))) throw new Error(`installRepoSettings: missing source ${path.join(from, rel)}`);
  }
  for (const rel of files) {
    fs.mkdirSync(path.dirname(path.join(root, rel)), { recursive: true });
    fs.copyFileSync(path.join(from, rel), path.join(root, rel));
  }
  if (json !== undefined) fs.writeFileSync(path.join(root, ".agents.json"), `${json}\n`);
}

module.exports = { installRepoSettings, BASE_FILES };
