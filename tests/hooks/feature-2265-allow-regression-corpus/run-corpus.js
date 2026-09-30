#!/usr/bin/env node
"use strict";
// In-process runner for the #2265 allow regression corpus and the worktree-divergence table.
// One node process judges every row: a spawn per row would make 2,600 rows far too slow.
//
// Usage: node run-corpus.js (--corpus <jsonl> | --table <file>) --main <dir> --wt <dir>
//          [--foreign <dir>] [--plain <dir>] [--fakewt <dir>] --session <id>
// --table lines are `id ~ cmd ~ cwd ~ expect` (`-` = no cwd), judged in file order.
// Placeholders: @ROOT@ / @WIN@ (the row's root, posix / backslash), @MAIN@ @WT@ @FOREIGN@
// @PLAIN@ @FAKEWT@. A cwd of MAIN/WT/... names that directory; otherwise it is substituted.
// Output: `ROW` lines (table mode, or FAIL rows in corpus mode), `FAMILY` totals, one `RESULT`.

const fs = require("fs");
const path = require("path");

const REPO = path.resolve(__dirname, "..", "..", "..");
const { judgeBashCommand } = require(path.join(REPO, "hooks", "bash-guard", "judge.js"));

const argOf = (name) => {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : undefined;
};
const dirs = {
  MAIN: argOf("--main"), WT: argOf("--wt"), FOREIGN: argOf("--foreign"),
  PLAIN: argOf("--plain"), FAKEWT: argOf("--fakewt"),
};
const session = argOf("--session") || "";
const verbose = process.env.CORPUS_VERBOSE === "1";
const FAIL_CAP = 15;

const subst = (text, rootDir) => {
  let out = text.split("@WIN@").join(rootDir.split("/").join("\\")).split("@ROOT@").join(rootDir);
  for (const key of Object.keys(dirs)) {
    if (dirs[key]) out = out.split(`@${key}@`).join(dirs[key]);
  }
  return out;
};
const cwdOf = (cwd, rootDir) => {
  if (cwd === null || cwd === undefined || cwd === "-") return undefined;
  if (dirs[cwd]) return dirs[cwd];
  return subst(cwd, rootDir);
};

const judge = (cmd, cwd) => {
  const toolInput = { command: cmd };
  if (cwd !== undefined) toolInput.cwd = cwd;
  const v = judgeBashCommand({ tool_name: "Bash", session_id: session, tool_input: toolInput }, { root: dirs.MAIN });
  return `${v.verdict}|${v.code}`;
};

const loadRows = () => {
  const corpus = argOf("--corpus");
  if (corpus) {
    const lines = fs.readFileSync(corpus, "utf8").split("\n").filter((l) => l.trim());
    const parsed = lines.map((l) => JSON.parse(l));
    const meta = parsed.find((o) => o.meta === true) || null;
    return { meta, rows: parsed.filter((o) => o.meta !== true), table: false };
  }
  const table = argOf("--table");
  const rows = fs.readFileSync(table, "utf8").split("\n")
    .filter((l) => l.trim() && !l.trim().startsWith("#"))
    .map((l) => {
      const [id, cmd, cwd, expect] = l.split("~").map((f) => f.trim());
      return { id, family: "table", cmd, root: null, cwd, expect };
    });
  return { meta: null, rows, table: true };
};

const { meta, rows, table } = loadRows();
const fam = new Map();
const bySrc = new Map();
let pass = 0;
let fail = 0;
let skip = 0;
for (const row of rows) {
  const rootDir = row.root === "WT" ? dirs.WT : dirs.MAIN;
  if (!rootDir) {
    skip += 1;
    continue;
  }
  const cmd = subst(row.cmd, rootDir);
  const got = judge(cmd, cwdOf(row.cwd, rootDir));
  const ok = got === row.expect;
  const f = fam.get(row.family) || { total: 0, pass: 0, fail: 0 };
  f.total += 1;
  if (ok) {
    f.pass += 1;
    pass += 1;
  } else {
    f.fail += 1;
    fail += 1;
  }
  fam.set(row.family, f);
  for (const src of row.sources || []) {
    const s = bySrc.get(src) || { total: 0, pass: 0, fail: 0 };
    s.total += 1;
    s[ok ? "pass" : "fail"] += 1;
    bySrc.set(src, s);
  }
  if (table) {
    process.stdout.write(`ROW ${row.id} ${ok ? "PASS" : "FAIL"} want=${row.expect} got=${got}\n`);
  } else if (!ok && (verbose || f.fail <= FAIL_CAP)) {
    process.stdout.write(`ROW ${row.id} FAIL want=${row.expect} got=${got} rule=${row.rule} cmd=${row.cmd}\n`);
  }
}

for (const [name, f] of fam) process.stdout.write(`FAMILY ${name} total=${f.total} pass=${f.pass} fail=${f.fail}\n`);
for (const [name, s] of bySrc) process.stdout.write(`SOURCE ${name} total=${s.total} pass=${s.pass} fail=${s.fail}\n`);
const r = meta ? meta.rules : {};
const distinct = (src) => new Set(rows.filter((x) => (x.sources || []).includes(src)).map((x) => x.rule)).size;
process.stdout.write(`RESULT pass=${pass} fail=${fail} skip=${skip} rows=${rows.length}` +
  ` meta_rows=${meta ? meta.rows : "-"} meta_static=${r["static-2451"] === undefined ? "-" : r["static-2451"]}` +
  ` static_rules=${distinct("static-2451")} gen_rules=${distinct("gen-2421")} ssot_rules=${distinct("ssot-add")}` +
  ` meta_gen=${r["gen-2421"] === undefined ? "-" : r["gen-2421"]} meta_ssot=${r["ssot-add"] === undefined ? "-" : r["ssot-add"]}\n`);
