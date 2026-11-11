"use strict";
// Test-only preload for the protect-user-block hook process: child_process.spawnSync calls whose
// argv names bin/user-block-guard never start the CLI. They log one JSON line to F2940_UBG_LOG and
// answer from F2940_UBG_VERDICTS ({ "<op>" | "default": <rc> | "timeout" }). Others pass through.
const childProcess = require("child_process");
const fs = require("fs");

const real = childProcess.spawnSync;
const IS_CLI = /(^|\/)user-block-guard$/;

function verdictFor(op) {
  let map = {};
  try { map = JSON.parse(process.env.F2940_UBG_VERDICTS || "{}"); } catch (_e) { map = {}; }
  if (Object.prototype.hasOwnProperty.call(map, op)) return map[op];
  return Object.prototype.hasOwnProperty.call(map, "default") ? map.default : 0;
}

function bodyOf(args, input) {
  const i = args.lastIndexOf("--new-body-file");
  if (i < 0) return null;
  const file = args[i + 1];
  if (file === "-") return input === undefined || input === null ? "" : String(input);
  try { return fs.readFileSync(file, "utf8"); } catch (e) { return `<<unreadable body file: ${e.code}>>`; }
}

childProcess.spawnSync = function patchedSpawnSync(file, args, options) {
  const argv = Array.isArray(args) ? args : [];
  const all = [file, ...argv].map((a) => String(a).replace(/\\/g, "/"));
  const at = all.findIndex((a) => IS_CLI.test(a));
  if (at < 0) return real.apply(this, arguments);
  const cliArgs = [file, ...argv].slice(at + 1).map(String);
  const opts = (Array.isArray(args) ? options : args) || {};
  const opIdx = cliArgs.indexOf("--op");
  const op = opIdx >= 0 ? cliArgs[opIdx + 1] : "";
  if (process.env.F2940_UBG_LOG) {
    const rec = { args: cliArgs, body: bodyOf(cliArgs, opts.input), timeout: opts.timeout === undefined ? null : opts.timeout };
    fs.appendFileSync(process.env.F2940_UBG_LOG, JSON.stringify(rec) + "\n");
  }
  const verdict = verdictFor(op);
  const enc = opts.encoding && opts.encoding !== "buffer";
  const wrap = (s) => (enc ? s : Buffer.from(s));
  if (verdict === "timeout") {
    const error = Object.assign(new Error("spawnSync node ETIMEDOUT"), { code: "ETIMEDOUT", errno: -4039, syscall: "spawnSync node" });
    return { pid: 0, status: null, signal: "SIGTERM", stdout: wrap(""), stderr: wrap(""), output: [null, wrap(""), wrap("")], error };
  }
  const out = `user-block-guard: stub-${op}-rc${verdict}\n`;
  return { pid: 0, status: Number(verdict), signal: null, stdout: wrap(out), stderr: wrap(""), output: [null, wrap(out), wrap("")] };
};
