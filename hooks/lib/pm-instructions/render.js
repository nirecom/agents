"use strict";
// Renders one PM instructions block (#3019): the header line, the per-session facts (PM tag and issues,
// or each issue's assigned PM with its full session id for `find-peer --session`), the source line and
// the section bodies, capped at MAX_BYTES on a UTF-8 boundary.

const S = require("../../pm-session/schema");
const { capWithHeader } = require("../user-instructions");
const { MD_REL } = require("./sections");

const MAX_BYTES = 8192;

function factsOf(role) {
  if (role.role === "pm") return [`PM tag: ${role.tag}; assigned issues: ${role.issues.map(S.refLabel).join(" ") || "(none)"}`];
  return role.owners.map((o) => `Assigned PM of ${S.refLabel(o.issue)}: PM tag ${o.tag}, session id ${o.session_id}`);
}

// render(role, timing, sections) -> the block, or null when no section applies.
function render(role, timing, sections) {
  if (sections.length === 0) return null;
  const header = `[pm-instructions role=${role.role} timing=${timing}]`;
  const h2 = sections[0].entry.h2;
  const body = [
    ...factsOf(role),
    `Source: ${MD_REL} ## ${h2}`,
    "",
    ...sections.map((s) => `### ${s.entry.h3}\n\n${s.body}\n`),
  ].join("\n");
  return capWithHeader(body, header, MAX_BYTES);
}

module.exports = { MAX_BYTES, render };
