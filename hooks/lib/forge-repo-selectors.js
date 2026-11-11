"use strict";
// hooks/lib/forge-repo-selectors.js — pure readers of the repository a gh command names
// (--repo / -R selectors, --hostname), shared by confirm-forge-target-ownership and
// protect-user-block. A value that cannot be read literally is unresolved, never assumed.
const { extractRepoSelectors, extractRepoFlag } = require("./forge-write-extract");
const { isValidOwner, isValidRepo, GITHUB_HOST } = require("./parse-remote-url");

const NON_LITERAL_RE = /[$`]/;

function unresolved(why) {
  return { kind: "unresolved", why };
}

function hostIsGithub(value) {
  return typeof value === "string" && value.trim().toLowerCase() === GITHUB_HOST;
}

// `--hostname` as gh itself reads it: a separated value, or an attached one —
// and, when the flag is repeated, the LAST occurrence, which is the value pflag
// hands gh and the rule every other duplicate-flag reader here already applies.
function hostSelector(argv, argvRaw) {
  const list = Array.isArray(argv) ? argv : [];
  const raws = Array.isArray(argvRaw) ? argvRaw : list;
  let found = { present: false, value: null, raw: null };
  for (let i = 0; i < list.length; i++) {
    const tok = list[i];
    if (typeof tok !== "string") continue;
    if (tok === "--hostname") {
      const next = i + 1 < list.length ? list[i + 1] : null;
      found = { present: true, value: typeof next === "string" ? next : null, raw: raws[i + 1] };
    } else if (tok.indexOf("--hostname=") === 0) {
      found = { present: true, value: tok.slice("--hostname=".length), raw: raws[i] };
    }
  }
  return found;
}

function hostSelectorIsGithub(sel) {
  if (!sel || !sel.present) return true;
  if (typeof sel.raw === "string" && NON_LITERAL_RE.test(sel.raw)) return false;
  return hostIsGithub(sel.value);
}

// The repo selectors on a command, paired with the RAW spelling of each value so
// a substituted or variable value can be told from a literal one.
function repoSelectors(argv, argvRaw) {
  const list = Array.isArray(argv) ? argv : [];
  const raws = Array.isArray(argvRaw) ? argvRaw : list;
  return extractRepoSelectors(list).map((s) => {
    const separated = s.form === "long-separated" || s.form === "short-separated";
    const rawIndex = separated ? s.index + 1 : s.index;
    return { value: s.value, form: s.form, raw: typeof raws[rawIndex] === "string" ? raws[rawIndex] : null };
  });
}

// Split a selector into owner/repo, honouring gh's own [HOST/]OWNER/REPO form.
// A three-segment value is a HOST-qualified name; read as OWNER/REPO it would
// become a repo named "OWNER/REPO" under an owner named after the host.
function splitSelector(value) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (trimmed === "" || /:\/\//.test(trimmed)) return null;
  const segs = trimmed.split("/");
  let owner = null;
  let repo = null;
  if (segs.length === 2) { owner = segs[0]; repo = segs[1]; }
  else if (segs.length === 3 && segs[0].toLowerCase() === GITHUB_HOST) { owner = segs[1]; repo = segs[2]; }
  else return null;
  if (!isValidOwner(owner) || !isValidRepo(repo)) return null;
  return owner + "/" + repo;
}

function resolveSelectors(selectors, rawText) {
  if (!selectors.length) return null;
  for (const s of selectors) {
    if (s.value === null) return unresolved("the --repo selector carries no readable value");
    if (typeof s.raw === "string" && NON_LITERAL_RE.test(s.raw)) {
      return unresolved("the --repo selector is not a literal value, so its target cannot be read");
    }
  }
  const distinct = [];
  for (const s of selectors) {
    const key = String(s.value).trim().toLowerCase();
    if (distinct.indexOf(key) === -1) distinct.push(key);
  }
  if (distinct.length > 1) return unresolved("the command names more than one repository selector");
  const value = String(selectors[0].value).trim();
  const flagValue = extractRepoFlag(rawText);
  if (typeof flagValue === "string" && flagValue.trim() !== "" && flagValue.trim() !== value) {
    return unresolved("the --repo selector does not read the same way twice");
  }
  const ownerRepo = splitSelector(value);
  if (!ownerRepo) return unresolved("the --repo selector is not a valid OWNER/REPO on github.com");
  return { kind: "explicit", ownerRepo };
}

module.exports = {
  NON_LITERAL_RE,
  unresolved,
  hostIsGithub,
  hostSelector,
  hostSelectorIsGithub,
  repoSelectors,
  splitSelector,
  resolveSelectors,
};
