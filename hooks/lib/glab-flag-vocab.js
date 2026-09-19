"use strict";
// WHICH glab flags eat the NEXT argv token, per subcommand — the glab analogue of
// gh-flag-vocab.js. glab reuses GitHub CLI's flag grammar but spells issue/MR body
// as --description (-d) and MR branches as --source-branch/--target-branch, so the
// value/boolean split is declared here independently rather than borrowed from gh.

// [shorthand, long name, takesValue]; a later entry overrides an earlier one.
const GLAB_COMMON = [
  ["R", "repo", true],
  ["", "hostname", true],
  ["h", "help", false],
];

const ISSUE_CREATE = [
  ["t", "title", true], ["d", "description", true], ["l", "label", true],
  ["a", "assignee", true], ["m", "milestone", true], ["", "recover", true],
  ["b", "body", true],
];

const ISSUE_UPDATE = ISSUE_CREATE;
const ISSUE_CLOSE = [["m", "message", true]];
const ISSUE_NOTE = [["m", "message", true], ["", "attachment", true]];

const MR_CREATE = ISSUE_CREATE.concat([
  ["s", "source-branch", true], ["b", "target-branch", true],
  ["", "reviewer", true], ["", "milestone", true],
]);
const MR_UPDATE = MR_CREATE;
const MR_CLOSE = [["m", "message", true]];
const MR_NOTE = [["m", "message", true], ["", "attachment", true]];

const GLAB_SUBCOMMAND_FLAGS = {
  "issue create": ISSUE_CREATE, "issue update": ISSUE_UPDATE,
  "issue close": ISSUE_CLOSE, "issue note": ISSUE_NOTE,
  "mr create": MR_CREATE, "mr update": MR_UPDATE,
  "mr close": MR_CLOSE, "mr note": MR_NOTE,
};

function buildVocab(specs) {
  const vocab = {
    longValue: new Set(), longBool: new Set(),
    shortValue: new Set(), shortBool: new Set(),
  };
  for (const [short, long, takesValue] of specs) {
    if (long) {
      const name = "--" + long;
      (takesValue ? vocab.longBool : vocab.longValue).delete(name);
      (takesValue ? vocab.longValue : vocab.longBool).add(name);
    }
    if (short) {
      (takesValue ? vocab.shortBool : vocab.shortValue).delete(short);
      (takesValue ? vocab.shortValue : vocab.shortBool).add(short);
    }
  }
  return vocab;
}

const VOCABS = { "": buildVocab(GLAB_COMMON) };
for (const key of Object.keys(GLAB_SUBCOMMAND_FLAGS)) {
  VOCABS[key] = buildVocab(GLAB_COMMON.concat(GLAB_SUBCOMMAND_FLAGS[key]));
}

// First non-flag word at or after `start`, plus the index just past it. glab
// takes no value-bearing global flags before the verb, so a simple scan that
// skips dash-led tokens resolves `glab issue create` without a gh-style resolver.
function subWord(argv, start) {
  for (let i = start; i < argv.length; i += 1) {
    const w = argv[i];
    if (typeof w !== "string" || w === "") continue;
    if (w[0] === "-") continue;
    return { word: w, next: i + 1 };
  }
  return { word: null, next: argv.length };
}

// The subcommand a glab argv (everything AFTER the `glab` word) names, as the key
// of its flag table: "issue create", "mr note", etc. Returns null when no
// two-word verb resolves.
function subcommandKey(argv) {
  const list = Array.isArray(argv) ? argv : [];
  const first = subWord(list, 0);
  if (first.word === null) return null;
  const second = subWord(list, first.next);
  if (second.word === null) return null;
  return first.word + " " + second.word;
}

// The flag vocabulary in force for a glab argv. An unrecognized subcommand gets
// the global-only table, where every command flag reads as unknown.
function vocabularyFor(argv) {
  const key = subcommandKey(argv);
  if (key !== null && Object.prototype.hasOwnProperty.call(VOCABS, key)) return VOCABS[key];
  return VOCABS[""];
}

module.exports = { vocabularyFor, subcommandKey };
