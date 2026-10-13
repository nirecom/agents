"use strict";
// Quote-aware tokenizer and subcommand-path matcher shared by merge-detect.js and
// merge-detect/graphql.js.

function tokenize(segment) {
  return segment.trim().match(/(?:[^\s"']+|"[^"]*"|'[^']*')+/g) || [];
}

// True when `segment` runs `<head> <words...>` with flags allowed between the words
// (`glab mr -R owner/repo merge`). A non-flag token right after a flag is taken as that
// flag's value, so an unknown value-taking flag errs toward a hit (fail-closed).
function hasSubcommandPath(segment, head, words) {
  const tokens = tokenize(segment);
  if (tokens[0] !== head) return false;
  let i = 1;
  for (const word of words) {
    let afterFlag = false;
    for (; i < tokens.length; i++) {
      const t = tokens[i];
      if (t === word) break;
      if (t.startsWith("-")) { afterFlag = !t.includes("="); continue; }
      if (!afterFlag) return false;
      afterFlag = false;
    }
    if (i >= tokens.length) return false;
    i++;
  }
  return true;
}

module.exports = { tokenize, hasSubcommandPath };
