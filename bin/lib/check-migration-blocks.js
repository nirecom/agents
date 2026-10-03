"use strict";
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const BEGIN_RE = /^\s*(#|\/\/)\s*---\s*BEGIN\s+temporary:\s+(.+?)\s*---\s*$/;
const END_RE   = /^\s*(#|\/\/)\s*---\s*END\s+temporary:/;
const ARROW_RE = /→|->/;
const MIGRATION_RE = /migration/;
const DATE_RE = /added\s+(\d{4}-\d{2}-\d{2})/;
const DELETION_COND_RE = /^\s*(#|\/\/)\s*deletion-condition:/;
const EXCLUDE_RE = [
  /(?:^|[/\\])rules[/\\].*\.md$/,
  /(?:^|[/\\])tests[/\\]/,
  /(?:^|[/\\])\.claude[/\\]worktrees[/\\]/,
];

function walkTree(dir, cb) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (e) { return; }
  for (const entry of entries) {
    if (entry.name === ".git" || entry.name === "node_modules") continue;
    const absPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      walkTree(absPath, cb);
    } else {
      cb(absPath);
    }
  }
}

function readIndexContent(filePath, root) {
  const rel = path.relative(root, filePath);
  try {
    return execFileSync("git", ["show", ":" + rel], { cwd: root, encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] });
  } catch (e) {
    return null;
  }
}

function parseBlocks(content, filePath) {
  const lines = content.split("\n");
  const blocks = [];
  const violations = [];
  let openBlock = null;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const lineNum = i + 1;

    const beginMatch = line.match(BEGIN_RE);
    if (beginMatch) {
      if (openBlock) {
        violations.push(
          `${filePath}:${lineNum}: error: nested BEGIN temporary block (previous BEGIN at line ${openBlock.beginLine})`
        );
      }
      const desc = beginMatch[2];
      const addedMatch = desc.match(DATE_RE);
      const nextLine = lines[i + 1] || "";
      const hasDeletionCond = DELETION_COND_RE.test(nextLine);
      openBlock = {
        beginLine: lineNum,
        desc,
        addedDate: addedMatch ? addedMatch[1] : null,
        hasDeletionCond,
      };
      continue;
    }

    if (END_RE.test(line)) {
      if (!openBlock) {
        violations.push(`${filePath}:${lineNum}: error: END temporary without matching BEGIN`);
      } else {
        if (!ARROW_RE.test(openBlock.desc) || !MIGRATION_RE.test(openBlock.desc)) {
          violations.push(
            `${filePath}:${openBlock.beginLine}: error: migration block description missing arrow (→ or ->) or 'migration' keyword: "${openBlock.desc}"`
          );
        }
        blocks.push(openBlock);
        openBlock = null;
      }
    }
  }

  if (openBlock) {
    violations.push(`${filePath}:${openBlock.beginLine}: error: BEGIN temporary without matching END`);
  }

  return { blocks, violations };
}

function checkAxis3(blocks, filePath, mode, warnings) {
  for (const b of blocks) {
    if (mode === "all" && !b.addedDate) continue;
    if (!b.addedDate) warnings.push(`${filePath}:${b.beginLine}: warning: migration block missing 'added YYYY-MM-DD' field`);
    if (!b.hasDeletionCond) warnings.push(`${filePath}:${b.beginLine}: warning: migration block missing 'deletion-condition:' field`);
  }
}

const STALE_DAYS = 90;

function staleBlocks(blocks) {
  const today = new Date();
  const out = [];
  for (const b of blocks) {
    if (!b.addedDate) continue;
    const diffDays = (today - new Date(b.addedDate)) / (1000 * 60 * 60 * 24);
    if (diffDays > STALE_DAYS) out.push({ block: b, diffDays });
  }
  return out;
}

function checkAxis4(blocks, filePath, warnings) {
  for (const { block: b, diffDays } of staleBlocks(blocks)) {
    warnings.push(
      `${filePath}:${b.beginLine}: warning: migration block is ${Math.floor(diffDays)} days old (added ${b.addedDate}); consider removing`
    );
  }
}

// --stale-report: one `path:line:added` line per block older than STALE_DAYS; exit 0,
// exit 2 when the root cannot be scanned (the sweep job must see that as a failure).
function staleReport(rootArg) {
  const root = rootArg ? path.resolve(rootArg) : getGitRoot();
  try {
    if (!fs.statSync(root).isDirectory()) throw new Error("not a directory");
  } catch (e) {
    process.stderr.write(`check-migration-blocks.js: cannot scan '${root}': ${e.message}\n`);
    process.exit(2);
  }
  const lines = [];
  walkTree(root, (absPath) => {
    const rel = path.relative(root, absPath).replace(/\\/g, "/");
    if (EXCLUDE_RE.some((excl) => excl.test(rel))) return;
    let content;
    try { content = fs.readFileSync(absPath, "utf8"); } catch (e) { return; }
    for (const { block: b } of staleBlocks(parseBlocks(content, rel).blocks)) {
      lines.push(`${rel}:${b.beginLine}:${b.addedDate}`);
    }
  });
  lines.forEach((l) => process.stdout.write(l + "\n"));
  process.exit(0);
}

function getGitRoot() {
  try {
    return execFileSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8" }).trim();
  } catch (e) {
    return process.cwd();
  }
}

function main() {
  const args = process.argv.slice(2);
  if (args.length === 0) {
    process.stderr.write("usage: check-migration-blocks.js --staged [<file>...]\n");
    process.stderr.write("       check-migration-blocks.js --all [<root>]\n");
    process.stderr.write("       check-migration-blocks.js --stale-report [<root>]\n");
    process.exit(2);
  }

  const mode = args[0];

  if (mode === "--staged") {
    const files = args.slice(1);
    const root = getGitRoot();
    const violations = [];
    const warnings = [];
    for (const f of files) {
      const absPath = path.isAbsolute(f) ? f : path.join(root, f);
      const content = readIndexContent(absPath, root);
      if (content == null) continue;
      const { blocks, violations: v } = parseBlocks(content, f);
      violations.push(...v);
      checkAxis3(blocks, f, "staged", warnings);
      checkAxis4(blocks, f, warnings);
    }
    if (violations.length > 0) {
      violations.forEach((v) => process.stdout.write(v + "\n"));
      process.exit(1);
    }
    if (warnings.length > 0) {
      warnings.forEach((w) => process.stderr.write(w + "\n"));
    }
    process.exit(0);

  } else if (mode === "--all") {
    const root = args[1] ? path.resolve(args[1]) : process.cwd();
    const violations = [];
    const warnings = [];
    walkTree(root, (absPath) => {
      const rel = path.relative(root, absPath);
      for (const excl of EXCLUDE_RE) {
        if (excl.test(rel)) return;
      }
      let content;
      try { content = fs.readFileSync(absPath, "utf8"); } catch (e) { return; }
      const { blocks, violations: v } = parseBlocks(content, rel);
      violations.push(...v);
      checkAxis3(blocks, rel, "all", warnings);
      checkAxis4(blocks, rel, warnings);
    });
    if (violations.length > 0) {
      violations.forEach((v) => process.stdout.write(v + "\n"));
      process.exit(1);
    }
    if (warnings.length > 0) {
      warnings.forEach((w) => process.stderr.write(w + "\n"));
    }
    process.exit(0);

  } else if (mode === "--stale-report") {
    staleReport(args[1]);

  } else {
    process.stderr.write(`check-migration-blocks.js: unknown mode '${mode}'\n`);
    process.stderr.write("usage: check-migration-blocks.js --staged [<file>...]\n");
    process.stderr.write("       check-migration-blocks.js --all [<root>]\n");
    process.stderr.write("       check-migration-blocks.js --stale-report [<root>]\n");
    process.exit(2);
  }
}

main();
