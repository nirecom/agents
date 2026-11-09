"use strict";
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");
const RT = require("./check-migration-blocks/retired-tokens");

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

// EXCLUDE_RE holds back only the format axes; the retired-token axis follows the registry scope.
const formatAxesApply = (rel) => !EXCLUDE_RE.some((excl) => excl.test(rel));

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

// `git show :<path>` needs `/`; a Windows backslash path made --staged skip the file silently.
function readIndexContent(filePath, root, env) {
  const rel = path.relative(root, filePath).replace(/\\/g, "/");
  try {
    return execFileSync("git", ["show", ":" + rel], { cwd: root, env: env || process.env, encoding: "utf8", stdio: ["pipe", "pipe", "pipe"], timeout: 15000 });
  } catch (e) {
    return null;
  }
}

function stagedText(readStaged, rel) {
  const buf = readStaged(rel.replace(/\\/g, "/"));
  return buf == null ? null : buf.toString("utf8");
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
        openBlock.endLine = lineNum;
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
function staleReport(rootArg, io) {
  const root = rootArg ? path.resolve(io.cwd, rootArg) : getGitRoot(io);
  try {
    if (!fs.statSync(root).isDirectory()) throw new Error("not a directory");
  } catch (e) {
    io.stderr.write(`check-migration-blocks.js: cannot scan '${root}': ${e.message}\n`);
    return 2;
  }
  const lines = [];
  walkTree(root, (absPath) => {
    const rel = path.relative(root, absPath).replace(/\\/g, "/");
    if (!formatAxesApply(rel)) return;
    let content;
    try { content = fs.readFileSync(absPath, "utf8"); } catch (e) { return; }
    for (const { block: b } of staleBlocks(parseBlocks(content, rel).blocks)) {
      lines.push(`${rel}:${b.beginLine}:${b.addedDate}`);
    }
  });
  lines.forEach((l) => io.stdout.write(l + "\n"));
  return 0;
}

function getGitRoot(io) {
  try {
    return execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: io.cwd, env: io.env, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: 15000 }).trim();
  } catch (e) {
    return io.cwd;
  }
}

function verdict(violations, warnings, io, notices = []) {
  notices.forEach((n) => io.stdout.write(n + "\n"));
  if (violations.length > 0) {
    violations.forEach((v) => io.stdout.write(v + "\n"));
    return 1;
  }
  warnings.forEach((w) => io.stderr.write(w + "\n"));
  return 0;
}

function usage(io) {
  io.stderr.write("usage: check-migration-blocks.js [--retired-tokens-from <file>] --staged [<file>...]\n");
  io.stderr.write("       check-migration-blocks.js [--retired-tokens-from <file>] --all [<root>]\n");
  io.stderr.write("       check-migration-blocks.js --stale-report [<root>]\n");
  return 2;
}

// run({ argv, cwd, env, stdout, stderr, readStaged }) -> rc: 0 clean, 1 violations, 2 usage /
// unscannable. readStaged(rel) -> Buffer|null replaces the per-file `git show` of --staged.
// The retired-token registry; a RegistryError (malformed registry, flag without a file) is rc 2.
function loadRegistry(argv, root, staged, readOne, io) {
  try {
    return RT.resolveRegistry({ argv, cwd: io.cwd, root, staged, readStaged: readOne });
  } catch (e) {
    if (!(e instanceof RT.RegistryError)) throw e;
    io.stderr.write(`check-migration-blocks.js: ${e.message}\n`);
    return null;
  }
}

// A NUL byte marks a binary file (e.g. a local index database under a `**` scope): it holds no source line to judge.
function retiredAxis(rel, content, blocks, registry, out) {
  if (content.includes("\0")) return;
  const r = RT.checkRetiredTokens(rel, content, blocks, registry);
  out.violations.push(...r.violations);
  out.notices.push(...r.notices);
}

function runStaged(files, argv, io, readStaged) {
  const root = getGitRoot(io);
  const indexText = (rel) => {
    const viaSnapshot = readStaged ? stagedText(readStaged, rel) : null;
    return viaSnapshot != null ? viaSnapshot : readIndexContent(path.join(root, rel), root, io.env);
  };
  const registry = loadRegistry(argv, root, true, indexText, io);
  if (!registry) return 2;
  const out = { violations: [], notices: [] };
  const warnings = [];
  for (const f of files) {
    const absPath = path.isAbsolute(f) ? f : path.join(root, f);
    const rel = path.relative(root, absPath).replace(/\\/g, "/");
    const formatAxes = formatAxesApply(rel);
    if (!formatAxes && !RT.inspects(registry, rel)) continue;
    const content = readStaged ? stagedText(readStaged, rel) : readIndexContent(absPath, root, io.env);
    if (content == null) continue;
    const { blocks, violations: v } = parseBlocks(content, f);
    if (formatAxes) {
      out.violations.push(...v);
      checkAxis3(blocks, f, "staged", warnings);
      checkAxis4(blocks, f, warnings);
    }
    retiredAxis(rel, content, blocks, registry, out);
  }
  return verdict(out.violations, warnings, io, out.notices);
}

function runAll(rootArg, argv, io) {
  const root = rootArg ? path.resolve(io.cwd, rootArg) : io.cwd;
  const registry = loadRegistry(argv, root, false, null, io);
  if (!registry) return 2;
  const out = { violations: [], notices: [] };
  const warnings = [];
  walkTree(root, (absPath) => {
    const rel = path.relative(root, absPath).replace(/\\/g, "/");
    const formatAxes = formatAxesApply(rel);
    if (!formatAxes && !RT.inspects(registry, rel)) return;
    let content;
    try { content = fs.readFileSync(absPath, "utf8"); } catch { return; }
    const { blocks, violations: v } = parseBlocks(content, rel);
    if (formatAxes) {
      out.violations.push(...v);
      checkAxis3(blocks, rel, "all", warnings);
      checkAxis4(blocks, rel, warnings);
    }
    retiredAxis(rel, content, blocks, registry, out);
  });
  return verdict(out.violations, warnings, io, out.notices);
}

function run({ argv = [], cwd = process.cwd(), env = process.env, stdout = process.stdout, stderr = process.stderr, readStaged = null } = {}) {
  const io = { cwd, env, stdout, stderr };
  let args;
  try {
    args = RT.withoutRetiredFlag(argv).rest;
  } catch (e) {
    stderr.write(`check-migration-blocks.js: ${e.message}\n`);
    return usage(io);
  }
  if (args.length === 0) return usage(io);

  const mode = args[0];

  if (mode === "--staged") {
    return runStaged(args.slice(1), argv, io, readStaged);
  } else if (mode === "--all") {
    return runAll(args[1], argv, io);
  } else if (mode === "--stale-report") {
    return staleReport(args[1], io);
  }
  stderr.write(`check-migration-blocks.js: unknown mode '${mode}'\n`);
  return usage(io);
}

module.exports = { run };

if (require.main === module) {
  process.exitCode = run({ argv: process.argv.slice(2) });
}
