"use strict";
// lang-check: ignore — Japanese fixture strings are test data for Japanese term matching.
// T4-1 part of tests/hooks/feat-2529-glossary-accept.js (#2529). Holds no case markers; the
// entrypoint wraps each run function in one.
// patterns(): GLOSSARY_ACCEPTED_RE_DQ / _LOOKSLIKE_RE over a table, and their isSentinel /
// isStrictSentinel registration. format(): what the regex lets through but the handler must
// still refuse as malformed (value outside the domain, duplicate, provenance + stage, short
// reason), the look-alike-only path, and a missing session id.

const cmdOf = (body) => `echo "<<WORKFLOW_GLOSSARY_ACCEPTED${body}>>"`;
const BT = String.fromCharCode(96);

// [label, body after the sentinel name, DQ matches, LOOKSLIKE matches]
const TABLE = [
  ["no discriminator", ": term=glossary drift — user accepted", true, true],
  ["stage only", ": term=glossary drift stage=outline — user accepted", true, true],
  ["op + cat", ": term=glossary drift op=add cat=user — user accepted", true, true],
  ["three discriminators (regex level)", ": term=glossary drift op=add cat=user stage=docs — user accepted", true, true],
  ["Japanese term", ": term=用語揺れ — 上流の表記をそのまま引用", true, true],
  ["four discriminators", ": term=glossary drift op=add cat=user stage=docs op=add — user accepted", false, true],
  ["( in term", ": term=glossary (drift) — user accepted", false, true],
  [") in reason", ": term=glossary drift — user accepted (twice)", false, true],
  ["; in reason", ": term=glossary drift — user; accepted", false, true],
  ["| in reason", ": term=glossary drift — user | accepted", false, true],
  ["& in reason", ": term=glossary drift — user & accepted", false, true],
  ["> in reason", ": term=glossary drift — user > accepted", false, true],
  ["backtick in reason", `: term=glossary drift — user ${BT}accepted${BT}`, false, true],
  ["term= missing", ": glossary drift — user accepted", false, true],
  ["separator missing", ": term=glossary drift user accepted", false, true],
  ["hyphen instead of the em dash", ": term=glossary drift - user accepted", false, true],
  ["undefined discriminator name", ": term=glossary drift foo=bar — user accepted", false, true],
  ["bare name", "", false, true],
];

function patterns(F) {
  const P = F.mod("hooks/lib/sentinel-patterns.js") || {};
  const dq = P.GLOSSARY_ACCEPTED_RE_DQ;
  const look = P.GLOSSARY_ACCEPTED_LOOKSLIKE_RE;
  F.check("T4-1 GLOSSARY_ACCEPTED_RE_DQ is exported", dq instanceof RegExp, typeof dq);
  F.check("T4-1 GLOSSARY_ACCEPTED_LOOKSLIKE_RE is exported", look instanceof RegExp, typeof look);
  for (const [label, body, wantDq, wantLook] of TABLE) {
    const cmd = cmdOf(body);
    const gotDq = dq instanceof RegExp && dq.test(cmd);
    const gotLook = look instanceof RegExp && look.test(cmd);
    F.check(`T4-1 ${label}: DQ ${wantDq ? "matches" : "does not match"}`, dq instanceof RegExp && gotDq === wantDq, cmd);
    F.check(`T4-1 ${label}: LOOKSLIKE ${wantLook ? "matches" : "does not match"}`, look instanceof RegExp && gotLook === wantLook, cmd);
    F.check(`T4-1 ${label}: isSentinel is true`, typeof P.isSentinel === "function" && P.isSentinel(cmd) === true, cmd);
    F.check(`T4-1 ${label}: isStrictSentinel is ${wantDq}`,
      typeof P.isStrictSentinel === "function" && P.isStrictSentinel(cmd) === wantDq && (wantDq || P.isSentinel(cmd)), cmd);
  }
  if (dq instanceof RegExp) {
    const m = dq.exec(cmdOf(": term=glossary drift op=add cat=user — user accepted"));
    F.check("T4-1 DQ groups: term / discriminator run / reason",
      !!m && m[1] === "glossary drift" && m[2] === " op=add cat=user" && m[3] === "user accepted", JSON.stringify(m));
  }
  const other = 'echo "<<WORKFLOW_GLOSSARY_ACCEPTEDX: term=a — reason>>"';
  F.check("T4-1 a longer sentinel name matches neither pattern",
    dq instanceof RegExp && look instanceof RegExp && !dq.test(other) && !look.test(other), other);
}

// Bodies the DQ regex accepts that the handler must still refuse as malformed.
const MALFORMED = [
  ["op outside the domain", "term=glossary drift op=remove — user accepted"],
  ["cat outside the domain", "term=glossary drift cat=session — user accepted"],
  ["stage outside the domain", "term=glossary drift stage=foo — user accepted"],
  ["duplicate op", "term=glossary drift op=add op=add — user accepted"],
  ["duplicate stage", "term=glossary drift stage=outline stage=outline — user accepted"],
  ["op mixed with stage", "term=glossary drift op=add stage=outline — user accepted"],
  ["cat mixed with stage", "term=glossary drift cat=user stage=outline — user accepted"],
  ["reason under 3 characters", "term=glossary drift — ab"],
  ["reason under 3 characters without whitespace", "term=glossary drift — a  b"],
  ["look-alike only (forbidden character)", "term=glossary (drift) — user accepted"],
  ["look-alike only (term= missing)", "glossary drift — user accepted"],
];

function format(F) {
  const repo = F.mkRepo("fmt");
  const sid = F.newSid("fmt");
  F.writeIntent(sid);
  F.seedAt(sid, "outline", repo);
  // An open finding for the term, so a well-formed sentinel would have something to grant.
  F.inject(sid, "outline", "glossary_check", F.findingRecord("outline", F.FP("a")));
  for (const [label, body] of MALFORMED) {
    F.expectRejected(`T4-1 handler: ${label}`, sid, `echo "<<WORKFLOW_GLOSSARY_ACCEPTED: ${body}>>"`, repo, /malformed/i);
  }
  const r = F.mark(null, F.accepted(F.TERM), repo);
  F.check("T4-1 handler: no session id → could not resolve session_id, GLOSSARY_ACCEPTED not recorded",
    /could not resolve session_id/.test(r.all) && /GLOSSARY_ACCEPTED/.test(r.all), `code=${r.code} ${r.all}`);
}

module.exports = { patterns, format };
