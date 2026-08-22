"use strict";

// What is in scope is issue CREATION — `gh issue create` and the REST calls that
// do the same thing. Everything else `gh` can do (edit, close, list, a GET) is
// out of scope, and out of scope must stay cheap: no probe, no prompt. The hard
// part is that "which subcommand is this" is not argv[0]: global flags come
// first, and `gh api` has no verb at all. Both questions are answered with the
// shared primitives that already model them, so a fix there fixes both callers.
const { resolveGhSubArgv } = require("../lib/bash-write-patterns/patterns");
const { commandBasename, ASSIGN_RE } = require("../lib/bash-write-patterns/segment-utils");
const { isValidOwner, isValidRepo } = require("../lib/parse-remote-url");
const { interpreterKindOfWord } = require("../block-clearance-token-write/interpreter-scan");
const { isForgeScanTarget } = require("../lib/forge-write-extract");
const { scanGhApiFlags, isGhApiWriteArgv, hasInputFlag, PAYLOAD_FIELD_FLAGS } = require("./gh-api-argv");
const { hasAnsicSpan } = require("./nested-commands");

const API_HOST = "api.github.com";
const MAX_SUB_WORDS = 24;
const NON_LITERAL_RE = /[$`]/;

// First path segments that are NOT a repository and never carry an issues
// subtree. An endpoint outside this list and outside the repos/ tree is not
// classified as safe — it is classified as unknown, which asks.
const NON_REPO_ROOTS = new Set([
  "gists", "orgs", "user", "users", "notifications", "markdown", "meta",
  "rate_limit", "search", "licenses", "gitignore", "emojis", "octocat", "zen",
  "feeds", "events", "teams", "projects", "installation", "app", "apps",
  "scim", "enterprises",
]);

// Commands whose ARGUMENTS are data, not code. `echo $'x'` executes nothing, so
// an ANSI-C span in their argv is inert; the same span in command position, or
// in the argv of anything else, may be the command that runs.
// `gh issue new` is GitHub CLI's own alias for `gh issue create`; the two run
// the same command, so the guard has to read them the same way or the alias is
// a free bypass.
const ISSUE_CREATE_VERBS = new Set(["create", "new"]);

function isIssueCreate(words) {
  return words[0] === "issue" && typeof words[1] === "string" && ISSUE_CREATE_VERBS.has(words[1]);
}

const ANSIC_ARG_INERT_HEADS = new Set([
  "echo", "printf", "cat", "head", "tail", "wc", "sort", "uniq", "tr", "cut",
  "basename", "dirname", "grep", "egrep", "fgrep", "rg", "test", "[",
]);

// The subcommand WORDS of a gh invocation, in order, with global flags skipped
// by the shared resolver rather than by a private copy of its rules.
function ghSubWords(ghArgv) {
  const words = [];
  let argv = Array.isArray(ghArgv) ? ghArgv : [];
  for (let n = 0; n < MAX_SUB_WORDS && argv.length > 0; n++) {
    const rest = resolveGhSubArgv(argv);
    if (!Array.isArray(rest) || rest.length === 0) break;
    words.push(rest[0]);
    argv = rest.slice(1);
  }
  return words;
}

function stripScheme(endpoint) {
  const scheme = endpoint.match(/^[A-Za-z][A-Za-z0-9+.-]*:\/\//);
  if (!scheme) return { rest: endpoint, hadScheme: false };
  const rest = endpoint.slice(scheme[0].length);
  const slash = rest.indexOf("/");
  const host = (slash < 0 ? rest : rest.slice(0, slash)).toLowerCase();
  if (host !== API_HOST) return null;
  return { rest: slash < 0 ? "" : rest.slice(slash + 1), hadScheme: true };
}

function inScope(target) {
  return { scope: "in", target: target || null };
}

// A GraphQL call is classified by its DOCUMENT, and the document does not have
// to be on the command line: --input, an @file field and a substituted value all
// hand it over out of band. Only a document the guard can read, and can see is
// not a mutation, earns passThrough.
function classifyGraphql(flags, fullText) {
  if (hasInputFlag(flags)) return inScope(null);
  for (const f of flags) {
    if (!f || !PAYLOAD_FIELD_FLAGS.has(f.flag)) continue;
    if (typeof f.value !== "string") return inScope(null);
    const eq = f.value.indexOf("=");
    const value = eq < 0 ? "" : f.value.slice(eq + 1);
    if (value === "" || value[0] === "@") return inScope(null);
    if (typeof f.raw === "string" && /[$`]/.test(f.raw)) return inScope(null);
  }
  return /\bmutation\b/.test(fullText || "") ? inScope(null) : { scope: "out" };
}

// Map one `gh api` endpoint to { scope, target }. The order is fixed and the
// default is "unknown, therefore in scope": a path the guard cannot place is not
// evidence of safety.
function classifyEndpoint(endpoint, flags, fullText) {
  if (typeof endpoint !== "string" || endpoint === "") return inScope(null);
  const stripped = stripScheme(endpoint);
  if (stripped === null) return inScope(null);
  let path = stripped.rest;
  if (!stripped.hadScheme) {
    const first = path.split("/")[0];
    if (first.indexOf(".") !== -1 && !NON_REPO_ROOTS.has(first.toLowerCase())) {
      if (first.toLowerCase() !== API_HOST) return inScope(null);
      path = path.slice(first.length + 1);
    }
  }
  if (path[0] === "/") return inScope(null);
  path = path.split("#")[0].split("?")[0];
  const segs = path.split("/");
  if (segs[0] === "repos") {
    const sub = segs.slice(3);
    const isIssues = sub[0] === "issues" || (sub[0] === "import" && sub[1] === "issues");
    if (!isIssues) return { scope: "out" };
    if (!isValidOwner(segs[1]) || !isValidRepo(segs[2])) return inScope(null);
    return inScope(segs[1] + "/" + segs[2]);
  }
  if (segs[0] === "graphql") return classifyGraphql(flags, fullText);
  if (NON_REPO_ROOTS.has(segs[0].toLowerCase())) return { scope: "out" };
  return inScope(null);
}

// Is this segment itself an in-scope forge write? Returns null when it is not.
function ghScopeOf(effCmd0, effArgv, effArgvRaw, fullText) {
  if (commandBasename(effCmd0) !== "gh") return null;
  const argv = Array.isArray(effArgv) ? effArgv : [];
  const argvRaw = Array.isArray(effArgvRaw) ? effArgvRaw : argv;
  const words = ghSubWords(argv);
  // The verb is confirmed against the shared forge-write vocabulary rather than
  // against a private list. The subcommand words are re-spelled into canonical
  // form first, so a global flag between `gh` and the verb does not defeat the
  // shared regex the way it would on the raw text.
  if (isIssueCreate(words)) {
    // Both spellings of the create verb are in the shared vocabulary itself, so
    // the words go to it exactly as gh received them — no private rewrite here.
    if (isForgeScanTarget("gh " + words.join(" "))) return { kind: "issue-create" };
  }
  if (words[0] !== "api") return null;
  const at = argv.indexOf("api");
  if (at < 0) return null;
  const rest = argv.slice(at + 1);
  const restRaw = argvRaw.slice(at + 1);
  if (!isGhApiWriteArgv(rest)) return null;
  const scan = scanGhApiFlags(rest, restRaw);
  // An endpoint the shell will rewrite before gh sees it cannot be classified as
  // out of scope: the path that runs is not the path on the command line, so the
  // only honest answer is "in scope, target unknown" (fail closed).
  if (typeof scan.endpointRaw === "string" && NON_LITERAL_RE.test(scan.endpointRaw)) {
    return { kind: "api", target: null, endpointScope: "in" };
  }
  const classified = classifyEndpoint(scan.endpoint, scan.flags, fullText);
  if (scan.ambiguous) return { kind: "api", target: null, endpointScope: "in" };
  if (classified.scope === "out") return null;
  return { kind: "api", target: classified.target, endpointScope: "in" };
}

// A gh write hiding in the ARGUMENTS of something else (`xargs gh issue create`,
// a wrapper the peel refused). No target is attributed — the point is only that
// a write may run and the guard cannot say where.
function argvHidesForgeWrite(seg, effCmd0) {
  if (commandBasename(effCmd0) === "gh") return false;
  const argv = Array.isArray(seg && seg.argv) ? seg.argv : [];
  for (let i = 0; i < argv.length; i++) {
    if (commandBasename(argv[i]) !== "gh") continue;
    const rest = argv.slice(i + 1);
    const words = ghSubWords(rest);
    if (isIssueCreate(words)) return true;
    if (words[0] === "api") {
      const at = rest.indexOf("api");
      if (at >= 0 && isGhApiWriteArgv(rest.slice(at + 1))) return true;
    }
  }
  return false;
}

// An ANSI-C span is not the text it looks like: $'\x67h' IS `gh`. In command
// position that means the guard never saw the command at all.
function ansicPositionIssue(seg) {
  if (!seg || typeof seg !== "object") return false;
  const cmd0Raw = typeof seg.cmd0Raw === "string" ? seg.cmd0Raw : seg.cmd0;
  if (hasAnsicSpan(cmd0Raw)) return true;
  if (ANSIC_ARG_INERT_HEADS.has(commandBasename(seg.cmd0))) return false;
  const argvRaw = Array.isArray(seg.argvRaw) ? seg.argvRaw : [];
  for (const tok of argvRaw) if (hasAnsicSpan(tok)) return true;
  for (const r of Array.isArray(seg.redirects) ? seg.redirects : []) {
    if (r && hasAnsicSpan(typeof r.targetRaw === "string" ? r.targetRaw : "")) return true;
  }
  return false;
}

// An interpreter sitting in ARGUMENT position means the real program is chosen
// at runtime by something the guard is not modelling. No wrapper names are
// enumerated here on purpose — the shape is the evidence, not the name.
function unrecognizedWrapperHead(ctx) {
  if (!ctx || ctx.claimed || ctx.argvScanCounted) return false;
  if (ctx.bodyState && ctx.bodyState !== "none") return false;
  const seg = ctx.seg;
  if (!seg || typeof seg !== "object") return false;
  const argv = Array.isArray(seg.argv) ? seg.argv : [];
  const tokens = [seg.cmd0].concat(argv);
  let start = 0;
  while (start < tokens.length && typeof tokens[start] === "string" && ASSIGN_RE.test(tokens[start])) start += 1;
  let hit = false;
  for (let i = start + 1; i < tokens.length; i++) {
    if (typeof tokens[i] !== "string") continue;
    if (interpreterKindOfWord(commandBasename(tokens[i]))) { hit = true; break; }
  }
  if (!hit && commandBasename(tokens[start]) === "env") {
    hit = argv.some((t) => t === "-S" || t === "--split-string" || (typeof t === "string" && t.indexOf("--split-string=") === 0));
  }
  return hit;
}

module.exports = {
  ghSubWords,
  classifyEndpoint,
  ghScopeOf,
  argvHidesForgeWrite,
  ansicPositionIssue,
  unrecognizedWrapperHead,
  NON_REPO_ROOTS,
  ANSIC_ARG_INERT_HEADS,
};
