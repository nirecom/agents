"use strict";
// Temporary (#2434): deleted with this folder per the deletion-condition in control-dir.js.
// Rewrites embedded legacy paths <any-dir>/<sid>-<name> to <sid>.control/<name>.
// A path is matched by its <sid>-<name> basename in any separator form (native,
// forward-slash, MSYS, JSON-escaped); artifacts and other sids are left alone.
const path = require("path");
const { parsePlansEntry } = require("../../plans-artifact-registry");
const { NEVER_MOVE_RE } = require("./plan");

function injected(code, message) {
  return Object.assign(new Error(message), { code });
}

function pathRe(sid) {
  return new RegExp(
    `(?<![^\\s"'=(,\\[])(?:[A-Za-z]:)?(?:[\\\\/]{1,2}[^\\s"'\\\\/<>|*?]+)*?[\\\\/]{1,2}${sid}-([A-Za-z0-9._-]+)`,
    "g",
  );
}

function shouldRewrite(sid, rest) {
  if (NEVER_MOVE_RE.test(rest)) return false;
  const parsed = parsePlansEntry(`${sid}-${rest}`);
  if (!parsed) return true;
  if (parsed.verdict === "ambiguous" || parsed.verdict === "artifact") return false;
  return parsed.sid === sid;
}

function rewriteContent(buf, { sid, ctlDir, name }) {
  if (process.env.CONTROL_MIGRATION_FAULT === "rewrite-fail" && name.endsWith(".json")) {
    throw injected("EREWRITE", `injected rewrite failure for ${name}`);
  }
  const text = buf.toString("utf8");
  const ctlFwd = path.resolve(ctlDir).replace(/\\/g, "/");
  let changed = false;
  const out = text.replace(pathRe(sid), (whole, rawRest) => {
    const rest = rawRest.replace(/\.+$/, "");
    if (!shouldRewrite(sid, rest)) return whole;
    changed = true;
    return `${ctlFwd}/${rest}${rawRest.slice(rest.length)}`;
  });
  if (!changed) return buf;
  if (name.endsWith(".json")) {
    try { JSON.parse(out); } catch (e) {
      throw injected("EREWRITE", `rewritten ${name} is not valid JSON: ${e.message}`);
    }
  }
  return Buffer.from(out, "utf8");
}

module.exports = { rewriteContent };
