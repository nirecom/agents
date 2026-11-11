"use strict";
// stdin/stdout driver for protect-user-block: splits every command line into segments, turns each
// gh issue write into operation descriptors, asks bin/user-block-guard about each, and writes one
// decision (deny > ask > none). A write whose target cannot be read never reaches the CLI: it
// denies when it changes a title and asks otherwise.
const fs = require("fs");
const { isCommandTool, commandListOf } = require("../lib/tool-command-text");
const { parse } = require("../lib/command-ir");
const { tokenizeSegmentWithQuotes, REDIRECT_RE, ATTACHED_REDIRECT_RE } = require("../lib/command-parser");
const { resolveEffectiveSegment, ASSIGN_RE } = require("../lib/command-ir/effective");
const { commandBasename } = require("../lib/bash-write-patterns/segment-utils");
const { spanAwareNewlineSplit } = require("../lib/quote-spans");
const { readHookInput, readFailOpenDiagnostic } = require("../lib/read-stdin");
const { armDecisionTimeLimit } = require("../lib/decision-time-limit");
const out = require("../lib/permission-decision-output");
const { extractIssue } = require("./extract");
const { extractApi } = require("./extract-api");
const { callGuard } = require("./call-guard");

const HOOK = "protect-user-block";
const DIR_CHANGERS = new Set(["cd", "pushd", "popd"]);

function touches(text) {
  if (!/\bgh\b/.test(text)) return false;
  return /\bissue\s+(create|new|edit|comment|delete)\b/.test(text) || /\bapi\b[\s\S]*(issues|graphql)/.test(text);
}

function changesTitle(text) {
  return /\bissue\s+edit\b[\s\S]*\s(-t\S*|--title)([\s=]|$)/.test(text) ||
    (/\bapi\b/.test(text) && /(^|[\s'"])title=/.test(text) && /\bPATCH\b/i.test(text)) ||
    /\bupdateIssue\s*\(/.test(text);
}

function unresolvedItem(text, why) {
  const decision = changesTitle(text) ? "deny" : "ask";
  return { decide: decision, reason: `${HOOK}: the target of this issue write cannot be read (${why}), so its <user> block cannot be checked` };
}

// command-ir reads a quoted `"<user>…"` value as a `<` redirect and drops it from argv; rebuild
// argv from the raw text, treating only UNQUOTED operator tokens as redirects.
function quoteAwareSegment(seg) {
  let toks;
  try { toks = tokenizeSegmentWithQuotes(seg.rawText || ""); } catch (_e) { return seg; }
  const argv = [];
  const argvRaw = [];
  for (let i = 0; i < toks.length; i++) {
    const { value, raw } = toks[i];
    const unquoted = typeof raw === "string" && !/^['"]/.test(raw);
    if (unquoted && REDIRECT_RE.test(value)) { i += 1; continue; }
    if (unquoted && ATTACHED_REDIRECT_RE.test(value) && !/^[<>0-9&]*['"]/.test(raw)) continue;
    argv.push(value);
    argvRaw.push(raw);
  }
  if (argv.length === 0) return seg;
  return Object.assign({}, seg, { cmd0: argv[0], cmd0Raw: argvRaw[0], argv: argv.slice(1), argvRaw: argvRaw.slice(1) });
}

// The GH_REPO=... prefix written on the segment itself, raw spelling kept.
function ghRepoPrefix(seg) {
  const toks = [seg.cmd0].concat(seg.argv || []);
  const raws = [seg.cmd0Raw].concat(seg.argvRaw || []);
  let found = null;
  for (let i = 0; i < toks.length && typeof toks[i] === "string" && ASSIGN_RE.test(toks[i]); i++) {
    if (toks[i].indexOf("GH_REPO=") === 0) found = { value: toks[i].slice(8), raw: raws[i] };
  }
  return found;
}

function itemsOfLine(line, cwd) {
  const items = [];
  let ir = null;
  try { ir = parse(line); } catch (_e) { ir = null; }
  if (!ir || ir.parseFailure || !Array.isArray(ir.segments)) {
    return touches(line) ? [unresolvedItem(line, "the command line cannot be parsed")] : items;
  }
  let dirChanged = false;
  for (const parsed of ir.segments) {
    const seg = parsed.redirects && parsed.redirects.length ? quoteAwareSegment(parsed) : parsed;
    const eff = resolveEffectiveSegment(seg);
    const base = eff ? commandBasename(eff.cmd0) : null;
    const text = seg.rawText || "";
    if (base === "gh") {
      if (!touches(text)) continue;
      if (dirChanged) { items.push(unresolvedItem(text, "an earlier command changes the directory")); continue; }
      const argv = eff.argv || [];
      const argvRaw = eff.argvRaw || argv;
      const extract = argv[0] === "api" ? extractApi : extractIssue;
      const r = extract(argv, argvRaw, text, ghRepoPrefix(seg), cwd);
      if (r.unresolved) items.push(unresolvedItem(text, r.why));
      else if (r.decide) items.push({ decide: r.decide, reason: `${HOOK}: ${r.why}, so its <user> block cannot be checked` });
      else for (const d of r.descs) items.push({ desc: d });
      continue;
    }
    if (base && DIR_CHANGERS.has(base)) { dirChanged = true; continue; }
    if (base === "glab") continue;
    if (touches(text)) items.push(unresolvedItem(text, "gh runs nested or behind another command"));
  }
  const claimed = ir.segments.some((s) => touches(s.rawText || ""));
  if (!claimed && touches(line)) items.push(unresolvedItem(line, "gh runs behind a substitution"));
  return items;
}

function decide(input) {
  if (!input || typeof input !== "object" || !isCommandTool(input.tool_name)) return out.none();
  const ti = input.tool_input || {};
  const cwd = typeof input.cwd === "string" ? input.cwd : (typeof ti.cwd === "string" ? ti.cwd : null);
  const asks = [];
  for (const command of commandListOf(input.tool_name, ti)) {
    for (const line of spanAwareNewlineSplit(command).lines) {
      for (const item of itemsOfLine(line, cwd)) {
        const v = item.desc ? callGuard(item.desc, cwd) : { decision: item.decide, reason: item.reason };
        if (v.decision === "deny") return out.deny(v.reason);
        if (v.decision === "ask") asks.push(v.reason);
      }
    }
  }
  return asks.length ? out.ask(asks.join("; ")) : out.none();
}

function main() {
  const r = readHookInput();
  armDecisionTimeLimit({ hookName: HOOK });
  let result;
  if (r.kind !== "ok") {
    try { fs.writeSync(2, readFailOpenDiagnostic(HOOK, r, "check skipped") + "\n"); } catch (_e) { /* diagnostic only */ }
    result = out.none();
  } else {
    try { result = decide(r.input); } catch (e) {
      result = out.deny(`${HOOK}: the guard could not evaluate this command (${e && e.message})`);
    }
  }
  process.stdout.write(JSON.stringify(result));
}

module.exports = { main, itemsOfLine, touches, changesTitle };
