"use strict";
// bin/lib/test-wrappers/node.js — runs one *.js test file for tests/run-all.sh (#2501 D4-3).
// argv: <path> <minVersion>. The file runs exactly once, without --test, under node-guard.cjs and
// node-reporter.mjs. A run that loaded node:test (the guard's marker) or left case records is
// settled by the node:test exit table; any other run is a plain script (0 / 77 kept, else 1).
// Exit: 0 pass, 1 any failure, 77 no test ran or all skipped, 79 + `unrunnable` when node < minVersion.

const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");
const { pathToFileURL } = require("url");

// The result env belongs to this wrapper; the test code under it must never see it.
const resultDir = process.env.RUN_ALL_RESULT_DIR || fs.mkdtempSync(path.join(os.tmpdir(), "node-"));
delete process.env.RUN_ALL_RESULT_DIR;
delete process.env.RUN_ALL_RESULT_OWNER;

const REPORTER = pathToFileURL(path.join(__dirname, "node-reporter.mjs")).href;
const GUARD = path.join(__dirname, "node-guard.cjs");

const versionOf = (v) => {
  const parts = String(v).replace(/^v/, "").split(".").slice(0, 3).map((p) => parseInt(p, 10) || 0);
  while (parts.length < 3) parts.push(0);
  return parts;
};
const atLeast = (have, want) => {
  for (let i = 0; i < 3; i++) {
    if (have[i] !== want[i]) return have[i] > want[i];
  }
  return true;
};

const cleanTarget = (file) => file.replace(/[\t\r\n]/g, " ");

// The node:test exit table over the records in casesFile; a non-zero child with no FAIL record gets
// a synthetic "(file)" FAIL.
function settle(casesFile, status, file) {
  const states = fs.existsSync(casesFile)
    ? fs.readFileSync(casesFile, "utf8").split("\n").filter(Boolean).map((l) => l.split("\t")[1])
    : [];
  if (status !== 0 && !states.includes("FAIL")) {
    fs.appendFileSync(casesFile, `${states.length + 1}\tFAIL\t(file)\t${cleanTarget(file)}\n`);
    states.push("FAIL");
  }
  if (states.includes("FAIL")) return 1;
  if (states.length === 0 || states.every((s) => s === "SKIP")) return 77;
  return 0;
}

// The test code shares the process with the reporter and can find its destination in execArgv, so
// both write to a scratch directory and only well-formed records are copied into the result directory.
function runOnce(abs, file, casesFile) {
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "node-run-"));
  try {
    const marker = path.join(scratch, "node-test-loaded");
    const scratchCases = path.join(scratch, "cases.tsv");
    const args = ["--require", GUARD, `--test-reporter=${REPORTER}`, `--test-reporter-destination=${scratchCases}`, abs];
    const env = Object.assign({}, process.env, { RUN_ALL_NODE_GUARD_MARKER: marker, RUN_ALL_NODE_TARGET: file });
    const r = spawnSync(process.execPath, args, { stdio: "inherit", env });
    const lines = fs.existsSync(scratchCases) ? fs.readFileSync(scratchCases, "utf8").split("\n").filter(Boolean) : [];
    // Neither loaded node:test nor recorded a case: a plain script; the aggregator makes its (file) record.
    if (!fs.existsSync(marker) && lines.length === 0) return r.status === 0 || r.status === 77 ? r.status : 1;
    const records = lines.map((l) => l.split("\t")).filter((f) => f.length >= 3 && /^(PASS|FAIL|SKIP)$/.test(f[1]));
    const body = records.map((f, i) => `${i + 1}\t${f[1]}\t${f[2]}\t${cleanTarget(file)}\n`).join("");
    if (body !== "") fs.writeFileSync(casesFile, body);
    // A record that is not well-formed is not trusted to be a pass: the run is settled as failed.
    return settle(casesFile, records.length === lines.length ? r.status : 1, file);
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
}

function main() {
  const [file, minVersion] = process.argv.slice(2);
  // Absolute, so a relative path starting with '-' never reads as a node option.
  const abs = path.resolve(file);
  fs.mkdirSync(resultDir, { recursive: true });
  const label = `node>=${minVersion}`;
  if (!atLeast(versionOf(process.versions.node), versionOf(minVersion))) {
    console.log(`UNRUNNABLE: ${label} (have ${process.versions.node})`);
    fs.writeFileSync(path.join(resultDir, "unrunnable"), `${label}\n`);
    return 79;
  }
  return runOnce(abs, file, path.join(resultDir, "cases.tsv"));
}

process.exitCode = main();
