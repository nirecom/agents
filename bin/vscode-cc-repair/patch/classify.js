// The bundle classifier — moved verbatim from the entrypoint's `// ---- classifier ----`
// section. `KEY` lives here rather than next to the other patch constants because
// classify() is the lower module: putting it in apply.js would make the two files
// require each other.
'use strict';

const KEY = 'includeWorktrees:';

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
  return { nLiteral: 0, nFalsy: 0, nTruthy: 0, nUnsupported: 0, nDynamic: 0, nUnknown: 0, nKey: 0 };
}

// The key occurs twice in the real bundle: a destructuring site whose value is an
// identifier, and the call site holding the boolean literal. Only the latter is a patch
// target, so every decision below is made on the boolean-literal count `nLiteral` —
// never on the raw key count `nKey`, which is reported for diagnostics only.
function classify(text) {
  const body = String(text);
  const counts = zeroCounts();
  let siteOffset = -1;
  let cursor = 0;
  for (;;) {
    const at = body.indexOf(KEY, cursor);
    if (at === -1) break;
    counts.nKey += 1;
    const verdict = classifyValue(body.slice(at + KEY.length));
    if (verdict === 'falsy') {
      counts.nFalsy += 1;
      if (siteOffset < 0) siteOffset = at;
    } else if (verdict === 'truthy') {
      counts.nTruthy += 1;
    } else if (verdict === 'unsupported') {
      counts.nUnsupported += 1;
    } else if (verdict === 'dynamic') {
      counts.nDynamic += 1;
    } else {
      counts.nUnknown += 1;
    }
    cursor = at + KEY.length;
  }
  counts.nLiteral = counts.nFalsy + counts.nTruthy;

  // Decision order is load-bearing. The unsupported/unknown refusal MUST precede the
  // `nLiteral === 0` test: a body holding only `!10` has zero literals, so the reverse
  // order would report `absent` and walk past a call site the tool cannot read.
  let state;
  if (counts.nUnsupported + counts.nUnknown > 0) state = 'refused';
  else if (counts.nLiteral === 0) state = 'absent';
  else if (counts.nLiteral >= 2) state = 'refused';
  else if (counts.nTruthy === 1) state = 'already';
  else state = 'unpatched';

  // siteOffset addresses the start of the KEY, not the start of the literal — the splice
  // length in patchDir() is measured from there.
  return { state, counts, siteOffset };
}

module.exports = { KEY, classifyValue, zeroCounts, classify };
