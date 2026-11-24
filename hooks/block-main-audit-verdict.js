#!/usr/bin/env node
// PreToolUse hook (#2853): an audit verdict is written only by the supervisor-audit subagent.
// The main conversation (no non-empty-string agent_id) is blocked from bin/supervisor-write-audit-verdict
// and from bin/supervisor-write-audit --set-audit-verdict, so it cannot settle its own plan's audit.
// Its exit is the ask-gated WORKFLOW_SUPERVISOR_VERDICT_ACCEPTED sentinel (ARP-EXBG).
// #3144: the one exception is the assigned PM writing the verdict of a pre-confirm run routed to it
// (judgePmWrite audit, S1-2); the pm-review rows of bin/review-rounds are judged the same way (request row
// -> judgeRequestWrite, verdict row -> judgePmWrite pm-review), and the subagent may neither write a
// pm-review row nor the verdict of a pre-confirm run whose route is not the subagent (S2-6).
// An exception is approved only on a strictly parsed single call; anything else blocks.
// Unreadable stdin and broken JSON block (fail-closed); other tools and other commands pass.

"use strict";

const path = require("path");
const { readHookInput, readFailureReason } = require("./lib/read-stdin");
const { isSubagentCall } = require("./lib/subagent-detect");
const { isCommandTool, isPowerShellTool, commandListOf } = require("./lib/tool-command-text");

const HOOK_NAME = "block-main-audit-verdict";

const BLOCK_MESSAGE =
  "the main conversation cannot write a supervisor audit verdict — verdicts are written only by the " +
  "supervisor-audit subagent. To accept an audit result as the main conversation, use the ask-gated " +
  "WORKFLOW_SUPERVISOR_VERDICT_ACCEPTED sentinel instead.";

// A path segment ending in bin/<name> (either slash), ended by whitespace, a quote, or the line end.
const binRe = (name) => new RegExp("(^|[\\s\"'/\\\\])bin[/\\\\]+" + name + "(?=$|[\\s\"'])");
const VERDICT_CLI_RE = binRe("supervisor-write-audit-verdict");
const AUDIT_CLI_RE = binRe("supervisor-write-audit");
const REVIEW_ROUNDS_RE = binRe("review-rounds");
const SET_VERDICT_FLAG_RE = /(^|\s)--set-audit-verdict(?=$|[\s=])/;
const PM_REVIEW_FORMAT_RE = /(^|\s)--format(?:\s+|=)["']?pm-review["']?(?=$|\s)/;

function isVerdictWrite(command) {
  if (VERDICT_CLI_RE.test(command)) return true;
  return AUDIT_CLI_RE.test(command) && SET_VERDICT_FLAG_RE.test(command);
}

const W = () => require("./lib/pm-review-writer");

// strictCall(command, name) -> the argv tokens after bin/<name>, or null: one call, optionally through
// node, its path made of plain path characters (or the $AGENTS_MAIN_ROOT root), and no shell
// metacharacter after it, so the tokens read here are the argv the CLI receives.
function strictCall(command, name) {
  const prefix = "(?:\\$AGENTS_MAIN_ROOT|\\$\\{AGENTS_MAIN_ROOT\\}|[A-Za-z0-9_.:/\\\\~-])*";
  const re = new RegExp(`^\\s*(?:node(?:\\.exe)?\\s+)?("?)(${prefix})bin[/\\\\]+${name}\\1(\\s+.*)?$`);
  const m = re.exec(String(command));
  if (!m) return null;
  const rest = m[3] || "";
  if (/[`$;|&<>(){}\r\n\\]/.test(rest)) return null;
  const tokens = [];
  const tok = /"([^"]*)"|'([^']*)'|(\S+)/g;
  let t;
  while ((t = tok.exec(rest)) !== null) tokens.push(t[1] !== undefined ? t[1] : t[2] !== undefined ? t[2] : t[3]);
  return tokens;
}

// flagsOf(tokens, switches) -> {positional, flags} | null: `--name value` pairs (switches take none);
// a repeated flag or a dangling value is not a strict call.
function flagsOf(tokens, switches) {
  const positional = [];
  const flags = {};
  for (let i = 0; i < tokens.length; i++) {
    const m = /^--([a-z-]+)$/.exec(tokens[i]);
    if (!m) {
      if (Object.keys(flags).length > 0) return null;
      positional.push(tokens[i]);
      continue;
    }
    if (Object.prototype.hasOwnProperty.call(flags, m[1])) return null;
    if (switches.has(m[1])) { flags[m[1]] = true; continue; }
    if (i + 1 >= tokens.length) return null;
    flags[m[1]] = tokens[i + 1];
    i += 1;
  }
  return { positional, flags };
}

// The reason a judge refused may name local holders; only its code reaches the block message.
const codeOf = (reason) => String(reason || "").split(":")[0].replace(/[^A-Za-z0-9_-]/g, "") || "refused";

// mainVerdict(command, callerSid) -> null (approve) | reason: the PM exception for the verdict CLI.
function mainVerdict(command, callerSid) {
  const tokens = strictCall(command, "supervisor-write-audit-verdict");
  const p = tokens && flagsOf(tokens, new Set());
  if (!p || p.positional.length > 0) return BLOCK_MESSAGE;
  const targetSid = p.flags["session-id"];
  const runId = p.flags["audit-run-id"];
  if (!targetSid || !runId) return BLOCK_MESSAGE;
  let j;
  try { j = W().judgePmWrite({ callerSid, targetSid, kind: "audit", runId }); } catch (e) { j = { ok: false, reason: `judge-error: ${e.message}` }; }
  return j.ok ? null : `${BLOCK_MESSAGE} (assigned-PM exception refused: ${codeOf(j.reason)})`;
}

const READ_ONLY_SUBCOMMANDS = ["summary", "has-run", "older-input", "interval", "derive-ext"];
const RR_SWITCHES = new Set(["no-park", "request", "high"]);

// pmReview(command, callerSid) -> null (approve) | reason: a pm-review command of bin/review-rounds.
function pmReview(command, callerSid) {
  const refuse = (why) => `[${HOOK_NAME}] the pm-review row is refused: ${why}.`;
  const tokens = strictCall(command, "review-rounds");
  const p = tokens && flagsOf(tokens, RR_SWITCHES);
  if (!p || p.positional.length !== 1) return refuse("not one strictly parsed bin/review-rounds call");
  const sub = p.positional[0];
  if (READ_ONLY_SUBCOMMANDS.includes(sub)) return null;
  if (sub !== "append") return refuse(`${sub} is not a pm-review write`);
  const f = p.flags;
  let j;
  try {
    if (f.request === true) {
      if (!f.pr) return refuse("--request needs --pr");
      j = W().judgeRequestWrite({ callerSid, targetSid: f.session, pmSid: f["pm-sid"], pr: f.pr });
    } else {
      j = W().judgePmWrite({ callerSid, targetSid: f.session, kind: "pm-review", target: { round: f.round, fingerprint: f.fingerprint, pr: f.pr } });
    }
  } catch (e) { j = { ok: false, reason: `judge-error: ${e.message}` }; }
  return j.ok ? null : refuse(codeOf(j.reason));
}

// subagentVerdict(command, inputSid) -> null (approve) | reason: S2-6, the subagent writes a pre-confirm
// run's verdict only while that run's route is the subagent.
function subagentVerdict(command, inputSid) {
  const sm = /(?:^|\s)--session-id(?:\s+|=)(\S+)/.exec(command);
  const sidRaw = sm ? sm[1].replace(/^["']|["']$/g, "") : inputSid;
  if (typeof sidRaw !== "string" || !/^[A-Za-z0-9_-]+$/.test(sidRaw)) return `[${HOOK_NAME}] the audited session id cannot be read, so the verdict write is blocked.`;
  let audit;
  try { audit = (require("./lib/supervisor-state-writer").readState(sidRaw) || {}).audit || null; } catch (e) {
    return `[${HOOK_NAME}] the audit state cannot be read (${codeOf(e.message)}), so the verdict write is blocked.`;
  }
  if (!audit) return null;
  const rm = /(?:^|\s)--audit-run-id(?:\s+|=)["']?(run-[0-9]+)["']?(?=$|\s)/.exec(command);
  const runId = rm ? rm[1] : audit.audit_run_id;
  const entry = Array.isArray(audit.ledger) ? audit.ledger.find((e) => e && e.id === runId) : null;
  const cause = String((entry && entry.cause) || (runId === audit.audit_run_id ? audit.audit_cause || "" : ""));
  if (!cause.startsWith("pre-confirm:")) return null;
  let r;
  try {
    r = require(path.join(__dirname, "..", "bin", "workflow", "lib", "next-step", "pm-audit-route")).routeOf(sidRaw, { runId });
  } catch (e) { r = { route: "ask", reason: codeOf(e.message) }; }
  if (r.route === "subagent") return null;
  return `[${HOOK_NAME}] the pre-confirm run ${runId} is routed to ${r.route === "pm" ? "the assigned PM" : "a destination the user has not chosen yet"}, ` +
    "so the supervisor-audit subagent does not write its verdict.";
}

// judge(raw, input, subagent) -> null (approve) | reason for one command of the call.
function judge(raw, input, subagent) {
  const command = String(raw);
  if (REVIEW_ROUNDS_RE.test(command) && PM_REVIEW_FORMAT_RE.test(command)) {
    if (subagent) return `[${HOOK_NAME}] a subagent never writes or reads pm-review rows through bin/review-rounds.`;
    return pmReview(command, input.session_id);
  }
  if (!isVerdictWrite(command)) return null;
  if (subagent) return subagentVerdict(command, input.session_id);
  return mainVerdict(command, input.session_id);
}

function approve() {
  console.log(JSON.stringify({ decision: "approve" }));
  process.exit(0);
}

function block(reason) {
  console.log(JSON.stringify({ decision: "block", reason }));
  process.exit(0);
}

module.exports = { BLOCK_MESSAGE, isVerdictWrite };

if (require.main === module) {
  const r = readHookInput();
  if (r.kind === "read-error") block(readFailureReason(HOOK_NAME, r.error));
  if (r.kind === "json-invalid") block(`[${HOOK_NAME}] hook input is not valid JSON, so the call is blocked (fail-closed).`);
  const input = r.input || {};

  if (!isCommandTool(input.tool_name) && !isPowerShellTool(input.tool_name)) approve();
  const subagent = isSubagentCall(input);

  for (const raw of commandListOf(input.tool_name, input.tool_input)) {
    let reason;
    try { reason = judge(raw, input, subagent); } catch (e) { reason = `[${HOOK_NAME}] the judgment failed (${codeOf(e.message)}), so the call is blocked (fail-closed).`; }
    if (reason) block(reason);
  }
  approve();
}
