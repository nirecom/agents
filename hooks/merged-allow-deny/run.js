"use strict";
// hooks/merged-allow-deny/run.js — runMembers(): read the hook input once, run each member's
// judge, merge, print. Shared by hooks/merged-allow-deny.js and the five single-member entries,
// so a member answers the same whether it runs alone or merged.

const fs = require("fs");
const { readHookInput, readFailureReason, readFailOpenDiagnostic } = require("../lib/read-stdin");
const { GROUPS, memberByName } = require("./members");
const { mergeResults } = require("./merge");

function writeStderr(line) {
  try { fs.writeSync(2, line + "\n"); } catch (_e) { /* diagnostics are best effort */ }
}

function loadEnvOnce() {
  try {
    require("../lib/load-env").loadDefaultEnv();
  } catch (_e) {
    /* fail-open: proceed with whatever process.env already has */
  }
}

// With a matcher group, an unreadable input could be any of the group's tools, so only the
// members that judge every tool of the group answer for it.
function failureMembers(members, matcherGroup) {
  const groupTools = matcherGroup && Object.prototype.hasOwnProperty.call(GROUPS, matcherGroup) ? GROUPS[matcherGroup] : null;
  if (!groupTools) return members;
  return members.filter((member) => groupTools.every((tool) => member.tools.includes(tool)));
}

function failureResults(members, read, entryName, matcherGroup) {
  const answering = failureMembers(members, matcherGroup);
  if (answering.some((member) => member.diagnose.includes(read.kind))) {
    writeStderr(readFailOpenDiagnostic(entryName, read, "check skipped"));
  }
  return answering.map((member) => {
    switch (member.failure[read.kind]) {
      case "deny": return { decision: "deny", reason: readFailureReason(entryName, read.error) };
      case "approve": return { decision: "approve" };
      case "omit": return { decision: "none", omitOutput: true };
      default: return { decision: "none" };
    }
  });
}

function judgeOne(member, input) {
  try {
    return member.judge(input);
  } catch (error) {
    const detail = (error && error.message) || String(error);
    writeStderr(`[${member.name}] judge threw: ${detail}`);
    if (!member.failClosed) return { decision: "none" };
    return { decision: "ask", reason: `${member.name}: the check failed (${detail}); asking instead of deciding` };
  }
}

function judgeResults(members, input, routeByTool) {
  const toolName = input && typeof input === "object" ? input.tool_name : undefined;
  const results = [];
  for (const member of members) {
    if (routeByTool && !member.tools.includes(toolName)) continue;
    const result = judgeOne(member, input);
    results.push(result);
    if (result && result.decision === "deny") break;
  }
  return results;
}

/**
 * @param {string[]} names member names, in judging order
 * @param {{entryName?: string, matcherGroup?: string, routeByTool?: boolean}} [opts]
 *   routeByTool: judge only the members whose tools include tool_name (the merged hook); a
 *   single-member entry judges whatever it is given, as it did before the merge.
 */
function runMembers(names, opts = {}) {
  const members = names.map(memberByName);
  const entryName = opts.entryName || members[0].name;
  if (members.some((member) => member.needsEnv)) loadEnvOnce();
  const read = readHookInput();
  const results = read.kind === "ok"
    ? judgeResults(members, read.input, opts.routeByTool === true)
    : failureResults(members, read, entryName, opts.matcherGroup);
  const out = mergeResults(results);
  if (out) process.stdout.write(JSON.stringify(out) + "\n");
}

module.exports = { runMembers, failureMembers };
