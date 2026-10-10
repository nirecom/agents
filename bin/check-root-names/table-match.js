"use strict";

// Table-match check (#2561): a tracked file carries only the root names its
// classification rule allows. Also owns the classification table itself — its parsing
// and the lookups the other checks use — and the four names with their spellings.

const { isTest, escapeRe } = require("./line-scan");

const SCR = "SCRIPT_CHECKOUT_ROOT";
const AMR = "AGENTS_MAIN_ROOT";
const TMR = "TARGET_MAIN_ROOT";
const TCR = "TARGET_CHECKOUT_ROOT";
const NAMES = [SCR, AMR, TMR, TCR];
const REPOS = ["agents", "dotfiles"];
const ID = "[A-Za-z0-9_]";

class TableError extends Error {}

// spellings(upper) → the four spellings of one name, derived from the upper-case one.
function spellings(upper) {
  const words = upper.toLowerCase().split("_");
  const camel = words[0] + words.slice(1).map((w) => w[0].toUpperCase() + w.slice(1)).join("");
  return { upper, camel, kebab: words.join("-"), snake: words.join("_") };
}

const bounded = (s, flags) => new RegExp(`(?<!${ID})${escapeRe(s)}(?!${ID})`, flags);

function globRe(glob) {
  let re = "";
  for (let i = 0; i < glob.length; i++) {
    if (glob.startsWith("**/", i)) {
      re += "(?:.*/)?";
      i += 2;
    } else if (glob.startsWith("**", i)) {
      re += ".*";
      i += 1;
    } else if (glob[i] === "*") re += "[^/]*";
    else if (glob[i] === "?") re += "[^/]";
    else re += escapeRe(glob[i]);
  }
  return new RegExp(`^${re}$`);
}

const isList = (v) => Array.isArray(v) && v.every((x) => typeof x === "string");

function need(ok, what) {
  if (!ok) throw new TableError(`the classification table is malformed: ${what}`);
}

// parseTable(text) → { ruleFor, grantsFor, carriers }; throws TableError on a bad shape.
function parseTable(text) {
  let data;
  try {
    data = JSON.parse(text);
  } catch {
    throw new TableError("the classification table is not valid JSON");
  }
  need(data !== null && typeof data === "object" && Array.isArray(data.rules), "rules is not a list");
  const exceptions = data.exceptions === undefined ? [] : data.exceptions;
  need(Array.isArray(exceptions), "exceptions is not a list");
  const rules = data.rules.map((r) => {
    need(r !== null && typeof r === "object", "a rule is not an object");
    need(REPOS.includes(r.repo) && typeof r.glob === "string" && r.glob !== "", "a rule lacks repo or glob");
    need(isList(r.allow) && r.allow.every((n) => NAMES.includes(n)), "a rule allows an unknown name");
    return { repo: r.repo, re: globRe(r.glob), allow: r.allow, sourced: r.sourced === true };
  });
  const fileGrants = [];
  const carriers = [];
  for (const e of exceptions) {
    need(e !== null && typeof e === "object", "an exception is not an object");
    if (typeof e.carrier === "string") {
      need(typeof e.source === "string" && isList(e.files), "a carrier lacks source or files");
      const token = e.carrier.replace(/\(\)$/, "").split(".").pop();
      carriers.push({ carrier: e.carrier, kind: e.kind, source: e.source, files: new Set(e.files), token });
    } else {
      need(typeof e.file === "string" && isList(e.allow) && isList(e.forms), "an exception lacks file, allow or forms");
      need(e.allow.every((n) => NAMES.includes(n)), "an exception allows an unknown name");
      fileGrants.push({ repo: e.repo || "agents", file: e.file, allow: e.allow, forms: e.forms });
    }
  }
  return {
    carriers,
    ruleFor: (rel, repo) => rules.find((r) => r.repo === repo && r.re.test(rel)) || null,
    // grantsFor — what the exceptions naming exactly this path add to its rule.
    grantsFor: (rel, repo) => {
      const allow = new Set();
      const forms = new Set();
      for (const g of fileGrants) {
        if (g.file !== rel || g.repo !== repo) continue;
        g.allow.forEach((n) => allow.add(n));
        g.forms.forEach((f) => forms.add(f));
      }
      return { allow, forms };
    },
  };
}

const SCR_SPELLINGS = spellings(SCR);
const QUICK = new RegExp(NAMES.map((n) => n.split("_").join("[_-]?")).join("|"), "i");

// carrierGrants(table, rel, repo) → the spellings of the checkout root this file may
// carry because a carrier lists it: the carrier's own token, plus the spellings that
// appear in the path of the carrier's source file.
function carrierGrants(table, rel, repo) {
  const granted = new Set();
  if (repo !== "agents") return granted;
  for (const c of table.carriers) {
    if (!c.files.has(rel)) continue;
    granted.add(c.token);
    for (const s of Object.values(SCR_SPELLINGS)) if (s !== SCR && c.source.includes(s)) granted.add(s);
  }
  return granted;
}

function matchers(table) {
  const list = [];
  for (const name of NAMES) {
    for (const [kind, s] of Object.entries(spellings(name))) list.push({ name, kind, spelling: s, re: bounded(s) });
  }
  // A carrier token that is not itself a spelling of a name (a function name) is tracked too.
  for (const c of table.carriers) {
    if (!list.some((m) => m.spelling === c.token)) list.push({ name: SCR, kind: "token", spelling: c.token, re: bounded(c.token) });
  }
  return list;
}

function check(ctx) {
  const table = ctx.table();
  const all = matchers(table);
  const out = [];
  for (const file of ctx.files) {
    const rule = table.ruleFor(file.rel, ctx.repo);
    if (!rule) {
      out.push(`${file.rel}: table-match: no classification rule matches this file`);
      continue;
    }
    if (file.text === null || !QUICK.test(file.text)) continue;
    const allow = new Set([...rule.allow, ...table.grantsFor(file.rel, ctx.repo).allow]);
    const granted = carrierGrants(table, file.rel, ctx.repo);
    const inTests = isTest(file.rel);
    const lines = file.text.split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
      if (!QUICK.test(lines[i])) continue;
      for (const m of all) {
        if (!m.re.test(lines[i])) continue;
        if (m.name === SCR && m.kind !== "upper") {
          if (inTests || granted.has(m.spelling)) continue;
          out.push(`${file.rel}:${i + 1}: table-match: the spelling "${m.spelling}" belongs to the files its carrier lists`);
        } else if (!allow.has(m.name)) {
          out.push(`${file.rel}:${i + 1}: table-match: ${m.name} is not allowed by the rule of this file`);
        }
      }
    }
  }
  return out;
}

module.exports = { check, parseTable, TableError, spellings, bounded, NAMES, SCR, AMR, TMR, TCR };
