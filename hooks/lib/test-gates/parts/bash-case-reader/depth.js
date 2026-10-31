"use strict";
// Block depth of one code line (comment cut) for the bash case reader: an opener whose own
// closer does not end the line, an end-of-line brace group, or a leading / trailing closer.

const SP = "[ \\t\\n\\v\\f\\r]";
const CLOSER = `;${SP}*(fi|done|esac|\\})(${SP}*([0-9]*[<>]|\\||&&|;|#).*)?$`;
const RE_CLOSER = new RegExp(CLOSER, "s");
const RE_LAST_CLOSER = new RegExp(`^.*${CLOSER}`, "s");
const RE_BRACE_CLOSE = new RegExp(`;${SP}*\\}(${SP}*([0-9]*[<>]|\\||&&|;|#).*)?$`, "s");
const RE_LEAD_CLOSER = new RegExp(`^(fi|done|esac|\\})(${SP}|;|$)`);
const RE_BRACE_OPEN = new RegExp(`(^|${SP}|\\))\\{$`);
const RE_BRACE_INLINE = new RegExp(`(^|${SP}|\\))\\{${SP}`);
const OWN = { if: "fi", case: "esac", function: "}", while: "done", until: "done", for: "done", select: "done" };

// depthStep(code, depth) — the depth after the line.
function depthStep(code, depth) {
  const trimmed = code.replace(/^[ \t\n\v\f\r]+/, "");
  const first = trimmed.split(/[ \t\n\v\f\r]/)[0];
  const body = trimmed.replace(/[ \t\n\v\f\r]+$/, "");
  if (Object.hasOwn(OWN, first)) {
    const m = RE_LAST_CLOSER.exec(body);
    return m && m[1] === OWN[first] ? depth : depth + 1;
  }
  if (RE_BRACE_OPEN.test(body)) return depth + 1;
  if (RE_BRACE_INLINE.test(body) && RE_BRACE_CLOSE.test(body)) return depth;
  if (RE_LEAD_CLOSER.test(body) || RE_CLOSER.test(body)) return depth - 1;
  return depth;
}

module.exports = { depthStep };
