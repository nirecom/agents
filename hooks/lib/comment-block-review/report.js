"use strict";
// Report buffer of the comment-block review (#2507): findings are held until the header's counts
// are known. Paths and the extension list print into a line-oriented report that pre-commit
// re-prints, so C0 controls and DEL render as \xHH to stop forged lines and terminal repaints.

const DETAIL_LIMIT = 5;

// esc(s) — C0 control bytes and 0x7F as uppercase \xHH; backslash and non-ASCII pass through.
function esc(s) {
  let out = "";
  for (const c of String(s)) {
    const code = c.charCodeAt(0);
    const control = (code >= 0x01 && code <= 0x1f) || code === 0x7f;
    out += control ? `\\x${code.toString(16).toUpperCase().padStart(2, "0")}` : c;
  }
  return out;
}

function createReport() {
  const body = [];
  const counts = { warn: 0, error: 0, scanned: 0, tooBig: 0 };
  return {
    counts,
    add(line) {
      body.push(line);
    },
    // details(runs) — up to DETAIL_LIMIT run lines, then the remainder count.
    details(runs) {
      runs.slice(0, DETAIL_LIMIT).forEach((r) => body.push(`  L${r.start}-L${r.end} (${r.len} comment lines)`));
      if (runs.length > DETAIL_LIMIT) body.push(`  ... and ${runs.length - DETAIL_LIMIT} more`);
    },
    body: () => body,
  };
}

module.exports = { esc, createReport };
