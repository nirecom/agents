"use strict";
// bin/lib/jev-report-aggregate/askuser-dialogs.js — the AskUserQuestion section of bin/jev-report
// (#2764): reads the route log (askuser-routes.jsonl, .3 oldest ... base newest) and counts, per
// dialog ID, how many dialogs were shown, sent to Jev (jev_called) and answered, and each route.

const fs = require("fs");
const path = require("path");
const SCRIPT_CHECKOUT_ROOT = path.resolve(__dirname, "..", "..", "..");
const { DIALOG_ID_RE } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "lib", "askuser-dialog-levels.js"));
const { ROUTES } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "lib", "askuser-route-log.js"));

const GENERATIONS = [".3", ".2", ".1", ""];
const NO_ID = "(no id)";
const MALFORMED = "(malformed)";

// readRoutes(logPath) -> {records, broken}; absent generations are skipped.
function readRoutes(logPath) {
  const records = [];
  let broken = 0;
  for (const suffix of GENERATIONS) {
    let text;
    try { text = fs.readFileSync(logPath + suffix, "utf8"); } catch (_e) { continue; }
    for (const line of text.split(/\r?\n/)) {
      if (!line.trim()) continue;
      let o;
      try { o = JSON.parse(line); } catch (_e) { broken++; continue; }
      if (!o || typeof o !== "object" || Array.isArray(o) || typeof o.route !== "string") { broken++; continue; }
      records.push(o);
    }
  }
  return { records, broken };
}

// aggregateDialogs(records) -> {<dialog ID | "(no id)">: {shown, to_jev, answered, routes}}.
// The map has no prototype, so a log-derived "constructor" key is an ordinary key; a route outside
// ROUTES is counted as "other".
function aggregateDialogs(records) {
  const out = Object.create(null);
  for (const r of records || []) {
    if (!r || typeof r !== "object") continue;
    const id = r.dialog_id === null || r.dialog_id === undefined ? NO_ID : String(r.dialog_id);
    const d = out[id] || (out[id] = { shown: 0, to_jev: 0, answered: 0, routes: {} });
    const route = ROUTES.includes(r.route) ? r.route : "other";
    d.shown++;
    if (r.jev_called === true) d.to_jev++;
    if (route === "answered") d.answered++;
    d.routes[route] = (d.routes[route] || 0) + 1;
  }
  return out;
}

const safeId = (id) => (id === NO_ID || DIALOG_ID_RE.test(id) ? id : MALFORMED);

// formatDialogs(dialogs) -> the text section; only well-formed IDs and known routes are printed.
function formatDialogs(dialogs) {
  const out = ["== askuser-answer dialogs =="];
  const ids = Object.keys(dialogs || {}).sort();
  if (!ids.length) out.push("no route records");
  for (const id of ids) {
    const d = dialogs[id];
    const routes = Object.keys(d.routes).sort().map((k) => `${k}=${d.routes[k]}`).join(" ");
    out.push(`${safeId(id)}  shown=${d.shown} to_jev=${d.to_jev} answered=${d.answered}  ${routes}`);
  }
  return out.join("\n") + "\n";
}

module.exports = { readRoutes, aggregateDialogs, formatDialogs, NO_ID };
