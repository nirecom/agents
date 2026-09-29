"use strict";
// hooks/lib/readonly-syntax-adapters.js — per-syntax argv checks for the #2403 N3 classes.
// Each adapter answers "is this argv free of every write / exec capability the entry names";
// a value mistaken for a flag can only add a rejection, so no value-arity table is kept.

// find actions that run a program or write a file (a superset of the settings.json deny).
const FIND_DENY = new Set([
  "-exec", "-execdir", "-ok", "-okdir", "-delete", "-fls", "-fprint", "-fprint0", "-fprintf",
]);

/**
 * @param {string[]} args argv without the command word
 * @param {{denyFlags?: string[], requireLeading?: string[]|null}} entry a class entry
 * @returns {boolean} true when no deny flag appears before `--` and requireLeading holds
 */
function getopt(args, entry) {
  const list = Array.isArray(args) ? args : [];
  const e = entry || {};
  const deny = Array.isArray(e.denyFlags) ? e.denyFlags : [];
  const longDeny = deny.filter((f) => f.startsWith("--"));
  const shortDeny = new Set(deny.filter((f) => !f.startsWith("--") && f.length === 2).map((f) => f[1]));
  if (Array.isArray(e.requireLeading) && e.requireLeading.length > 0) {
    if (list.length === 0 || !e.requireLeading.includes(list[0])) return false;
  }
  for (const tok of list) {
    if (typeof tok !== "string") return false;
    if (tok === "--") break;
    if (deny.includes(tok)) return false;
    if (tok.startsWith("--")) {
      const eq = tok.indexOf("=");
      const name = eq === -1 ? tok : tok.slice(0, eq);
      // GNU getopt_long accepts any unique abbreviation, so a prefix of a deny flag is it.
      if (longDeny.some((d) => d.startsWith(name))) return false;
    } else if (tok.length > 1 && tok[0] === "-") {
      if ([...tok.slice(1)].some((ch) => shortDeny.has(ch))) return false;
    }
  }
  return true;
}

/**
 * @param {string[]} args find's argv without the command word
 * @returns {boolean} true when no action token runs a program or writes a file
 */
function find(args) {
  const list = Array.isArray(args) ? args : [];
  return list.every((t) => typeof t === "string" && !FIND_DENY.has(t));
}

module.exports = { getopt, find, FIND_DENY };
