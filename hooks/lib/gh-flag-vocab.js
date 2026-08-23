"use strict";
// WHICH gh flags eat the NEXT argv token. pflag hands a value-taking flag the
// following argument verbatim — a leading dash does not stop it — so `--title
// -Rme/mine` puts a repo-selector SHAPE in value position where gh sees only a
// title. The value/boolean split is the only thing that tells the two apart.
//
// The split is PER SUBCOMMAND because gh reuses shorthands: `-t` is --title on
// `issue create` but --template on `api`, and `-h` is --help everywhere except
// `repo create|edit`, where it is --homepage. A flag in NEITHER set is unknown:
// callers fail closed on it rather than guess.
const { resolveGhSubArgv } = require("./bash-write-patterns/patterns");

// [shorthand, long name, takesValue]; a later entry overrides an earlier one.
const GH_COMMON = [
  ["h", "help", false],
  ["R", "repo", true],
  ["", "hostname", true],
];

const GH_API = [
  ["X", "method", true], ["H", "header", true],
  ["f", "field", true], ["F", "raw-field", true],
  ["", "input", true], ["", "cache", true], ["", "preview", true],
  ["q", "jq", true], ["t", "template", true],
  ["", "paginate", false], ["", "slurp", false], ["", "silent", false],
  ["i", "include", false], ["", "verbose", false],
];

const ISSUE_CREATE = [
  ["a", "assignee", true], ["b", "body", true], ["F", "body-file", true],
  ["l", "label", true], ["m", "milestone", true], ["p", "project", true],
  ["", "recover", true], ["T", "template", true], ["t", "title", true],
  ["e", "editor", false], ["w", "web", false],
];

const ISSUE_EDIT = [
  ["", "add-assignee", true], ["", "add-label", true], ["", "add-project", true],
  ["", "remove-assignee", true], ["", "remove-label", true], ["", "remove-project", true],
  ["b", "body", true], ["F", "body-file", true], ["m", "milestone", true],
  ["t", "title", true],
];

const ISSUE_CLOSE = [["c", "comment", true], ["r", "reason", true]];

const ISSUE_COMMENT = [
  ["b", "body", true], ["F", "body-file", true],
  ["", "create-if-none", false], ["", "edit-last", false],
  ["e", "editor", false], ["w", "web", false],
];

const PR_CREATE = ISSUE_CREATE.concat([
  ["B", "base", true], ["H", "head", true],
  ["d", "draft", false], ["", "dry-run", false], ["f", "fill", false],
  ["", "fill-first", false], ["", "fill-verbose", false],
  ["", "no-maintainer-edit", false],
]);

const PR_EDIT = ISSUE_EDIT.concat([
  ["B", "base", true], ["", "add-reviewer", true], ["", "remove-reviewer", true],
]);

const PR_CLOSE = [["c", "comment", true], ["d", "delete-branch", false]];

const PR_REVIEW = [
  ["b", "body", true], ["F", "body-file", true],
  ["a", "approve", false], ["c", "comment", false], ["r", "request-changes", false],
];

const REPO_CREATE = [
  ["d", "description", true], ["g", "gitignore", true], ["h", "homepage", true],
  ["l", "license", true], ["r", "remote", true], ["s", "source", true],
  ["t", "team", true], ["", "template", true],
  ["", "add-readme", false], ["c", "clone", false],
  ["", "disable-issues", false], ["", "disable-wiki", false],
  ["", "include-all-branches", false], ["", "internal", false],
  ["", "private", false], ["", "public", false], ["", "push", false],
];

// gh spells the repo-edit toggles with pflag's NoOptDefVal (`--enable-wiki`,
// `--enable-wiki=false`), so they never reach into the next token.
const REPO_EDIT = [
  ["d", "description", true], ["h", "homepage", true],
  ["", "add-topic", true], ["", "remove-topic", true],
  ["", "default-branch", true], ["", "visibility", true],
  ["", "accept-visibility-change-consequences", false],
  ["", "allow-forking", false], ["", "allow-update-branch", false],
  ["", "delete-branch-on-merge", false], ["", "enable-advanced-security", false],
  ["", "enable-auto-merge", false], ["", "enable-discussions", false],
  ["", "enable-issues", false], ["", "enable-merge-commit", false],
  ["", "enable-projects", false], ["", "enable-rebase-merge", false],
  ["", "enable-secret-scanning", false], ["", "enable-secret-scanning-push-protection", false],
  ["", "enable-squash-merge", false], ["", "enable-wiki", false],
  ["", "template", false],
];

// `new` is gh's own alias for `create` on both issue and pr: the two spellings
// run the SAME command, so they read the same way here too.
const GH_SUBCOMMAND_FLAGS = {
  "api": GH_API,
  "issue create": ISSUE_CREATE, "issue new": ISSUE_CREATE,
  "issue edit": ISSUE_EDIT, "issue close": ISSUE_CLOSE, "issue comment": ISSUE_COMMENT,
  "pr create": PR_CREATE, "pr new": PR_CREATE,
  "pr edit": PR_EDIT, "pr close": PR_CLOSE, "pr comment": ISSUE_COMMENT,
  "pr review": PR_REVIEW,
  "repo create": REPO_CREATE, "repo edit": REPO_EDIT,
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

const VOCABS = { "": buildVocab(GH_COMMON) };
for (const key of Object.keys(GH_SUBCOMMAND_FLAGS)) {
  VOCABS[key] = buildVocab(GH_COMMON.concat(GH_SUBCOMMAND_FLAGS[key]));
}

function subWord(argv) {
  const rest = resolveGhSubArgv(Array.isArray(argv) ? argv : []);
  const word = rest.length > 0 ? rest[0] : null;
  if (typeof word !== "string" || word === "" || word[0] === "-") return { word: null, rest };
  return { word, rest };
}

// The subcommand a gh argv (everything AFTER the `gh` word) names, as the key
// of its flag table. Global flags before the verb are skipped by the shared
// resolver, so `gh -R o/r issue create` still reads as `issue create`.
function subcommandKey(argv) {
  const first = subWord(argv);
  if (first.word === null) return null;
  if (first.word === "api") return "api";
  const second = subWord(first.rest.slice(1));
  if (second.word === null) return null;
  return first.word + " " + second.word;
}

// The flag vocabulary in force for a gh argv. An unrecognized subcommand gets
// the global-only table, where every command flag reads as unknown — the caller
// then has to treat it as unresolvable rather than as a boolean.
function vocabularyFor(argv) {
  const key = subcommandKey(argv);
  if (key !== null && Object.prototype.hasOwnProperty.call(VOCABS, key)) return VOCABS[key];
  return VOCABS[""];
}

function tokenSet(specs, takesValue) {
  const out = new Set();
  for (const [short, long, isValue] of specs) {
    if (isValue !== takesValue) continue;
    if (short) out.add("-" + short);
    if (long) out.add("--" + long);
  }
  return out;
}

// Token-form views of the `gh api` table, for the api scanner (CPR-SSOT: one
// declaration of gh's flag arity, two shapes of the same facts). Must include
// GH_COMMON — `gh api` also accepts --hostname/--repo/--help, and dropping
// them here makes the scanner treat e.g. `--hostname github.com` as unknown,
// misreading the hostname value as the endpoint.
const GH_API_ALL = GH_COMMON.concat(GH_API);
const GH_API_VALUE_FLAGS = tokenSet(GH_API_ALL, true);
const GH_API_BOOL_FLAGS = tokenSet(GH_API_ALL, false);

module.exports = {
  vocabularyFor,
  subcommandKey,
  GH_API_VALUE_FLAGS,
  GH_API_BOOL_FLAGS,
};
