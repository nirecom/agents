"use strict";

// `gh api` has no verb: whether a call writes is decided by flags whose meaning
// depends on order and on each other, so the argv has to be walked the way
// pflag walks it rather than pattern-matched. A value-taking flag consumes the
// NEXT token (so `-X -f title=x` makes `-f` the method, not a payload flag),
// attached forms (`-XPOST`, `--method=POST`) are self-contained, and an
// unrecognized flag makes the whole scan ambiguous — the guard cannot know
// whether it swallowed the following token, so it refuses to classify.
const { isGhApiWriteFromFlags } = require("../lib/forge-write-extract");
// The same declaration of gh's flag arity the repo-selector scan walks, so the
// two readers of one argv can never disagree about which flags eat a token.
const { GH_API_VALUE_FLAGS, GH_API_BOOL_FLAGS } = require("../lib/gh-flag-vocab");

const PAYLOAD_FIELD_FLAGS = new Set(["-f", "--field", "-F", "--raw-field"]);

function rawAt(argvRaw, i) {
  return Array.isArray(argvRaw) && typeof argvRaw[i] === "string" ? argvRaw[i] : null;
}

// Walk the argv that FOLLOWS the `api` subcommand word.
// Returns { flags: [{flag, value, index, raw}], endpoint, ambiguous }.
function scanGhApiFlags(argv, argvRaw) {
  const flags = [];
  let endpoint = null;
  let endpointRaw = null;
  let ambiguous = false;
  const list = Array.isArray(argv) ? argv : [];
  let i = 0;
  let endOfFlags = false;
  while (i < list.length) {
    const tok = list[i];
    if (typeof tok !== "string") { ambiguous = true; i += 1; continue; }
    if (endOfFlags || tok === "" || tok[0] !== "-" || tok === "-") {
      if (endpoint === null) { endpoint = tok; endpointRaw = rawAt(argvRaw, i); }
      i += 1;
      continue;
    }
    if (tok === "--") { endOfFlags = true; i += 1; continue; }
    const eq = tok.indexOf("=");
    if (eq > 0 && tok[1] === "-") {
      const name = tok.slice(0, eq);
      if (!GH_API_VALUE_FLAGS.has(name) && !GH_API_BOOL_FLAGS.has(name)) ambiguous = true;
      flags.push({ flag: name, value: tok.slice(eq + 1), index: i, raw: rawAt(argvRaw, i) });
      i += 1;
      continue;
    }
    if (GH_API_VALUE_FLAGS.has(tok)) {
      if (i + 1 >= list.length) {
        // A value-taking flag with nothing after it: gh would error, and the
        // guard cannot know what the effective method or payload would be.
        flags.push({ flag: tok, value: null, index: i, raw: rawAt(argvRaw, i) });
        ambiguous = true;
        i += 1;
        continue;
      }
      flags.push({ flag: tok, value: list[i + 1], index: i + 1, raw: rawAt(argvRaw, i + 1) });
      i += 2;
      continue;
    }
    if (GH_API_BOOL_FLAGS.has(tok)) { i += 1; continue; }
    if (tok[1] !== "-" && tok.length > 2 && GH_API_VALUE_FLAGS.has(tok.slice(0, 2))) {
      flags.push({ flag: tok.slice(0, 2), value: tok.slice(2), index: i, raw: rawAt(argvRaw, i) });
      i += 1;
      continue;
    }
    ambiguous = true;
    i += 1;
  }
  return { flags, endpoint, endpointRaw, ambiguous };
}

function isGhApiWriteArgv(argv) {
  const scan = scanGhApiFlags(argv);
  if (scan.ambiguous) return true;
  return isGhApiWriteFromFlags(scan.flags);
}

function extractApiEndpoint(argv) {
  return scanGhApiFlags(argv).endpoint;
}

// The effective value of a repeated payload field, pflag-style: last wins.
function lastFieldValue(flags, fieldName) {
  let found = null;
  for (const f of flags) {
    if (!f || !PAYLOAD_FIELD_FLAGS.has(f.flag)) continue;
    if (typeof f.value !== "string") { found = { name: fieldName, value: null, raw: f.raw }; continue; }
    const eq = f.value.indexOf("=");
    if (eq < 0) continue;
    if (f.value.slice(0, eq) !== fieldName) continue;
    found = { name: fieldName, value: f.value.slice(eq + 1), raw: f.raw };
  }
  return found;
}

function hasInputFlag(flags) {
  return flags.some((f) => f && f.flag === "--input");
}

module.exports = {
  scanGhApiFlags,
  isGhApiWriteArgv,
  extractApiEndpoint,
  lastFieldValue,
  hasInputFlag,
  GH_API_VALUE_FLAGS,
  GH_API_BOOL_FLAGS,
  PAYLOAD_FIELD_FLAGS,
};
