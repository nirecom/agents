"use strict";
// Retired-token axis of check-migration-blocks (#2820). A registered migration retires tokens; a
// token is an error outside that migration's temporary block, and a registered block lacking
// added / deletion-condition is an error in both modes. Registry format: retired-tokens.txt.
const fs = require("fs");
const path = require("path");

const REG_REL = "bin/lib/check-migration-blocks/retired-tokens.txt";
const OWN_REGISTRY = path.join(__dirname, "retired-tokens.txt");
const FLAG = "--retired-tokens-from";
const BEGIN_MARK = "# retired-tokens:begin";
const END_MARK = "# retired-tokens:end";
const LINE_RE = /^#\s+(migration|scope|word|re|except)\s+(\S+)(?:\s+(.*))?$/;

class RegistryError extends Error {}

function escapeRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// Anchored glob: `**/` any dirs, `**` anything, `*` / `?` within one segment, `{a,b}` alternation.
function globRe(glob) {
  let out = "";
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === "*" && glob[i + 1] === "*") {
      if (glob[i + 2] === "/") { out += "(?:.*/)?"; i += 2; } else { out += ".*"; i += 1; }
    } else if (c === "*") out += "[^/]*";
    else if (c === "?") out += "[^/]";
    else if (c === "{") out += "(?:";
    else if (c === "}") out += ")";
    else if (c === ",") out += "|";
    else out += escapeRe(c);
  }
  return new RegExp(`^${out}$`);
}

// A trailing `@<glob>` narrows one token; the last `@` followed by no whitespace is the split.
function splitNarrow(body) {
  const at = body.lastIndexOf("@");
  if (at > 0 && at < body.length - 1 && !/\s/.test(body.slice(at + 1))) {
    return { src: body.slice(0, at), narrow: globRe(body.slice(at + 1)) };
  }
  return { src: body, narrow: null };
}

function tokenOf(kind, body, where) {
  const { src, narrow } = splitNarrow(body);
  if (kind === "word") return { label: src, narrow, re: new RegExp(`(?<![\\w$-])${escapeRe(src)}(?![\\w$-])`) };
  try {
    return { label: src, narrow, re: new RegExp(src) };
  } catch (e) {
    throw new RegistryError(`${where}: invalid re '${src}': ${e.message}`);
  }
}

// parseRegistry(text) -> { migrations: [{ id, descKey, scopes, tokens, excepts }] }; throws
// RegistryError on a malformed line, an unknown id, or a migration without a scope.
function parseRegistry(text, source = "registry") {
  const lines = text.split(/\r?\n/);
  const begin = lines.findIndex((l) => l.trim() === BEGIN_MARK);
  const end = lines.findIndex((l, i) => i > begin && l.trim() === END_MARK);
  if (begin < 0 || end < 0) throw new RegistryError(`${source}: missing '${BEGIN_MARK}' / '${END_MARK}' markers`);
  const byId = new Map();
  for (let i = begin + 1; i < end; i++) {
    const line = lines[i].trim();
    if (line === "") continue;
    const where = `${source}:${i + 1}`;
    const m = line.match(LINE_RE);
    if (!m || !m[3]) throw new RegistryError(`${where}: malformed registry line: ${line}`);
    const [, kind, id, rest] = m;
    if (kind === "migration") {
      if (byId.has(id)) throw new RegistryError(`${where}: duplicate migration '${id}'`);
      byId.set(id, { id, descKey: rest, scopes: [], tokens: [], excepts: [] });
      continue;
    }
    const mig = byId.get(id);
    if (!mig) throw new RegistryError(`${where}: '${kind}' for undeclared migration '${id}'`);
    if (kind === "scope") mig.scopes.push(globRe(rest));
    else if (kind === "except") {
      const e = rest.match(/^(\S+)\s+(\S.*)$/);
      if (!e) throw new RegistryError(`${where}: except needs '<path> <reason>'`);
      mig.excepts.push({ match: globRe(e[1]), reason: e[2] });
    } else mig.tokens.push(tokenOf(kind, rest, where));
  }
  const migrations = [...byId.values()];
  for (const mig of migrations) {
    if (mig.scopes.length === 0) throw new RegistryError(`${source}: migration '${mig.id}' has no scope`);
  }
  return { migrations };
}

// withoutRetiredFlag(argv) -> { from, rest }; the flag may sit before or after the mode.
function withoutRetiredFlag(argv) {
  const rest = [];
  let from = null;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] !== FLAG) { rest.push(argv[i]); continue; }
    if (i + 1 >= argv.length) throw new RegistryError(`${FLAG} needs a file`);
    from = argv[++i];
  }
  return { from, rest };
}

function readOr(file) {
  try { return fs.readFileSync(file, "utf8"); } catch { return null; }
}

// resolveRegistry({ argv, cwd, root, staged, readStaged }): --retired-tokens-from, then the
// target repo's registry (index for --staged, root for --all), then the checker's own. An
// existing registry is used even when it declares nothing. readStaged(rel) -> string|null.
function resolveRegistry({ argv = [], cwd = process.cwd(), root, staged = false, readStaged = null }) {
  const { from } = withoutRetiredFlag(argv);
  const selfRels = new Set([REG_REL]);
  let text;
  let source;
  if (from) {
    const abs = path.resolve(cwd, from);
    text = readOr(abs);
    if (text == null) throw new RegistryError(`${FLAG}: cannot read '${abs}'`);
    source = abs;
    const rel = path.relative(root, abs).replace(/\\/g, "/");
    if (!rel.startsWith("../") && !path.isAbsolute(rel)) selfRels.add(rel);
  } else {
    text = staged ? (readStaged ? readStaged(REG_REL) : null) : readOr(path.join(root, REG_REL));
    source = REG_REL;
    if (text == null) { text = readOr(OWN_REGISTRY); source = OWN_REGISTRY; }
    if (text == null) return { migrations: [], selfRels };
  }
  return { ...parseRegistry(text, source), selfRels };
}

function inspects(registry, rel) {
  if (registry.selfRels.has(rel)) return false;
  return registry.migrations.some((m) => m.scopes.some((s) => s.test(rel)));
}

// checkRetiredTokens(relPath, content, blocks, registry) -> { violations, notices }. blocks
// come from parseBlocks (beginLine, endLine, desc, addedDate, hasDeletionCond).
function checkRetiredTokens(relPath, content, blocks, registry) {
  const rel = relPath.replace(/\\/g, "/");
  const violations = [];
  const notices = [];
  if (registry.selfRels.has(rel)) return { violations, notices };
  let lines = null;
  for (const mig of registry.migrations) {
    if (!mig.scopes.some((s) => s.test(rel))) continue;
    const ex = mig.excepts.find((e) => e.match.test(rel));
    if (ex) { notices.push(`EXCEPTED ${rel}: ${ex.reason}`); continue; }
    const own = blocks.filter((b) => b.desc.includes(mig.descKey));
    for (const b of own) {
      if (!b.addedDate) violations.push(`${rel}:${b.beginLine}: error: ${mig.id} migration block missing 'added YYYY-MM-DD' field`);
      if (!b.hasDeletionCond) violations.push(`${rel}:${b.beginLine}: error: ${mig.id} migration block missing 'deletion-condition:' field`);
    }
    const inBlock = (n) => own.some((b) => b.beginLine < n && n < b.endLine);
    for (const tok of mig.tokens) {
      if (tok.narrow && !tok.narrow.test(rel)) continue;
      if (!tok.re.test(content)) continue;
      lines = lines || content.split("\n");
      lines.forEach((line, i) => {
        if (tok.re.test(line.replace(/\r$/, "")) && !inBlock(i + 1)) {
          violations.push(`${rel}:${i + 1}: error: retired token '${tok.label}' of migration ${mig.id} outside its temporary block`);
        }
      });
    }
  }
  return { violations, notices };
}

module.exports = { REG_REL, RegistryError, parseRegistry, resolveRegistry, withoutRetiredFlag, inspects, checkRetiredTokens, globRe };
