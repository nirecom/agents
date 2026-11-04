"use strict";
// hooks/workflow-state/glossary-check/grant-carry.js — the grant carry-over and expiry of a re-record
// (#2770, #2909), private to record.js. A grant moves to the new fingerprint when every changed input
// is in its record's role set and its keys did not grow; otherwise it expires into expired_grants with
// a cause. Also the text parts every refusal shares: no part shown in a hint may hold a single quote.

const { unsafeTermChars, describeTermChars } = require("../../lib/glossary-term");

const CARRY_ROLES = Object.freeze({ check: ["artifact", "rules"], provenance: ["ops", "rules"] });

const asArray = (v) => (Array.isArray(v) ? v : []);
const noQuote = (s) => String(s).replace(/'/g, "");

// changedInputs(a, b) -> the input names whose digest differs between two inputs maps.
function changedInputs(a, b) {
  const x = a || {};
  const y = b || {};
  return [...new Set(Object.keys(x).concat(Object.keys(y)))].filter((k) => x[k] !== y[k]);
}

// The dedupe key of an expired entry: norm (check), or norm + operation + category (provenance).
const expiryKey = (e) => JSON.stringify([e && e.norm, e && e.operation !== undefined ? e.operation : null,
  e && e.category !== undefined ? e.category : null]);

function expiryOf(g, termOf, cause, changed, fingerprint) {
  const scope = g.operation !== undefined ? { operation: g.operation, category: g.category } : {};
  return Object.assign({ norm: g.norm, term: termOf(g.norm) }, scope, { cause, changed, fingerprint });
}

// grantCarry(prev, fpResult, roles, keysOf, prevList, nextList, termOf) -> { carried, expired }.
function grantCarry(prev, fpResult, roles, keysOf, prevList, nextList, termOf) {
  const p = prev || {};
  const fp = fpResult.fingerprint;
  if (typeof p.fingerprint !== "string" || p.fingerprint === fp) return { carried: [], expired: [] };
  const changed = changedInputs(p.inputs, fpResult.inputs);
  const grants = asArray(p.grants).filter((g) => g && g.fingerprint === p.fingerprint);
  const out = { carried: [], expired: [] };
  const inRoles = changed.length > 0 && changed.every((k) => roles.includes(k));
  for (const g of grants) {
    const before = new Set(keysOf(prevList, g.norm));
    if (inRoles && keysOf(nextList, g.norm).every((k) => before.has(k))) {
      out.carried.push(Object.assign({}, g, { fingerprint: fp }));
    } else {
      out.expired.push(expiryOf(g, termOf, inRoles ? "variants" : "inputs", changed, fp));
    }
  }
  return out;
}

// retainedExpired(prevExpired, expired, open) -> the new expiries plus the previous ones still open
// (an ungranted finding or blocked item has their key); deduped by key, new ones win.
function retainedExpired(prevExpired, expired, open) {
  const openKeys = new Set(asArray(open).map((o) => expiryKey({ norm: o.norm, operation: o.operation, category: o.category })));
  const fresh = asArray(expired).filter(Boolean);
  const seen = new Set(fresh.map(expiryKey));
  const kept = asArray(prevExpired).filter((e) => e && !seen.has(expiryKey(e)) && openKeys.has(expiryKey(e)));
  return fresh.concat(kept.filter((e, i) => kept.findIndex((x) => expiryKey(x) === expiryKey(e)) === i));
}

const termIn = (list, norm) => {
  const hit = asArray(list).find((x) => x && x.norm === norm && x.term !== undefined);
  return hit ? String(hit.term) : String(norm);
};

// staleOutlook(rec, changed, roles) -> { carry: "possible" | "none", granted_terms }, from the record only.
function staleOutlook(rec, changed, roles) {
  const r = rec || {};
  const c = asArray(changed);
  const carry = c.length > 0 && c.every((k) => roles.includes(k)) ? "possible" : "none";
  const granted = asArray(r.grants).filter((g) => g && g.fingerprint === r.fingerprint);
  return { carry, granted_terms: [...new Set(granted.map((g) => termIn(r.findings, g.norm)))] };
}

// carryReportOf(prev, value) -> what one re-record carried and expired, for the record output.
function carryReportOf(prev, value) {
  const p = prev || {};
  const v = value || {};
  if (typeof p.fingerprint !== "string" || p.fingerprint === v.fingerprint) return { changed: [], carried: [], expired: [] };
  const was = new Set(asArray(p.grants).filter((g) => g && g.fingerprint === p.fingerprint).map((g) => g.norm));
  const carried = asArray(v.grants).filter((g) => g && g.fingerprint === v.fingerprint && was.has(g.norm))
    .map((g) => termIn(v.findings, g.norm));
  const expired = asArray(v.expired_grants).filter((e) => e && e.fingerprint === v.fingerprint)
    .map((e) => ({ term: e.term, cause: e.cause, changed: asArray(e.changed) }));
  return { changed: changedInputs(p.inputs, v.inputs), carried: [...new Set(carried)], expired };
}

// termsText(terms) -> the distinct terms joined by ", ", single quotes dropped.
const termsText = (terms) => [...new Set(asArray(terms).map((t) => noQuote(t)))].join(", ");

// causeText(e) -> why an expired grant lapsed.
const causeText = (e) => (e && e.cause === "variants" ? "a new variant appeared"
  : `${asArray(e && e.changed).map(noQuote).join(", ")} changed`);

const codePoints = (chars) => chars.map((c) => "U+" + c.charCodeAt(0).toString(16).toUpperCase().padStart(4, "0")).join(", ");

// reacceptText(term, step, target) -> how to win the grant back; target "cli" or "hint" (the default,
// which never holds a single quote).
function reacceptText(term, step, target) {
  const cli = target === "cli";
  const t = String(term);
  const unsafe = unsafeTermChars(t);
  if (unsafe.length > 0) {
    return `the term has a forbidden character (${cli ? describeTermChars(unsafe) : codePoints(unsafe)}), ` +
      "so it cannot be accepted with GLOSSARY_ACCEPTED — fix the heading or record it in the intent glossary";
  }
  const echo = (x) => `re-accept with: echo "<<WORKFLOW_GLOSSARY_ACCEPTED: term=${x} step=${step} — <reason>>>"`;
  if (cli || !t.includes("'")) return echo(t);
  return `${echo("<term>")} (copy the term from the EXPIRED line of check-glossary-drift)`;
}

module.exports = {
  CARRY_ROLES, changedInputs, grantCarry, retainedExpired, staleOutlook, carryReportOf,
  termsText, causeText, reacceptText, termIn,
};
