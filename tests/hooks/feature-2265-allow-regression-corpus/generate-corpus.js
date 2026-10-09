#!/usr/bin/env node
"use strict";
// ONE-OFF generator for corpus.jsonl (committed data; tests never run this). It snapshots every
// spelling the retired #2421 generator and the #2451 static rules allowed, so the classifier is
// proven to cover the class before the static rules go (#2265). Design: the #2265 detail plan S0.
// Usage: node generate-corpus.js [--old-sha 72349bef] [--merge-sha 0dd05a82] [--out <file>]
// Exits 1 on a surviving host path (the file is public) or a static set other than 206 rules.

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");

const REPO = path.resolve(__dirname, "..", "..", "..");
const STATIC_EXPECTED = 206;
const ADDED_ENTRY = "bin/workflow/handoff-append";

const argOf = (name, fallback) => {
  const i = process.argv.indexOf(name);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
};
const OLD_SHA = argOf("--old-sha", "72349bef");
const MERGE_SHA = argOf("--merge-sha", "0dd05a82");
const OUT = argOf("--out", path.join(__dirname, "corpus.jsonl"));

const die = (msg) => {
  process.stderr.write(`generate-corpus: ${msg}\n`);
  process.exit(1);
};
const git = (...args) => execFileSync("git", ["-C", REPO, ...args], { encoding: "utf8", maxBuffer: 64 << 20 });
const readList = (file) => fs.readFileSync(file, "utf8").split("\n")
  .map((l) => l.replace(/\s+$/, "")).filter((l) => l && !/^\s*#/.test(l));

// --- 1. the retired generator, run against a temp fixture root -------------------------------
const work = fs.mkdtempSync(path.join(os.tmpdir(), "corpus-2265-"));
const oldGen = path.join(work, "old-settings-allow-rules.js");
fs.writeFileSync(oldGen, git("show", `${OLD_SHA}^:install/lib/settings-allow-rules.js`));
const { generatedAllowRules } = require(oldGen);

const root = path.join(work, "root");
const entries = readList(path.join(REPO, "install", "settings-allow-commands.txt"));
if (!entries.includes(ADDED_ENTRY)) entries.push(ADDED_ENTRY);
for (const entry of entries) {
  const dst = path.join(root, entry);
  fs.mkdirSync(path.dirname(dst), { recursive: true });
  fs.copyFileSync(path.join(REPO, entry), dst);
}
fs.mkdirSync(path.join(root, "install"), { recursive: true });
fs.writeFileSync(path.join(root, "install", "settings-allow-commands.txt"), entries.join("\n") + "\n");
fs.copyFileSync(path.join(REPO, "install", "path-exposed-commands.txt"),
  path.join(root, "install", "path-exposed-commands.txt"));

const rootPosix = root.split("\\").join("/");
const rootWin = rootPosix.split("/").join("\\");
const genRules = generatedAllowRules({ agentsRoot: rootPosix }).rules
  .map((r) => r.split(rootWin).join("@WIN@").split(rootPosix).join("@ROOT@"));
fs.rmSync(work, { recursive: true, force: true });

// --- 2. the #2451 static set ---------------------------------------------------------------
const allowAt = (rev) => JSON.parse(git("show", `${rev}:settings.json`)).permissions.allow;
const before = new Set(allowAt(`${MERGE_SHA}^1`));
const staticRules = allowAt(MERGE_SHA).filter((r) => !before.has(r));
if (staticRules.length !== STATIC_EXPECTED) die(`static set is ${staticRules.length}, want ${STATIC_EXPECTED}`);

// --- 3. merge with sources -----------------------------------------------------------------
const isAdded = (r) => r.includes(ADDED_ENTRY) || r.includes(ADDED_ENTRY.split("/").join("\\"));
const bySource = new Map();
const addRule = (r, src) => {
  if (!bySource.has(r)) bySource.set(r, new Set());
  bySource.get(r).add(src);
};
genRules.forEach((r) => addRule(r, isAdded(r) ? "ssot-add" : "gen-2421"));
staticRules.forEach((r) => addRule(r, "static-2451"));

// --- 4. family + expectation ---------------------------------------------------------------
const SCRIPT = "allow|BG-ALLOW-SELF-SCRIPT";
const BARE = "allow|BG-ALLOW-SELF-BARE";
const NOTIFY = "notify|BG-NOTIFY-SCRIPT-NO-INTERPRETER";
const WHY_EXEC = "retired exec-position spelling: the calling convention puts the interpreter first (#2262), so L3 notify asks for the fix";
const WHY_WIN_UNQ = "retired spelling: bash drops the unquoted backslashes so it never reaches the script; allowing it is harmless and pins the raw-spelling match";

const familyOf = (body) => {
  const bc = /^bash -c '(.*)'$/.exec(body);
  if (bc) {
    const cd = /^cd "\$AGENTS_MAIN_ROOT" && (.*)$/.exec(bc[1]);
    if (cd) return cd[1].includes("/") ? "bashc-cd" : "bashc-cd-bare";
    return bc[1].includes("/") ? "bashc" : "bashc-bare";
  }
  if (body.startsWith('"$AGENTS_MAIN_ROOT/')) return "exec-env";
  if (body.startsWith("@ROOT@/")) return "exec-abs";
  if (body.startsWith('"@ROOT@/')) return "exec-abs-q";
  if (body.startsWith('"@WIN@\\')) return "exec-win-q";
  const interp = /^(?:bash|node) (.*)$/.exec(body);
  if (interp) {
    const rest = interp[1];
    if (rest.startsWith('"$AGENTS_MAIN_ROOT/')) return "env";
    if (rest.startsWith("@ROOT@/")) return "abs";
    if (rest.startsWith('"@ROOT@/')) return "abs-q";
    if (rest.startsWith("@WIN@\\")) return "win-unq";
    if (rest.startsWith('"@WIN@\\')) return "win-q";
    if (rest.includes("/")) return "rel";
  }
  if (!body.includes("/") && !body.includes(" ")) return "bare";
  return die(`unclassifiable rule body: ${body}`);
};
const expectOf = (fam) => {
  if (fam.startsWith("exec-")) return { expect: NOTIFY, why: WHY_EXEC };
  if (fam === "win-unq") return { expect: SCRIPT, why: WHY_WIN_UNQ };
  if (fam === "bare" || fam.endsWith("-bare")) return { expect: BARE };
  return { expect: SCRIPT };
};

// --- 5. expansion: ` *` -> 4 representative arguments; single quotes cannot nest in bash -c --
const ARGS = [
  ["list", "--list", "--list"],
  ["path", '--path "$HOME/x"', '--path "$HOME/x"'],
  ["msg", "--msg 'a b'", '--msg "a b"'],
  ["summary", '--summary "a (b) c"', '--summary "a (b) c"'],
];
const rows = [];
let ruleIdx = 0;
for (const [rule, srcSet] of bySource) {
  const m = /^Bash\((.*)\)$/.exec(rule);
  if (!m) die(`not a Bash(...) rule: ${rule}`);
  const body = m[1];
  const hasWild = body.endsWith(" *") || body.endsWith(" *'");
  const base = hasWild ? body.replace(/ \*('?)$/, "$1") : body;
  const fam = familyOf(base);
  const inBashC = fam.startsWith("bashc");
  const variants = hasWild
    ? ARGS.map(([key, plain, inner]) => [key, base.replace(/('?)$/, ` ${inBashC ? inner : plain}$1`)])
    : [["noarg", base]];
  const hasRoot = base.includes("@ROOT@") || base.includes("@WIN@");
  const axes = hasRoot ? [["main", "MAIN", null], ["wt", "WT", null]]
    : fam === "rel" ? [["main", null, "MAIN"], ["wt", null, "WT"]]
      : [["one", null, null]];
  const { expect, why } = expectOf(fam);
  for (const [key, cmd] of variants) {
    for (const [axis, rootAxis, cwdAxis] of axes) {
      const row = { id: `${ruleIdx}.${key}.${axis}`, sources: [...srcSet].sort(), family: fam, rule, cmd,
        root: rootAxis, cwd: cwdAxis, expect };
      if (why) row.why = why;
      rows.push(row);
    }
  }
  ruleIdx += 1;
}

const count = (src) => [...bySource.values()].filter((s) => s.has(src)).length;
const meta = { meta: true, rules: { "gen-2421": count("gen-2421"), "static-2451": count("static-2451"),
  "ssot-add": count("ssot-add"), total: bySource.size }, rows: rows.length };
const text = [meta, ...rows].map((o) => JSON.stringify(o)).join("\n") + "\n";

// --- 6. public-safety gate -----------------------------------------------------------------
const tmpPosix = os.tmpdir().split("\\").join("/");
const user = os.userInfo().username;
const leaks = [/[A-Za-z]:[\\/]/, /\/tmp\//, /\/Users\//, /\/home\//];
if (leaks.some((re) => re.test(text)) || text.includes(tmpPosix) ||
    (user.length >= 3 && new RegExp(`[\\\\/]${user}[\\\\/]`, "i").test(text))) {
  die("a host path survived placeholder substitution - refusing to write");
}
fs.writeFileSync(OUT, text);
process.stdout.write(`wrote ${rows.length} rows, rules ${JSON.stringify(meta.rules)}\n`);
