#!/usr/bin/env node
// tests/feature-2134-bash-guard/judge-probe.js
// One-line stdout probe over the bash-guard modules, used by every cases-*.sh here.
// Usage: node judge-probe.js <mode> <cmd-file> [sessionId] [toolName]
// Env (all optional): BG_PROBE_TOOL_CWD_JSON / BG_PROBE_INPUT_CWD_JSON put a JSON value at
// tool_input.cwd / input.cwd (JSON so a number or object reaches readCwd() as-is);
// BG_PROBE_CTX_CWD_JSON is ctx.cwd for the in-process self-script / notify-hits modes;
// BG_PROBE_AGENTS_ROOT is the fixture agents root handed to matchSelfScript's options.
"use strict";

// Command text arrives in a FILE, never argv: quotes, backticks, `$(...)`, heredoc bodies
// and newlines must reach the module byte-for-byte. tryRequire() returns null for an absent
// module and the probe prints `<MISSING:...>` (a throw prints `<THREW:...>`), so a
// test-first target fails RED naming the artifact instead of crashing the suite.

const fs = require("fs");
const path = require("path");

const AGENTS = path.resolve(__dirname, "..", "..", "..");

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

let commandText = "";
if (cmdFile && cmdFile !== "-") {
  try {
    commandText = fs.readFileSync(cmdFile, "utf8");
  } catch (_e) {
    out("<MISSING:cmd-file " + cmdFile + ">");
  }
}
commandText = commandText.replace(/\n$/, "");

function envJson(name) {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return { set: false };
  return { set: true, value: JSON.parse(raw) };
}

const guardEntry = () => tryRequire("hooks/bash-guard.js");
const judgeMod = () => tryRequire("hooks/bash-guard/judge.js");
const detectMod = () => tryRequire("hooks/bash-guard/detect.js");
const allowMod = () => tryRequire("hooks/bash-guard/allow.js");
const literalsMod = () => tryRequire("hooks/bash-guard/forbidden-literals.js");
const reasonsMod = () => tryRequire("hooks/bash-guard/reasons.js");
const gateMod = () => tryRequire("hooks/lib/early-write-gate.js");
const irMod = () => tryRequire("hooks/lib/command-ir.js");

function judgeInput() {
  const toolInput = { command: commandText };
  const toolCwd = envJson("BG_PROBE_TOOL_CWD_JSON");
  if (toolCwd.set) toolInput.cwd = toolCwd.value;
  const input = { tool_name: toolName, session_id: sessionId, tool_input: toolInput };
  const inputCwd = envJson("BG_PROBE_INPUT_CWD_JSON");
  if (inputCwd.set) input.cwd = inputCwd.value;
  return input;
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
  const ctxCwd = envJson("BG_PROBE_CTX_CWD_JSON");
  return { ir: parsed, analysis, commandText, cwd: ctxCwd.set ? ctxCwd.value : null };
}

// xargs-pipe now lives inside detect() (#2264 Step 3), so detect() alone is the surviving set.
function detectedHits() {
  const d = detectMod();
  const ctx = buildCtx();
  if (!d || !ctx || typeof d.detect !== "function") return null;
  return d.detect(ctx.ir);
}

function idsOf(hits) {
  return Array.from(new Set(hits.map((h) => String(h && h.literalId)))).sort().join(",");
}

function sortedValues(obj) {
  return Object.keys(obj || {}).map((k) => k + "=" + obj[k]).sort().join(",");
}

try {
  switch (mode) {
    // verdict \t code \t literalId|notifyId. The 4-value verdict is allow|deny|notify|passThrough.
    case "judge": {
      const m = judgeMod();
      if (!m || typeof m.judgeBashCommand !== "function") sentinel();
      const v = m.judgeBashCommand(judgeInput());
      const id = v && (v.literalId != null ? v.literalId : v.notifyId);
      out([v && v.verdict, v && v.code, id].map((x) => (x == null ? "-" : x)).join("\t"));
      break;
    }
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

    // Fail-open under hostile input: neither shape may produce a deny, AND neither may produce
    // an allow -- allow bypasses the permission prompt, so an exception must land on passThrough.
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
    // A throwing cwd getter reached AFTER parse succeeds: the catch must still land on passThrough.
    case "judge-throwing-cwd": {
      const m = judgeMod();
      if (!m || typeof m.judgeBashCommand !== "function") sentinel();
      const toolInput = { command: commandText };
      Object.defineProperty(toolInput, "cwd", { get() { throw new Error("hostile cwd"); }, enumerable: true });
      let v;
      try {
        v = m.judgeBashCommand({ tool_name: "Bash", session_id: sessionId, tool_input: toolInput });
      } catch (e) {
        out("<THREW:" + (e && e.message ? e.message : String(e)) + ">");
      }
      out(String(v && v.verdict));
      break;
    }

    case "raw-hits":
    case "hits": {
      const hits = detectedHits();
      if (hits === null) sentinel();
      out(hits.map(hitKey).join(","));
      break;
    }
    case "hit-ids": {
      const hits = detectedHits();
      if (hits === null) sentinel();
      out(idsOf(hits));
      break;
    }

    // detectIneffective(ir, ctx) -> sorted notifyId list; the hit shape is also checked so a
    // sample carrying command text fails here rather than leaking into a transcript.
    case "notify-hits": {
      const d = detectMod();
      const ctx = buildCtx();
      if (!d || !ctx || typeof d.detectIneffective !== "function") {
        if (d && typeof d.detectIneffective !== "function") missing.push("detect.js#detectIneffective");
        sentinel();
      }
      const hits = d.detectIneffective(ctx.ir, ctx) || [];
      const bad = hits.filter((h) => !h || h.sample != null || !h.at || h.at.kind !== "segment");
      if (bad.length > 0) out("<BAD-HIT-SHAPE:" + JSON.stringify(bad) + ">");
      out(Array.from(new Set(hits.map((h) => String(h.notifyId)))).sort().join(","));
      break;
    }

    // matchSelfScript(ir, ctx, {root}) -> the ALLOW code, or "null".
    case "self-script": {
      const a = allowMod();
      const ctx = buildCtx();
      if (!a || !ctx || typeof a.matchSelfScript !== "function") sentinel();
      const root = process.env.BG_PROBE_AGENTS_ROOT || undefined;
      const r = a.matchSelfScript(ctx.ir, ctx, root ? { root } : undefined);
      out(r == null ? "null" : typeof r === "object" ? String(r.code) : String(r));
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
    // KEY=VALUE pairs of the three non-deny registries, sorted; "<ABSENT>" when not exported.
    case "pass-through-codes":
    case "notify-codes":
    case "allow-codes": {
      const m = reasonsMod();
      if (!m) sentinel();
      const key = { "pass-through-codes": "PASS_THROUGH_CODES", "notify-codes": "NOTIFY_CODES", "allow-codes": "ALLOW_CODES" }[mode];
      const reg = m[key];
      if (!reg || typeof reg !== "object") out("<ABSENT:" + key + ">");
      out((Object.isFrozen(reg) ? "" : "<NOT-FROZEN>") + sortedValues(reg));
      break;
    }

    case "gate": {
      const m = gateMod();
      if (!m || typeof m.earlyWriteGateStatus !== "function") sentinel();
      const s = m.earlyWriteGateStatus(sessionId);
      out([s && s.active, (s && s.pendingTier) || "-", (s && s.inactiveReason) || "-"].join("\t"));
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

    // The exact stdout hooks/bash-guard.js writes for judgeInput(), newlines escaped; the
    // envelope builder is not exported, so the real entrypoint is spawned. passThrough -> "".
    case "allow-envelope-stdout": {
      const hook = path.join(AGENTS, "hooks", "bash-guard.js");
      if (!fs.existsSync(hook)) out("<MISSING:hooks/bash-guard.js>");
      const r = require("child_process").spawnSync(process.execPath, [hook], {
        input: JSON.stringify(judgeInput()), encoding: "utf8", timeout: 20000,
      });
      if (r.error) threw(r.error);
      out(String(r.stdout || "").replace(/\n$/, "").replace(/\n/g, "\\n"));
      break;
    }

    default:
      out("<BAD-MODE:" + String(mode) + ">");
  }
} catch (e) {
  threw(e);
}
