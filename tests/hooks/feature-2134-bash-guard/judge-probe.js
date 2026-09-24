#!/usr/bin/env node
// tests/feature-2134-bash-guard/judge-probe.js
// One-line stdout probe over the bash-guard modules, used by every cases-*.sh here.
// Usage: node judge-probe.js <mode> <cmd-file> [sessionId] [toolName] [settingsPath]
"use strict";

// Command text arrives in a FILE, never argv: quotes, backticks, `$(...)`, heredoc
// bodies and newlines must reach the module byte-for-byte, and a shell argument
// would rewrite the very literals under test.

// Targets are written test-first, so tryRequire() returns null for an absent module
// and the probe prints `<MISSING:...>` (a throw prints `<THREW:...>`). Both land on
// assert_eq's `got` side: the suite fails RED naming the artifact instead of
// crashing and taking the remaining rows with it.

const fs = require("fs");
const path = require("path");

const AGENTS = path.resolve(__dirname, "..", "..");

const missing = [];
function tryRequire(rel) {
  try {
    return require(path.join(AGENTS, rel));
  } catch (e) {
    const head = e && e.message ? String(e.message).split("\n")[0] : String(e);
    missing.push(e && e.code === "MODULE_NOT_FOUND" ? rel : rel + "!" + head);
    return null;
  }
}

function out(s) {
  process.stdout.write(String(s) + "\n");
  process.exit(0);
}
function sentinel() {
  out("<MISSING:" + missing.join(";") + ">");
}
function threw(e) {
  out("<THREW:" + (e && e.message ? String(e.message).split("\n")[0] : String(e)) + ">");
}

const mode = process.argv[2];
const cmdFile = process.argv[3];
const sessionId = process.argv[4] || "sid-bg-armed";
const toolName = process.argv[5] || "Bash";
const settingsPath = process.argv[6] || null;

let commandText = "";
if (cmdFile && cmdFile !== "-") {
  try {
    commandText = fs.readFileSync(cmdFile, "utf8");
  } catch (_e) {
    out("<MISSING:cmd-file " + cmdFile + ">");
  }
}
// The writer appends no trailing newline; strip one defensively so an
// editor-added newline cannot re-shape a `cat <<EOF` case.
commandText = commandText.replace(/\n$/, "");

const guardEntry = () => tryRequire("hooks/bash-guard.js");
const judgeMod = () => tryRequire("hooks/bash-guard/judge.js");
const detectMod = () => tryRequire("hooks/bash-guard/detect.js");
const exemptMod = () => tryRequire("hooks/bash-guard/exemptions.js");
const literalsMod = () => tryRequire("hooks/bash-guard/forbidden-literals.js");
const reasonsMod = () => tryRequire("hooks/bash-guard/reasons.js");
const gateMod = () => tryRequire("hooks/lib/early-write-gate.js");
const allowMod = () => tryRequire("hooks/lib/settings-allow-match.js");
const irMod = () => tryRequire("hooks/lib/command-ir.js");

function judgeInput() {
  return { tool_name: toolName, session_id: sessionId, tool_input: { command: commandText } };
}

function hitKey(h) {
  const at = (h && h.at) || {};
  return String(h && h.literalId) + "@" + String(at.kind) + ":" + String(at.index);
}

function literalList(m) {
  if (!m) return null;
  const list = Array.isArray(m.FORBIDDEN_LITERALS) ? m.FORBIDDEN_LITERALS : m;
  return Array.isArray(list) ? list : null;
}

function buildCtx() {
  const ir = irMod();
  if (!ir || typeof ir.parse !== "function") return null;
  const parsed = ir.parse(commandText);
  const analysis = typeof ir.analysisOf === "function" ? ir.analysisOf(parsed) : null;
  return { ir: parsed, analysis, commandText };
}

function remainingHits(exemptions) {
  const d = detectMod();
  const x = exemptMod();
  const ctx = buildCtx();
  if (!d || !x || !ctx || typeof d.detect !== "function" || typeof x.applyExemptions !== "function") return null;
  const hits = d.detect(ctx.ir);
  return exemptions ? x.applyExemptions(hits, ctx, exemptions) : x.applyExemptions(hits, ctx);
}

function idsOf(hits) {
  return Array.from(new Set(hits.map((h) => String(h && h.literalId)))).sort().join(",");
}

try {
  switch (mode) {
    case "judge": {
      const m = judgeMod();
      if (!m || typeof m.judgeBashCommand !== "function") sentinel();
      const v = m.judgeBashCommand(judgeInput());
      out([v && v.verdict, v && v.code, v && v.literalId].map((x) => (x == null ? "-" : x)).join("\t"));
      break;
    }
    // sample: the deny's reproduced offending-text fragment (not the whole command line).
    // A separate mode from "judge" so cases-detect.sh's D-namespace assertion can read it
    // without re-threading the tab-column layout every other "judge" caller depends on.
    case "judge-sample": {
      const m = judgeMod();
      if (!m || typeof m.judgeBashCommand !== "function") sentinel();
      const v = m.judgeBashCommand(judgeInput());
      out(v && v.sample != null ? String(v.sample) : "");
      break;
    }
    case "judge-message": {
      const m = judgeMod();
      if (!m || typeof m.judgeBashCommand !== "function") sentinel();
      const v = m.judgeBashCommand(judgeInput());
      out(String((v && v.message) || "").replace(/\n/g, "\\n"));
      break;
    }

    // Fail-open under hostile input: a null command, and an input whose `command` getter
    // throws. Neither may produce a deny; a presentation guard that stops work on its own
    // bug is worse than one that misses a case.
    case "judge-null-command":
    case "judge-throwing-input": {
      const m = judgeMod();
      if (!m || typeof m.judgeBashCommand !== "function") sentinel();
      const toolInput = {};
      if (mode === "judge-null-command") toolInput.command = null;
      else Object.defineProperty(toolInput, "command", { get() { throw new Error("hostile getter"); }, enumerable: true });
      let v;
      try {
        v = m.judgeBashCommand({ tool_name: "Bash", session_id: sessionId, tool_input: toolInput });
      } catch (e) {
        out("<THREW:" + (e && e.message ? e.message : String(e)) + ">");
      }
      out(String(v && v.verdict));
      break;
    }

    case "raw-hits": {
      const d = detectMod();
      const ctx = buildCtx();
      if (!d || !ctx || typeof d.detect !== "function") sentinel();
      out(d.detect(ctx.ir).map(hitKey).join(","));
      break;
    }
    case "hits": {
      const rest = remainingHits(null);
      if (rest === null) sentinel();
      out(rest.map(hitKey).join(","));
      break;
    }
    case "hit-ids": {
      const rest = remainingHits(null);
      if (rest === null) sentinel();
      out(idsOf(rest));
      break;
    }

    // Dummy hit-scoped exemption excusing ONLY "pipe": every other hit must stand.
    // Contract: applyExemptions(hits, ctx, exemptions) takes the list as an
    // optional third argument so one exemption can be exercised in isolation.
    case "dummy-exemption": {
      const dummy = [{ id: "dummy-pipe-only", scope: "hit", excuses: ["pipe"], applies: () => true }];
      const rest = remainingHits(dummy);
      if (rest === null) sentinel();
      out(idsOf(rest));
      break;
    }
    case "exemption-ids": {
      const x = exemptMod();
      if (!x || !Array.isArray(x.EXEMPTIONS)) sentinel();
      out(x.EXEMPTIONS.map((e) => e.id + ":" + e.scope).sort().join(","));
      break;
    }

    case "ids": {
      const list = literalList(literalsMod());
      if (!list) sentinel();
      out(list.map((e) => e.id).join(","));
      break;
    }
    case "row-count": {
      const list = literalList(literalsMod());
      if (!list) sentinel();
      out(String(Array.from(new Set(list.map((e) => e.row))).length));
      break;
    }
    // id -> doc-row-index map, read straight off each entry's own `.row` field (not
    // re-derived from "ids" + a guessed fold) so a real generator drift shows up here.
    case "id-row-map": {
      const list = literalList(literalsMod());
      if (!list) sentinel();
      const map = {};
      list.forEach((e) => { map[e.id] = e.row; });
      out(JSON.stringify(map));
      break;
    }
    case "literals-frozen": {
      const list = literalList(literalsMod());
      if (!list) sentinel();
      out(String(Object.isFrozen(list)));
      break;
    }

    case "reason-codes": {
      const m = reasonsMod();
      if (!m) sentinel();
      const codes = Array.isArray(m.REASON_CODES) ? m.REASON_CODES : Object.keys(m.REASONS || {});
      out(codes.slice().sort().join(","));
      break;
    }

    case "gate": {
      const m = gateMod();
      if (!m || typeof m.earlyWriteGateStatus !== "function") sentinel();
      const s = m.earlyWriteGateStatus(sessionId);
      out([s && s.active, (s && s.pendingTier) || "-", (s && s.inactiveReason) || "-"].join("\t"));
      break;
    }

    case "allow-match": {
      const m = allowMod();
      if (!m || typeof m.isAllowRuleMatch !== "function") sentinel();
      out(String(m.isAllowRuleMatch(commandText, settingsPath ? { settingsPath } : undefined)));
      break;
    }

    // Position linkage: xargs-pipe reads separatorLinks because segments[i+1]
    // index arithmetic is wrong for leading/trailing separators.
    case "links": {
      const ir = irMod();
      if (!ir || typeof ir.parse !== "function" || typeof ir.analysisOf !== "function") sentinel();
      const links = ir.analysisOf(ir.parse(commandText)).separatorLinks || [];
      out(links.map((l) => l.index + ":" + l.sep + ":" + (l.leftSegment == null ? "-" : l.leftSegment) +
        ":" + (l.rightSegment == null ? "-" : l.rightSegment)).join(","));
      break;
    }

    // Every PreToolUse matcher whose group runs hooks/bash-guard.js. C4: it must be the
    // bare "Bash" -- runInTerminal / runCommands may drive pwsh, a different dialect.
    case "guard-hook-matchers": {
      let settings;
      try {
        settings = JSON.parse(fs.readFileSync(path.join(AGENTS, "settings.json"), "utf8"));
      } catch (e) {
        out("<MISSING:settings.json>");
      }
      const groups = (settings.hooks && settings.hooks.PreToolUse) || [];
      const hit = groups.filter((g) => JSON.stringify(g.hooks || []).indexOf("bash-guard") !== -1);
      out(hit.length === 0 ? "<NOT-REGISTERED>" : hit.map((g) => g.matcher).join(","));
      break;
    }

    case "entry-shape": {
      const m = guardEntry();
      if (!m) sentinel();
      out(typeof m.judgeBashCommand);
      break;
    }

    default:
      out("<BAD-MODE:" + String(mode) + ">");
  }
} catch (e) {
  threw(e);
}
