"use strict";
// Markdown (summary + per-session tables) and CSV (one flat table, kind=session|segment) renderers.
const MIN = 60000;
const HOUR = 3600000;

const pad = (n) => String(n).padStart(2, "0");
function fmtTs(ms) {
  const d = new Date(ms);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}
const fmtMin = (ms) => (ms / MIN).toFixed(0);
const fmtH = (ms) => (ms / HOUR).toFixed(1);
const mdCell = (s) => String(s || "-").replace(/\|/g, "/").replace(/[\r\n]+/g, " ");

function renderMarkdown(rows) {
  const lines = [
    "# Workflow step durations", "",
    "Times are local. Values in ( ) are user-wait time, excluded from net. Source transcript means segments are estimated from workflow skill launch times.", "",
    "## Summary", "",
    "Wall = first to last transcript record of the session. Span = sum of workflow segments (split into wait / net).", "",
    "| Start | session | title | source | wall h | span h | (wait h) | net h |",
    "|---|---|---|---|---|---|---|---|",
  ];
  for (const r of rows) {
    lines.push(`| ${fmtTs(r.start)} | ${r.sid.slice(0, 8)} | ${mdCell(r.title).slice(0, 60)} | ${r.source} | ${fmtH(r.wall)} | ${fmtH(r.gross)} | (${fmtH(r.wait)}) | ${fmtH(r.gross - r.wait)} |`);
  }
  for (const r of rows) {
    lines.push("", `## ${r.sid.slice(0, 8)} ${r.title ? mdCell(r.title) : ""}`.trimEnd(), "");
    lines.push(`source: ${r.source} / wall ${fmtH(r.wall)} h / span ${fmtH(r.gross)} h (wait ${fmtH(r.wait)} h) -> net ${fmtH(r.gross - r.wait)} h`, "");
    lines.push("| Segment | Start | min | (wait min) | net min |", "|---|---|---|---|---|");
    for (const g of r.segs) {
      lines.push(`| ${mdCell(g.label)} | ${fmtTs(g.s)} | ${fmtMin(g.e - g.s)} | (${fmtMin(g.w)}) | ${fmtMin(g.e - g.s - g.w)} |`);
    }
  }
  return lines.join("\n") + "\n";
}

function csvCell(v) {
  const s = v === null || v === undefined ? "" : String(v);
  return /[",\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}
const min1 = (ms) => (ms / MIN).toFixed(1);

const CSV_HEADER = ["kind", "session", "title", "source", "segment", "start", "end", "wall_min", "span_min", "wait_min", "net_min"];
// Built from its code point: a literal BOM in source trips the outbound zero-width scan.
const BOM = String.fromCharCode(0xfeff);

function renderCsv(rows) {
  const out = [CSV_HEADER.join(",")];
  const push = (cells) => out.push(cells.map(csvCell).join(","));
  for (const r of rows) {
    const end = r.segs[r.segs.length - 1].e;
    push(["session", r.sid, r.title, r.source, "", fmtTs(r.start), fmtTs(end), min1(r.wall), min1(r.gross), min1(r.wait), min1(r.gross - r.wait)]);
    for (const g of r.segs) {
      push(["segment", r.sid, r.title, r.source, g.label, fmtTs(g.s), fmtTs(g.e), "", min1(g.e - g.s), min1(g.w), min1(g.e - g.s - g.w)]);
    }
  }
  // BOM so spreadsheet apps detect UTF-8 (Japanese labels).
  return BOM + out.join("\r\n") + "\r\n";
}

module.exports = { renderMarkdown, renderCsv, CSV_HEADER };
