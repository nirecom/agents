// The bundle classifier. `KEY` lives here rather than next to the other patch constants
// because classify() is the lower module: putting it in apply.js would make the two files
// require each other.
//
// Two counting methods. `anchor` (default) patches only the single `includeWorktrees:`
// directly in the object literal returned by `sessionListOptions(){return{`; every other site
// in the bundle (e.g. resolveSession's own `includeWorktrees:!1`) is left alone. `legacy`
// is the pre-#2683 rule — exactly one boolean literal anywhere — kept as an opt-in fallback.
'use strict';

const KEY = 'includeWorktrees:';
const ANCHOR = 'sessionListOptions(){return{';
const METHODS = ['anchor', 'legacy'];
const ANCHOR_BOUNDARY = '{},;';

// `rest` is the text immediately following one `includeWorktrees:` occurrence.
// Anchored, tried top to bottom. The negative lookahead is the whole safety margin:
// `!10` is valid JS that this tool must not mistake for the boolean literal `!1`.
function classifyValue(rest) {
  const text = String(rest);
  if (/^!1(?![A-Za-z0-9_$])/.test(text)) return 'falsy';
  if (/^!0(?![A-Za-z0-9_$])/.test(text)) return 'truthy';
  if (/^ ?(?:true|false)\b/.test(text)) return 'unsupported';
  if (/^[A-Za-z_$]/.test(text)) return 'dynamic';
  return 'unknown';
}

function zeroCounts() {
  return {
    nLiteral: 0, nFalsy: 0, nTruthy: 0, nUnsupported: 0, nDynamic: 0, nUnknown: 0, nKey: 0,
    nAnchor: 0, anchorValue: '-',
  };
}

const COUNT_FIELD = {
  falsy: 'nFalsy',
  truthy: 'nTruthy',
  unsupported: 'nUnsupported',
  dynamic: 'nDynamic',
  unknown: 'nUnknown',
};

function scanSites(body) {
  const counts = zeroCounts();
  const sites = [];
  let cursor = 0;
  for (;;) {
    const at = body.indexOf(KEY, cursor);
    if (at === -1) break;
    const verdict = classifyValue(body.slice(at + KEY.length));
    counts.nKey += 1;
    counts[COUNT_FIELD[verdict]] += 1;
    sites.push({ at, verdict });
    cursor = at + KEY.length;
  }
  counts.nLiteral = counts.nFalsy + counts.nTruthy;
  return { counts, sites };
}

function anchorOffsets(body) {
  const offsets = [];
  for (let at = body.indexOf(ANCHOR); at !== -1; at = body.indexOf(ANCHOR, at + ANCHOR.length)) {
    offsets.push(at);
  }
  return offsets;
}

// Index of the closing quote of the string opening at `start`; -1 when unterminated.
function skipString(body, start) {
  const quote = body[start];
  for (let j = start + 1; j < body.length; j += 1) {
    if (body[j] === '\\') j += 1;
    else if (body[j] === quote) return j;
  }
  return -1;
}

// Depth scan from the literal's opening `{` to its matching `}`, also collecting the KEY
// sites that sit directly in the literal (depth 1, outside strings). A wrong range would
// patch a sibling method's site, so the scan never guesses: quoted strings are skipped,
// and a backtick or `/` (template, regex, comment — unlexable without a parser), an
// unterminated string, a mismatched closer or no closer at all returns null, which the
// caller refuses. A non-null range therefore counts only code braces.
function scanLiteral(body, open) {
  const top = [];
  let depth = 0;
  for (let i = open; i < body.length; i += 1) {
    const ch = body[i];
    if (ch === '"' || ch === "'") {
      i = skipString(body, i);
      if (i === -1) return null;
    } else if (ch === '`' || ch === '/') return null;
    else if ('{[('.includes(ch)) depth += 1;
    else if ('}])'.includes(ch)) {
      depth -= 1;
      if (depth === 0) return ch === '}' ? { close: i, top } : null;
    } else if (depth === 1 && body.startsWith(KEY, i)) top.push(i);
  }
  return null;
}

// Method-independent view of the anchor, shared by the anchor decision and the report's
// `anchor-value` diagnostic so legacy runs show it too.
function inspectAnchor(body, sites) {
  const anchors = anchorOffsets(body);
  if (anchors.length !== 1) return { anchors, value: '-' };
  // Without a lexer the anchor text may sit inside a string or comment; a method definition
  // follows `{` `}` `,` `;` (or opens the file), so any other preceding char is refused.
  if (anchors[0] > 0 && !ANCHOR_BOUNDARY.includes(body[anchors[0] - 1])) {
    return { anchors, value: 'ambiguous' };
  }
  const open = anchors[0] + ANCHOR.length - 1;
  const range = scanLiteral(body, open);
  if (!range) return { anchors, value: 'ambiguous' };
  const inside = sites.filter((s) => s.at > open && s.at < range.close);
  if (inside.length === 0) return { anchors, value: 'none' };
  const single = inside.length === 1 && range.top.length === 1 && range.top[0] === inside[0].at;
  return single ? { anchors, value: inside[0].verdict, site: inside[0] } : { anchors, value: 'ambiguous' };
}

function classifyLegacy(counts, sites) {
  if (counts.nUnsupported + counts.nUnknown > 0) return { state: 'refused', reason: 'unknown-value' };
  if (counts.nLiteral === 0) return { state: 'absent' };
  if (counts.nLiteral >= 2) return { state: 'refused', reason: 'multiple-literals' };
  if (counts.nTruthy === 1) return { state: 'already' };
  return { state: 'unpatched', siteOffset: sites.find((s) => s.verdict === 'falsy').at };
}

// Decision order is load-bearing: the unknown-value refusal precedes every count test
// (a body holding only `!10` has zero literals and would otherwise read as `absent`).
function classifyAnchor(counts, probe) {
  if (counts.nUnsupported + counts.nUnknown > 0) return { state: 'refused', reason: 'unknown-value' };
  if (probe.anchors.length >= 2) return { state: 'refused', reason: 'multiple-anchors' };
  if (probe.anchors.length === 0) {
    return counts.nLiteral > 0 ? { state: 'refused', reason: 'no-anchor' } : { state: 'absent' };
  }
  if (probe.value === 'none') {
    return counts.nLiteral > 0 ? { state: 'refused', reason: 'no-anchor-key' } : { state: 'absent' };
  }
  if (probe.value === 'truthy') return { state: 'already' };
  if (probe.value === 'falsy') return { state: 'unpatched', siteOffset: probe.site.at };
  return { state: 'refused', reason: 'ambiguous-anchor' };
}

// Counts are always whole-bundle and diagnostic only. siteOffset addresses the start of
// the KEY, not the start of the literal — the splice length in patchDir() is measured
// from there. `reason` is set on `refused` only.
function classify(text, options) {
  const method = (options && options.method) || 'anchor';
  if (!METHODS.includes(method)) throw new Error('unknown classify method: ' + method);
  const body = String(text);
  const { counts, sites } = scanSites(body);
  const probe = inspectAnchor(body, sites);
  counts.nAnchor = probe.anchors.length;
  counts.anchorValue = probe.value;
  const decision =
    method === 'legacy' ? classifyLegacy(counts, sites) : classifyAnchor(counts, probe);
  const siteOffset = decision.siteOffset === undefined ? -1 : decision.siteOffset;
  const result = { state: decision.state, counts, siteOffset };
  if (decision.reason) result.reason = decision.reason;
  return result;
}

module.exports = { KEY, ANCHOR, METHODS, classifyValue, zeroCounts, classify };
