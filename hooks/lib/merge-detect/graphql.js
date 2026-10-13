"use strict";
// GraphQL merge detection (#2527 4-1): `gh|glab api graphql` whose -f / -F / --field /
// --raw-field text names a merge mutation as a whole word. Reuses the existing kinds so
// every merge-detect consumer treats it as the forge PR merge it is.
// Out of scope by design: --input, @file, stdin, shell variables, curl / wget.

const { tokenize, hasSubcommandPath } = require("./subcommand-path");

const MUTATIONS_BY_HEAD = Object.freeze({
  gh: { kind: "gh-pr-merge", re: /\b(?:mergePullRequest|enablePullRequestAutoMerge)\b/ },
  glab: { kind: "glab-mr-merge", re: /\bmergeRequestAccept\b/ },
});

const FIELD_FLAGS = new Set(["-f", "-F", "--field", "--raw-field"]);

// The field values of the segment, quotes stripped; `key=@file` values are skipped.
function fieldValues(tokens) {
  const values = [];
  for (let i = 0; i < tokens.length; i++) {
    const t = tokens[i];
    let v = null;
    if (FIELD_FLAGS.has(t)) v = tokens[++i];
    else if (/^--(?:raw-)?field=/.test(t)) v = t.slice(t.indexOf("=") + 1);
    else if (/^-[fF][^-]/.test(t)) v = t.slice(2);
    if (typeof v !== "string") continue;
    const unq = v.replace(/["']/g, "");
    if (/^[^=]*=@/.test(unq)) continue;
    values.push(unq);
  }
  return values;
}

function checkGraphqlMerge(segment) {
  if (!segment || typeof segment !== "string") return { hit: false, kind: null };
  for (const head of Object.keys(MUTATIONS_BY_HEAD)) {
    if (!hasSubcommandPath(segment, head, ["api", "graphql"])) continue;
    const { kind, re } = MUTATIONS_BY_HEAD[head];
    if (fieldValues(tokenize(segment)).some((v) => re.test(v))) return { hit: true, kind };
  }
  return { hit: false, kind: null };
}

module.exports = { checkGraphqlMerge };
