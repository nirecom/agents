"use strict";
// hooks/merged-allow-deny/members.js — the members of the merged allow-deny hook (#2676): which
// tools each member judges (its pre-merge settings.json matcher), what it answers when the hook
// input cannot be read, and its judge. Judges are called through their module objects at call
// time, so a patched export is honoured.

const dotenvJudge = require("../block-dotenv/judge");
const credentialsJudge = require("../block-credentials/judge");
const bashGuardJudge = require("../bash-guard/judge");
const captureEchoJudge = require("../block-capture-echo/judge");
const autoApproveJudge = require("../preuse-auto-approve/judge");

const PRIMARY_TOOLS = Object.freeze(["Bash", "Read", "Grep", "Glob", "Edit", "Write", "MultiEdit", "editFiles",
  "runInTerminal", "runCommands", "mcp__codegraph__codegraph_explore"]);

// One settings.json registration per group; the groups do not overlap.
const GROUPS = Object.freeze({
  primary: PRIMARY_TOOLS,
  "monitor-worktree": Object.freeze(["Monitor", "EnterWorktree"]),
});

// bash-guard verdict -> judge result. notify keeps today's approve + extras (b-rejected branch).
// The user sees only `[bash-guard] <code>` (#2731); the explanation goes to the model.
function convLang(text) { return require("../lib/conv-lang").withConvLang(text); }

function judgeBashGuard(input) {
  const verdict = bashGuardJudge.judgeBashCommand(input) || {};
  switch (verdict.verdict) {
    case "deny":
      return { decision: "deny", reason: convLang(verdict.message) };
    case "notify":
      return { decision: "approve", systemMessage: `[bash-guard] ${verdict.code}`, additionalContext: convLang(verdict.message) };
    case "allow":
      return { decision: "allow", reason: "bash-guard " + verdict.code };
    default:
      return { decision: "approve" };
  }
}

// failure: what the member answers per unreadable-input kind ("deny" | "approve" | "none" |
// "omit" = print nothing). diagnose: the kinds on which it writes the one stderr diagnostic.
// failClosed: a judge that throws asks instead of being skipped. needsEnv: load the default .env.
const MEMBERS = Object.freeze([
  {
    name: "block-dotenv", tools: PRIMARY_TOOLS, failClosed: true, needsEnv: false,
    failure: { "read-error": "deny", "json-invalid": "approve" }, diagnose: ["json-invalid"],
    judge: (input) => dotenvJudge.judgeDotenv(input),
  },
  {
    name: "block-credentials", tools: PRIMARY_TOOLS, failClosed: true, needsEnv: false,
    failure: { "read-error": "deny", "json-invalid": "approve" }, diagnose: ["json-invalid"],
    judge: (input) => credentialsJudge.judgeCredentials(input),
  },
  {
    name: "bash-guard", tools: Object.freeze(["Bash"]), failClosed: false, needsEnv: false,
    failure: { "read-error": "deny", "json-invalid": "omit" }, diagnose: ["json-invalid"],
    judge: judgeBashGuard,
  },
  {
    name: "block-capture-echo", tools: Object.freeze(["Bash", "runInTerminal", "runCommands"]), failClosed: false, needsEnv: false,
    failure: { "read-error": "none", "json-invalid": "none" }, diagnose: ["read-error", "json-invalid"],
    judge: (input) => captureEchoJudge.judgeCaptureEcho(input),
  },
  {
    name: "preuse-auto-approve", tools: Object.freeze(["Monitor", "EnterWorktree", "Bash", "runInTerminal", "runCommands"]),
    failClosed: false, needsEnv: true,
    failure: { "read-error": "none", "json-invalid": "none" }, diagnose: [],
    judge: (input) => autoApproveJudge.judgeAutoApprove(input),
  },
]);

function memberByName(name) {
  const member = MEMBERS.find((entry) => entry.name === name);
  if (!member) throw new Error(`merged-allow-deny: unknown member ${name}`);
  return member;
}

module.exports = { GROUPS, MEMBERS, PRIMARY_TOOLS, memberByName, judgeBashGuard };
