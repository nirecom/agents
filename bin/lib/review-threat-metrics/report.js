"use strict";
// bin/lib/review-threat-metrics/report.js — the output of bin/review-threat-metrics (#2020): one
// JSON object, or a text report whose header names the mode, the model and the classifierId,
// followed by key=value lines of every scalar outside the per-row lists.
const HEAD_KEYS = new Set(["mode", "model", "classifierId"]);

function flatten(v, pre, out) {
  if (v && typeof v === "object" && !Array.isArray(v)) {
    for (const [k, x] of Object.entries(v)) if (k !== "rows" || !Array.isArray(x)) flatten(x, pre ? `${pre}.${k}` : k, out);
  } else if (Array.isArray(v)) {
    out.push(`${pre}=${v.join(",")}`);
  } else {
    out.push(`${pre}=${typeof v === "number" && !Number.isInteger(v) ? v.toFixed(4) : v}`);
  }
  return out;
}

// render(r, json) — the report text, newline-terminated.
function render(r, json) {
  if (json) return `${JSON.stringify(r)}\n`;
  const head = `# review-threat-metrics ${r.mode} model=${r.model} classifierId=${r.classifierId}`;
  const body = flatten(r, "", []).filter((l) => !HEAD_KEYS.has(l.slice(0, l.indexOf("="))));
  return `${[head, ...body].join("\n")}\n`;
}

module.exports = { render, flatten };
