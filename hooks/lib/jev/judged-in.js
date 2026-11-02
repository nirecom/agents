"use strict";
// hooks/lib/jev/judged-in.js — the record's judged_in: where the judgment ran (the hook or the
// CLI that asked Jev), as {kind, name}.

const JUDGED_IN = Object.freeze({
  shadowPre: Object.freeze({ kind: "hook", name: "jev-shadow-pre" }),
  shadowPost: Object.freeze({ kind: "hook", name: "jev-shadow-post" }),
  jevJudge: Object.freeze({ kind: "cli", name: "jev-judge" }),
});
const KINDS = Object.freeze(["hook", "cli"]);
const NAME_RE = /^[a-z0-9-]{1,64}$/;

// A judged_in (file content included) rebuilt from valid values, else fallback (null by default).
function judgedInOr(v, fallback) {
  if (v && typeof v === "object" && KINDS.includes(v.kind) && typeof v.name === "string" && NAME_RE.test(v.name)) {
    return { kind: v.kind, name: v.name };
  }
  return fallback ? { kind: fallback.kind, name: fallback.name } : null;
}

module.exports = { JUDGED_IN, judgedInOr };
