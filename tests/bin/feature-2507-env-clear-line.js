"use strict";
// Tests: hooks/lib/test-gates/parts/env-clear/bash.js, hooks/lib/test-gates/parts/env-clear/js.js, hooks/lib/test-gates/parts/env-clear/pester.js, hooks/lib/test-gates/parts/env-clear/pytest.js, hooks/lib/test-language-registry.json
// Tags: TL1, bin, test-language-registry, session-id, tombstone, table-driven, golden, scope:issue-specific
// #2507 (D7): the envClearLine parts move from the bash `<lang>_env_clear_line` functions to Node
// modules, the new SSOT. fn(namesEre, line) answers 0 when the line only clears env vars the ERE
// names, 1 otherwise, printing nothing. Expected answers: golden/env-clear.tsv, made by the pre-port
// bash functions over golden/rows.txt (feature-2411 rows plus whitespace, CR, several-name, `-u`
// chain and partial-name rows); every row runs through all four parts. Retired names are spelled
// split (not tombstone-exempt). Assumed contract: envClearLine = { file: <the .js part>, function:
// <export> }; until the registry points there, the part is read through an `envClearLine` export.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { after, test } = require("node:test");

const REPO = path.join(__dirname, "..", "..");
const GOLDEN_DIR = path.join(__dirname, "feature-2507-env-clear-line", "golden");
const LANGS = ["bash", "js", "pester", "pytest"];
const partRel = (lang) => `hooks/lib/test-gates/parts/env-clear/${lang}.js`;

const restore = isolate();
after(() => restore());

const RET_S = "CLAUDE_" + "SESSION_ID";
const RET_E = "CLAUDE_" + "ENV_FILE";
const ERES = { G: `${RET_S}|${RET_E}`, O: "OTHER_VAR", M: `${RET_S}|${RET_E}|OTHER_VAR`, S1: RET_S };

function expand(line) {
  return line.split("@S@").join(RET_S).split("@E@").join(RET_E).split("@P@").join("|")
    .split("@CR@").join("\r").split("@TAB@").join("\t");
}

// rows.txt: name | ERE | line — the line is everything after the second pipe, less one leading space.
function loadRows() {
  const rows = new Map();
  // A raw CR is never row content (@CR@ spells it), so a CRLF checkout reads the same.
  for (const raw of fs.readFileSync(path.join(GOLDEN_DIR, "rows.txt"), "utf8").split(/\r?\n/)) {
    if (raw === "" || raw.startsWith("#")) continue;
    const a = raw.indexOf("|");
    const b = raw.indexOf("|", a + 1);
    const name = raw.slice(0, a).trim();
    const ere = raw.slice(a + 1, b).trim();
    let line = raw.slice(b + 1);
    if (line.startsWith(" ")) line = line.slice(1);
    rows.set(name, { name, ere, line: expand(line) });
  }
  return rows;
}

function loadGolden() {
  const out = [];
  for (const raw of fs.readFileSync(path.join(GOLDEN_DIR, "env-clear.tsv"), "utf8").split(/\r?\n/)) {
    if (raw === "" || raw.startsWith("#")) continue;
    const [name, ere, ...rcs] = raw.split("\t");
    out.push({ name, ere, want: Object.fromEntries(LANGS.map((l, i) => [l, Number(rcs[i])])) });
  }
  return out;
}

const ROWS = loadRows();
const GOLDEN = loadGolden();

function registryEntry(lang) {
  const reg = JSON.parse(fs.readFileSync(path.join(REPO, "hooks", "lib", "test-language-registry.json"), "utf8"));
  return reg.entries.find((e) => e.id === lang);
}

// The part's function: the registry's name once the registry points at the Node part, else envClearLine.
function loadPart(lang) {
  const mod = require(path.join(REPO, partRel(lang)));
  const spec = (registryEntry(lang) || {}).envClearLine || {};
  const name = spec.file === partRel(lang) ? spec.function : "envClearLine";
  const fn = typeof mod === "function" ? mod : mod[name];
  assert.strictEqual(typeof fn, "function", `${partRel(lang)} exports no function ${name}`);
  return fn;
}

// Calls fn with process.stdout.write trapped, so a part that prints is caught.
function callQuiet(fn, ere, line) {
  const orig = process.stdout.write;
  let printed = "";
  process.stdout.write = (s) => { printed += String(s); return true; };
  try {
    return { rc: fn(ere, line), printed };
  } finally {
    process.stdout.write = orig;
  }
}

function checkLang(lang) {
  const fn = loadPart(lang);
  const bad = [];
  for (const g of GOLDEN) {
    const row = ROWS.get(g.name);
    assert.ok(row, `golden row ${g.name} has no corpus line in rows.txt`);
    assert.ok(ERES[g.ere], `golden row ${g.name}: unknown ERE code ${g.ere}`);
    const { rc, printed } = callQuiet(fn, ERES[g.ere], row.line);
    if (rc !== g.want[lang] || printed !== "") {
      bad.push(`${g.name}: got ${JSON.stringify(rc)} printed=${printed.length} want ${g.want[lang]} line=${JSON.stringify(row.line)}`);
    }
  }
  assert.deepStrictEqual(bad, [], `${lang} part differs from the bash golden on ${bad.length} row(s)`);
}

test("the golden and the corpus line up (row names, ERE codes, rc values)", () => {
  assert.ok(GOLDEN.length >= 120, `golden has ${GOLDEN.length} rows`);
  assert.strictEqual(GOLDEN.length, ROWS.size, "every corpus row has exactly one golden row");
  for (const g of GOLDEN) {
    for (const l of LANGS) assert.ok(g.want[l] === 0 || g.want[l] === 1, `${g.name} ${l}: ${g.want[l]}`);
  }
});

caseBegin("node-bash-env-clear-line-golden", "hooks/lib/test-gates/parts/env-clear/bash.js");
test("bash part: every golden row (unset, -u chains, CR kept, partial names)", () => checkLang("bash"));
caseEnd();

caseBegin("node-js-env-clear-line-golden", "hooks/lib/test-gates/parts/env-clear/js.js");
test("js part: every golden row (delete process.env, CR stripped)", () => checkLang("js"));
caseEnd();

caseBegin("node-pester-env-clear-line-golden", "hooks/lib/test-gates/parts/env-clear/pester.js");
test("pester part: every golden row (Remove-Item Env:, switches, CR stripped)", () => checkLang("pester"));
caseEnd();

caseBegin("node-pytest-env-clear-line-golden", "hooks/lib/test-gates/parts/env-clear/pytest.js");
test("pytest part: every golden row (os.environ.pop, both quotes, CR stripped)", () => checkLang("pytest"));
caseEnd();

caseBegin("registry-env-clear-line-points-at-node-part", "hooks/lib/test-language-registry.json");
test("each supported entry's envClearLine names the Node part and one of its exports", () => {
  for (const lang of LANGS) {
    const spec = (registryEntry(lang) || {}).envClearLine;
    assert.ok(spec, `${lang}: envClearLine missing`);
    assert.strictEqual(spec.file, partRel(lang), `${lang}: envClearLine.file`);
    const mod = require(path.join(REPO, spec.file));
    assert.strictEqual(typeof mod[spec.function], "function", `${lang}: ${spec.function} is not exported`);
  }
});
caseEnd();
