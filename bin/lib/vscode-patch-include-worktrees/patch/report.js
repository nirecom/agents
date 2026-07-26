// Report formatting for the patch pass — moved verbatim from the entrypoint's
// `// ---- report ----` section.
'use strict';

// Emitted on EVERY state, including `absent` and `refused`, so the report is diffable
// across runs without special-casing which fields a state happens to populate.
function countPrefix(counts) {
  return [
    'literal=' + counts.nLiteral,
    'falsy=' + counts.nFalsy,
    'truthy=' + counts.nTruthy,
    'dynamic=' + counts.nDynamic,
    'unsupported=' + counts.nUnsupported,
    'unknown=' + counts.nUnknown,
    'key=' + counts.nKey,
  ].join(' ');
}

function summaryLine(nRoots, nDirs, tally) {
  return (
    'summary: roots=' + nRoots + ' dirs=' + nDirs +
    ' patched=' + tally.patched + ' already=' + tally.already + ' absent=' + tally.absent +
    ' would-patch=' + tally['would-patch'] +
    ' refused=' + tally.refused + ' failed=' + tally.failed
  );
}

module.exports = { countPrefix, summaryLine };
