"use strict";
// gh issue create|edit|comment|delete -> the operation descriptors handed to bin/user-block-guard.
// A value the hook cannot read literally is marked unreadable, never guessed; a target it cannot
// read (non-GitHub selector, substituted repo or issue) makes the whole segment unresolved.
const fs = require("fs");
const path = require("path");
const { normalizeCwd } = require("../lib/path-normalize");
const { vocabularyFor } = require("../lib/gh-flag-vocab");
const { resolveGhSubArgv } = require("../lib/bash-write-patterns/patterns");
const sel = require("../lib/forge-repo-selectors");

const BODY_FILE_MAX = 1024 * 1024;
const SHORT_LONG = { t: "--title", b: "--body", F: "--body-file", R: "--repo", w: "--web", e: "--editor", T: "--template" };
const ISSUE_URL_RE = /^https?:\/\/github\.com\/([^/]+\/[^/]+)\/issues\/(\d+)\/?$/i;

// Non-literal: a `$` or backtick outside single quotes in the raw spelling.
function isNonLiteral(raw) {
  if (typeof raw !== "string") return false;
  return sel.NON_LITERAL_RE.test(raw.replace(/'[^']*'/g, ""));
}

const unreadable = () => ({ unreadable: true });
const unresolved = (why) => ({ unresolved: true, why });

function textValue(v, raw) {
  if (typeof v !== "string" || isNonLiteral(raw)) return unreadable();
  return { value: v };
}

function readBodyFile(file, raw, cwd) {
  if (typeof file !== "string" || file === "" || file === "-" || isNonLiteral(raw)) return unreadable();
  try {
    const base = normalizeCwd(cwd) || process.cwd();
    const full = path.resolve(base, normalizeCwd(file) || file);
    const st = fs.statSync(full);
    if (!st.isFile() || st.size > BODY_FILE_MAX) return unreadable();
    return { value: fs.readFileSync(full, "utf8") };
  } catch (_e) {
    return unreadable();
  }
}

// pflag-style walk: values (last wins, with their position), booleans and positionals.
function parseFlags(tokens, raws, vocab) {
  const vals = {};
  const bools = new Set();
  const pos = [];
  let endOfFlags = false;
  for (let i = 0; i < tokens.length; i++) {
    const tok = tokens[i];
    const raw = raws[i];
    if (endOfFlags || typeof tok !== "string" || tok === "-" || tok[0] !== "-") { pos.push({ v: tok, raw }); continue; }
    if (tok === "--") { endOfFlags = true; continue; }
    const set = (name, v, r) => { vals[name] = { v, raw: r, at: i }; };
    if (tok[1] === "-") {
      const eq = tok.indexOf("=");
      if (eq > 0) { set(tok.slice(0, eq), tok.slice(eq + 1), raw); continue; }
      if (vocab.longValue.has(tok)) { set(tok, tokens[i + 1], raws[i + 1]); i += 1; continue; }
      bools.add(tok);
      continue;
    }
    const ch = tok[1];
    const long = SHORT_LONG[ch] || "-" + ch;
    if (vocab.shortValue.has(ch)) {
      if (tok.length > 2) set(long, tok.slice(2), raw);
      else { set(long, tokens[i + 1], raws[i + 1]); i += 1; }
      continue;
    }
    bools.add(long);
  }
  return { vals, bools, pos };
}

function titleOf(p) {
  const t = p.vals["--title"];
  return t ? textValue(t.v, t.raw) : undefined;
}

function bodyOf(p, cwd) {
  const b = p.vals["--body"];
  const f = p.vals["--body-file"];
  if (f && (!b || f.at > b.at)) return readBodyFile(f.v, f.raw, cwd);
  return b ? textValue(b.v, b.raw) : undefined;
}

// The repository this gh segment targets: selector, else GH_REPO prefix, else gh's own default.
function repoOf(argv, argvRaw, rawText, ghRepo) {
  if (!sel.hostSelectorIsGithub(sel.hostSelector(argv, argvRaw))) return unresolved("--hostname is not github.com");
  const selectors = sel.repoSelectors(argv, argvRaw);
  if (selectors.length) {
    const v = sel.resolveSelectors(selectors, rawText || "");
    return v.kind === "explicit" ? { repo: v.ownerRepo } : unresolved(v.why);
  }
  if (ghRepo) {
    if (isNonLiteral(ghRepo.raw)) return unresolved("GH_REPO is not a literal value");
    const r = sel.splitSelector(ghRepo.value);
    return r ? { repo: r } : unresolved("GH_REPO is not a github.com OWNER/REPO");
  }
  return { repo: null };
}

function targetOf(p, repo) {
  if (typeof p.v !== "string" || isNonLiteral(p.raw)) return unresolved("the issue number is not a literal value");
  const n = p.v.replace(/^#/, "");
  if (/^\d+$/.test(n)) return { issue: n, repo };
  const m = p.v.match(ISSUE_URL_RE);
  if (m && sel.splitSelector(m[1])) return { issue: m[2], repo: m[1] };
  return unresolved("the issue target " + p.v + " is not a github.com issue");
}

function withTarget(base, t) {
  const d = Object.assign({}, base, { issue: t.issue });
  if (t.repo) d.repo = t.repo;
  return d;
}

// argv/argvRaw follow the `gh` word. Returns { descs: [...] } or { unresolved, why }.
function extractIssue(argv, argvRaw, rawText, ghRepo, cwd) {
  const sub = resolveGhSubArgv(argv);
  if (sub[0] !== "issue") return { descs: [] };
  const verb = sub[1];
  const off = argv.length - sub.length;
  const tokens = argv.slice(off + 2);
  const raws = (Array.isArray(argvRaw) ? argvRaw : argv).slice(off + 2);
  const r = repoOf(argv, argvRaw, rawText, ghRepo);
  if (r.unresolved) return r;
  const p = parseFlags(tokens, raws, vocabularyFor(argv));
  const title = titleOf(p);
  const body = bodyOf(p, cwd);
  const descs = [];
  const targets = [];
  const needTargets = verb === "edit" || verb === "comment" || verb === "delete";
  if (needTargets) {
    for (const pp of p.pos) {
      const t = targetOf(pp, r.repo);
      if (t.unresolved) return t;
      targets.push(t);
    }
    if (targets.length === 0) return unresolved("gh issue " + verb + " names no issue the guard can read");
  }
  if (verb === "create" || verb === "new") {
    if (!title && !body) return { descs };
    const d = { op: "create", title, body };
    if (r.repo) d.repo = r.repo;
    descs.push(d);
  } else if (verb === "edit") {
    if (!title && !body) return { descs };
    for (const t of targets) descs.push(withTarget({ op: "edit", title, body }, t));
  } else if (verb === "comment") {
    const t = targets[0];
    if (p.bools.has("--delete-last")) descs.push(withTarget({ op: "comment-delete", lastOwn: true }, t));
    else if (p.bools.has("--edit-last")) {
      descs.push(withTarget({ op: "comment-edit", lastOwn: true, createIfNone: p.bools.has("--create-if-none"), body: body || unreadable() }, t));
    } else if (body) descs.push(withTarget({ op: "comment-create", body }, t));
  } else if (verb === "delete") {
    for (const t of targets) descs.push(withTarget({ op: "issue-delete" }, t));
  }
  return { descs };
}

module.exports = { extractIssue, repoOf, textValue, readBodyFile, isNonLiteral, unreadable, unresolved };
