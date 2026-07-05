"use strict";
const ASSIGN_RE = /^[A-Za-z_][A-Za-z0-9_]*=/;

function resolveEffectiveCommand(seg) {
  if (!seg || seg.cmd0 == null) return null;
  if (!ASSIGN_RE.test(seg.cmd0)) return seg.cmd0;
  if (!Array.isArray(seg.argv)) return null;
  const idx = seg.argv.findIndex((a) => !ASSIGN_RE.test(a));
  return idx === -1 ? null : seg.argv[idx];
}

function resolveEffectiveArgv(seg) {
  if (!seg || !Array.isArray(seg.argv)) return [];
  if (seg.cmd0 == null) return [];
  if (!ASSIGN_RE.test(seg.cmd0)) return seg.argv.slice();
  const idx = seg.argv.findIndex((a) => !ASSIGN_RE.test(a));
  return idx === -1 ? [] : seg.argv.slice(idx + 1);
}

module.exports = { resolveEffectiveCommand, resolveEffectiveArgv };
