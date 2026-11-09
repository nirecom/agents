#!/usr/bin/env node
"use strict";
// Tests: tests/lib/repo-settings-fixture.js, tests/lib/repo-settings-fixture.sh
// Tags: TL2, test-infrastructure, repo-settings, shared-lib, test-lang-exception:symmetry, scope:issue-specific
// #2968: installRepoSettings puts the real settings reader and .agents.json into a fixture root,
// throws on a missing source, and installs the same file set as the bash twin.

const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { caseBegin, caseEnd } = require("../lib/harness");
const { installRepoSettings } = require("../lib/repo-settings-fixture");

const ROOT = path.resolve(__dirname, "..", "..");
const fwd = (p) => p.replace(/\\/g, "/");
const mk = (label) => fs.mkdtempSync(path.join(os.tmpdir(), `rsf-2968-${label}-`));
const rm = (d) => fs.rmSync(d, { recursive: true, force: true });
const listFiles = (dir) => {
  const out = [];
  const walk = (d) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p);
      else out.push(fwd(path.relative(dir, p)));
    }
  };
  walk(dir);
  return out.sort();
};
// copySrc(dir) - a source tree holding the whole file set, so a case can break one file.
function copySrc(dir) {
  const probe = mk("probe");
  try {
    installRepoSettings(probe, ROOT);
    fs.cpSync(probe, dir, { recursive: true });
  } finally {
    rm(probe);
  }
}

caseBegin("installs-the-whole-file-set-from-default-src", "tests/lib/repo-settings-fixture.js");
test("installs-the-whole-file-set-from-default-src", () => {
  const root = mk("default");
  try {
    installRepoSettings(root);
    const files = listFiles(root);
    for (const f of ["bin/repo-settings", "bin/lib/repo-settings.sh", "hooks/lib/repo-settings.js", ".agents.json"]) {
      assert.ok(files.includes(f), `${f} missing in ${files.join(",")}`);
    }
    assert.ok(files.some((f) => f.startsWith("hooks/lib/repo-settings/") && f.endsWith(".js")), files.join(","));
    assert.equal(fs.readFileSync(path.join(root, ".agents.json"), "utf8"), fs.readFileSync(path.join(ROOT, ".agents.json"), "utf8"));
  } finally {
    rm(root);
  }
});
caseEnd();

caseBegin("json-argument-replaces-agents-json", "tests/lib/repo-settings-fixture.js");
test("json-argument-replaces-agents-json", () => {
  const root = mk("json");
  try {
    installRepoSettings(root, ROOT, '{"tests":{"dir":"t"}}');
    assert.equal(fs.readFileSync(path.join(root, ".agents.json"), "utf8"), '{"tests":{"dir":"t"}}\n');
    installRepoSettings(root, ROOT, "");
    assert.equal(fs.readFileSync(path.join(root, ".agents.json"), "utf8"), "\n", "an empty json is still a given json");
  } finally {
    rm(root);
  }
});
caseEnd();

caseBegin("missing-source-file-throws", "tests/lib/repo-settings-fixture.js");
test("missing-source-file-throws", () => {
  const src = mk("src");
  const root = mk("root");
  try {
    copySrc(src);
    fs.rmSync(path.join(src, "bin", "repo-settings"));
    assert.throws(() => installRepoSettings(root, src), /missing source/);
    assert.deepEqual(listFiles(root), [], "nothing is installed after a refusal");
    copySrc(src);
    fs.rmSync(path.join(src, ".agents.json"));
    assert.throws(() => installRepoSettings(root, src), /missing source/);
    installRepoSettings(root, src, "{}");
    assert.equal(fs.readFileSync(path.join(root, ".agents.json"), "utf8"), "{}\n", "a given json needs no source .agents.json");
  } finally {
    rm(src);
    rm(root);
  }
});
caseEnd();

caseBegin("no-modules-throws", "tests/lib/repo-settings-fixture.js");
test("no-modules-throws", () => {
  const src = mk("nomod");
  const root = mk("nomodroot");
  try {
    copySrc(src);
    fs.rmSync(path.join(src, "hooks", "lib", "repo-settings"), { recursive: true });
    assert.throws(() => installRepoSettings(root, src), /no modules/);
    assert.throws(() => installRepoSettings(""), /root required/);
  } finally {
    rm(src);
    rm(root);
  }
});
caseEnd();

caseBegin("installing-twice-is-idempotent", "tests/lib/repo-settings-fixture.js");
test("installing-twice-is-idempotent", () => {
  const root = mk("twice");
  try {
    installRepoSettings(root, ROOT);
    const first = listFiles(root);
    installRepoSettings(root, ROOT);
    assert.deepEqual(listFiles(root), first);
  } finally {
    rm(root);
  }
});
caseEnd();

caseBegin("file-set-matches-the-bash-twin", "tests/lib/repo-settings-fixture.sh");
test("file-set-matches-the-bash-twin", () => {
  const jsRoot = mk("js");
  const shRoot = mk("sh");
  try {
    installRepoSettings(jsRoot, ROOT);
    const r = spawnSync("bash", ["-c", '. "$1" && install_repo_settings "$2" "$3"', "_",
      fwd(path.join(ROOT, "tests", "lib", "repo-settings-fixture.sh")), fwd(shRoot), fwd(ROOT)], { encoding: "utf8", timeout: 60000 });
    assert.equal(r.status, 0, r.stderr);
    assert.deepEqual(listFiles(jsRoot), listFiles(shRoot));
  } finally {
    rm(jsRoot);
    rm(shRoot);
  }
});
caseEnd();

caseBegin("file-set-matches-the-bash-twin-with-json", "tests/lib/repo-settings-fixture.sh");
test("file-set-matches-the-bash-twin-with-json", () => {
  const jsRoot = mk("jsjson");
  const shRoot = mk("shjson");
  const json = '{"tests":{"dir":"t"}}';
  try {
    installRepoSettings(jsRoot, ROOT, json);
    const r = spawnSync("bash", ["-c", '. "$1" && install_repo_settings "$2" "$3" "$4"', "_",
      fwd(path.join(ROOT, "tests", "lib", "repo-settings-fixture.sh")), fwd(shRoot), fwd(ROOT), json], { encoding: "utf8", timeout: 60000 });
    assert.equal(r.status, 0, r.stderr);
    assert.deepEqual(listFiles(jsRoot), listFiles(shRoot));
    assert.equal(fs.readFileSync(path.join(jsRoot, ".agents.json"), "utf8"), fs.readFileSync(path.join(shRoot, ".agents.json"), "utf8"));
  } finally {
    rm(jsRoot);
    rm(shRoot);
  }
});
caseEnd();
