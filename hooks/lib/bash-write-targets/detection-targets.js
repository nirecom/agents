"use strict";
// hooks/lib/bash-write-targets/detection-targets.js
// Detection-side write-target collector (#2434 D7a): the raw words a command writes, deletes or
// renames away, left unexpanded for expandForDetection. Unlike collectWriteTargetsFromSegments it
// never fails closed on an unresolvable word, and it adds touch/rm/rmdir/unlink/ln and rename sources.
const { resolveEffectiveCommand, resolveEffectiveArgv } = require("../bash-write-patterns/segment-utils");
const cpMv = require("./cp-mv");
const pwsh = require("./pwsh");

const { cpMvOperands } = cpMv;
const { pwshOperands, PWSH_SINGLE_TARGET_CMDLETS, PWSH_DEST_SECOND_CMDLETS, PWSH_RENAME_CMDLETS } = pwsh;

const ALL_OPERAND_VERBS = new Set(["tee", "touch", "rm", "rmdir", "unlink", "shred", "truncate"]);
const READ_REDIRECT_OPS = new Set(["<", "<<", "<<<", "<&"]);

function redirectTargets(seg, out) {
  for (const r of seg.redirects || []) {
    if (!r || READ_REDIRECT_OPS.has(r.op)) continue;
    const raw = typeof r.targetRaw === "string" ? r.targetRaw : r.target;
    if (!raw || /^&\d*-?$/.test(raw) || raw === "/dev/null") continue;
    out.push(raw);
  }
}

// Rename sources come only from extractRenameSources (CPR-SSOT). When it cannot read the segment,
// every operand word and every -Name:value inline value is treated as a candidate (fail closed).
function pushRenameSources(sources, argv, out) {
  if (sources !== null) {
    for (const s of sources) out.push(s);
    return;
  }
  for (const t of argv) {
    if (!t.startsWith("-")) out.push(t);
    else if (t.includes(":")) out.push(t.slice(t.indexOf(":") + 1));
  }
}

function posixTargets(seg, cmd, argv, out) {
  if (ALL_OPERAND_VERBS.has(cmd)) {
    let options = true;
    for (const t of argv) {
      if (options && t === "--") { options = false; continue; }
      if (options && t.startsWith("-")) continue;
      out.push(t);
    }
    return;
  }
  if (cmd !== "cp" && cmd !== "mv" && cmd !== "ln") return;
  const { targetDir, positionals } = cpMvOperands(argv);
  if (targetDir !== null) out.push(targetDir);
  else if (positionals.length >= 2) out.push(positionals[positionals.length - 1]);
  if (cmd === "mv") pushRenameSources(cpMv.extractRenameSources(seg), argv, out);
}

function pwshTargets(seg, cmdlet, argv, out) {
  const { named, positionals } = pwshOperands(argv);
  if (PWSH_SINGLE_TARGET_CMDLETS.has(cmdlet)) {
    const src = named["-path"] || named["-literalpath"] || named["-filepath"] || positionals[0];
    if (src) out.push(src);
    return;
  }
  if (PWSH_DEST_SECOND_CMDLETS.has(cmdlet)) {
    const dest = named["-destination"] || named["-target"] || positionals[named["-path"] || named["-literalpath"] ? 0 : 1];
    if (dest) out.push(dest);
  }
  if (PWSH_RENAME_CMDLETS.has(cmdlet)) pushRenameSources(pwsh.extractRenameSources(seg), argv, out);
}

function collectDetectionTargets(segments) {
  const out = [];
  for (const seg of segments || []) {
    if (!seg) continue;
    redirectTargets(seg, out);
    const eff = resolveEffectiveCommand(seg);
    if (eff == null) continue;
    const argv = resolveEffectiveArgv(seg);
    const lower = eff.toLowerCase();
    if (PWSH_SINGLE_TARGET_CMDLETS.has(lower) || PWSH_DEST_SECOND_CMDLETS.has(lower) || PWSH_RENAME_CMDLETS.has(lower)) {
      pwshTargets(seg, lower, argv, out);
    } else {
      posixTargets(seg, eff, argv, out);
    }
  }
  return out;
}

module.exports = { collectDetectionTargets };
