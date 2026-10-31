"use strict";
// Fixture for tests/hooks/feature-2631-edit-size-hook*.js: a git fixture repo used as both
// CLAUDE_PROJECT_DIR and input.cwd, config roots whose .env pins the comment-block knobs, a
// started session, and a runner for hooks/block-post-edit-size.js. The caller runs isolate() first.

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const { gitInit } = require("../../lib/harness");
const F = require("../feature-2631-size-limits/fixture");

const HOOK = path.join(F.ROOT, "hooks", "block-post-edit-size.js");
const BASE_ENV = ["COMMENT_BLOCK_MAX_LINES=10", "CODE_FILE_EXTENSIONS=js;sh;py"];

let ctx = null;
function setup() {
  const work = F.work();
  const repo = path.join(work, "repo");
  fs.mkdirSync(repo, { recursive: true });
  gitInit(repo);
  const noTranscripts = path.join(work, "no-transcripts");
  fs.mkdirSync(noTranscripts, { recursive: true });
  const cfgOn = F.configRoot("edit-on", ["COMMENT_BLOCK_ENFORCE=on"].concat(BASE_ENV));
  const cfgOff = F.configRoot("edit-cb-off", ["COMMENT_BLOCK_ENFORCE=off"].concat(BASE_ENV));
  const sid = F.newSid();
  F.writeStartedState(sid);
  F.startedSanity(sid);
  ctx = { work, repo, noTranscripts, cfgOn, cfgOff, sid };
  return ctx;
}

function repoPath(rel) { return path.join(ctx.repo, rel); }
function planPath(sid, leaf) { return path.join(process.env.WORKFLOW_PLANS_DIR, `${sid}-${leaf}.md`); }
function put(abs, text) {
  fs.mkdirSync(path.dirname(abs), { recursive: true });
  fs.writeFileSync(abs, text);
  return abs;
}
// bigLines(n) — n code lines of ~1700 chars each: over MAX_BYTES (1 MB) at n >= 600.
function bigLines(n) {
  const pad = "x".repeat(1680);
  let s = "";
  for (let i = 1; i <= n; i++) s += `const b${i} = "${pad}";\n`;
  return s;
}
// commentRun(n) — a code file opening with an n-line comment run.
function commentRun(n) {
  let s = "";
  for (let i = 1; i <= n; i++) s += `// note ${i}\n`;
  return s;
}

// hook(toolName, toolInput, opts) -> { out, decision, reason, ctx, raw }
// opts.sid: null drops session_id; opts.cfg overrides the config root; opts.hookPath runs another
// copy of the hook; opts.command runs a registered command line through the shell instead.
function hook(toolName, toolInput, opts) {
  const o = opts || {};
  const input = { tool_name: toolName, tool_input: toolInput, cwd: ctx.repo, hook_event_name: "PreToolUse" };
  const sid = o.sid === undefined ? ctx.sid : o.sid;
  if (sid) input.session_id = sid;
  const env = Object.assign({}, process.env, {
    AGENTS_MAIN_ROOT: o.cfg || ctx.cfgOn,
    CLAUDE_PROJECT_DIR: ctx.repo,
    CLAUDE_TRANSCRIPT_BASE_DIR: ctx.noTranscripts,
  });
  delete env.CLAUDE_CODE_SESSION_ID;
  delete env.COMMENT_BLOCK_ENFORCE;
  delete env.COMMENT_BLOCK_MAX_LINES;
  delete env.CODE_FILE_EXTENSIONS;
  const so = { input: JSON.stringify(input), encoding: "utf8", timeout: 60000, env, cwd: ctx.work };
  const r = o.command ? spawnSync(o.command, Object.assign({ shell: true }, so)) : spawnSync(process.execPath, [o.hookPath || HOOK], so);
  const raw = `rc=${r.status} out=${r.stdout} err=${r.stderr}`;
  let out = null;
  try { out = JSON.parse(String(r.stdout || "").trim().split("\n").pop()); } catch (_) { out = null; }
  const hso = (out && out.hookSpecificOutput) || {};
  return {
    out, raw,
    decision: out ? out.decision : undefined,
    reason: String((out && out.reason) || ""),
    ctx: String(hso.additionalContext || ""),
  };
}

// Assertion helpers. Every approve needs an explicit "approve": a missing hook prints nothing.
function approves(name, r) { F.check(name, r.decision === "approve", r.raw); }
function blocks(name, r, needles) {
  const miss = (needles || []).filter((n) => !r.reason.includes(String(n)));
  F.check(name, r.decision === "block" && miss.length === 0, `missing ${JSON.stringify(miss)} in ${r.raw}`);
}
function advises(name, r, needles) {
  const miss = (needles || []).filter((n) => !r.ctx.includes(String(n)));
  F.check(name, r.decision === "approve" && /WARN/i.test(r.ctx) && miss.length === 0, `missing ${JSON.stringify(miss)} in ${r.raw}`);
}
function silent(name, r) { F.check(name, r.decision === "approve" && !/WARN/i.test(r.ctx), r.raw); }

module.exports = { F, HOOK, setup, repoPath, planPath, put, bigLines, commentRun, hook, approves, blocks, advises, silent, get ctx() { return ctx; } };
