"use strict";
// T5-1 part of tests/bin/feat-2529-glossary-drift.js (#2529). Holds no case markers; the
// entrypoint wraps run() in one.
// Six stages × four variant kinds (case, hyphen, plural with a hyphen, merged) each give a DRIFT
// line, and a regular plural line gives none; the R-S stages read the staged blob, never the
// working tree; an intent `## Issues` variant is not scanned.

const VARIANTS = [["case", "Glossary Drift"], ["hyphen", "glossary-drift"], ["plural with a hyphen", "glossary-drifts"],
  ["merged", "glossarydrift"]];
const PLURAL = "glossary drifts";
const line = (v) => `Mid-line the ${v} shows up here.`;
const lineOf = (text, needle) => text.split("\n").findIndex((l) => l.includes(needle)) + 1;

// Where each stage's artifact lives, and the text of each file it is made of.
function artifactFor(F, stage, sid, lines) {
  if (stage === "intent") return [{ suffix: "intent", text: F.intentBody({ goal: lines.join("\n\n") }) }];
  if (stage === "outline" || stage === "detail") {
    return [{ suffix: stage, text: `# Plan\n\n## Approach\n\n${lines.join("\n\n")}\n` }];
  }
  const js = (ls) => `"use strict";\n${ls.map((l) => `// ${l}`).join("\n")}\nmodule.exports = 1;\n`;
  if (stage === "tests") return [{ rel: "tests/t.js", text: js(lines) }];
  if (stage === "code") {
    return [{ rel: "skills/x/SKILL.md", text: `# Skill\n\n${lines[0]}\n` }, { rel: "bin/a.js", text: js(lines.slice(1)) }];
  }
  return [{ rel: "docs/guide.md", text: `# Guide\n\n${lines.join("\n\n")}\n` }];
}

function placeArtifact(F, repo, sid, files) {
  for (const f of files) {
    if (f.suffix) F.writePlan(sid, f.suffix, f.text);
    else F.stageFile(repo, f.rel, f.text);
  }
}

function perStage(F) {
  for (const stage of F.STAGES) {
    const repo = F.mkRepo(`v-${stage}`);
    const sid = F.newSid(`v-${stage}`);
    const lines = VARIANTS.map(([, v]) => line(v)).concat([line(PLURAL)]);
    const files = artifactFor(F, stage, sid, lines);
    placeArtifact(F, repo, sid, files);
    F.seedAt(sid, F.STAGE_STEP[stage], repo);
    const r = F.drift(sid, stage, repo, false);
    F.check(`T5-1 ${stage}: check-glossary-drift runs and exits 1`, F.reached(r) && r.code === 1, `code=${r.code} ${r.all}`);
    const found = F.driftLines(r.all);
    for (const [kind, v] of VARIANTS) {
      const f = files.find((x) => x.text.includes(line(v)));
      const want = { stage, variant: v, term: F.TERM, line: lineOf(f.text, line(v)) };
      const tail = f.suffix ? `${sid}-${f.suffix}.md` : f.rel;
      const hit = found.find((d) => d.stage === stage && d.variant === v && d.term === F.TERM &&
        d.line === want.line && d.file.endsWith(tail));
      F.check(`T5-1 ${stage} × ${kind}: DRIFT "${v}" -> "${F.TERM}" at ${tail}:${want.line}`, !!hit, r.all);
    }
    const pf = files.find((x) => x.text.includes(line(PLURAL)));
    const pTail = pf.suffix ? `${sid}-${pf.suffix}.md` : pf.rel;
    const pLine = lineOf(pf.text, line(PLURAL));
    const pHits = found.filter((d) => d.line === pLine && d.file.endsWith(pTail));
    F.check(`T5-1 ${stage} × regular plural: no DRIFT at ${pTail}:${pLine}`, F.reached(r) && pHits.length === 0, JSON.stringify(pHits));
  }
}

// R-S: the staged blob is the artifact. Working-tree-only variant → clean; staged-only → DRIFT.
const RS_TARGET = {
  tests: ["tests/t.js", (l) => `"use strict";\n// ${l}\nmodule.exports = 1;\n`],
  code: ["bin/a.js", (l) => `"use strict";\n// ${l}\nmodule.exports = 1;\n`],
  docs: ["docs/guide.md", (l) => `# Guide\n\n${l}\n`],
};
function stagedBlob(F) {
  for (const stage of F.RS_STAGES) {
    const [rel, body] = RS_TARGET[stage];
    const clean = body(line(F.TERM));
    const dirty = body(line("glossary-drift"));

    const repoA = F.mkRepo(`sw-${stage}`);
    const sidA = F.newSid(`sw-${stage}`);
    F.stageFile(repoA, rel, clean);
    F.writeFile(repoA, rel, dirty);
    F.seedAt(sidA, F.STAGE_STEP[stage], repoA);
    const a = F.drift(sidA, stage, repoA, false);
    F.check(`T5-1 ${stage}: variant only in the working tree → exit 0, no DRIFT`,
      F.reached(a) && a.code === 0 && F.driftLines(a.all).length === 0, `code=${a.code} ${a.all}`);

    const repoB = F.mkRepo(`ss-${stage}`);
    const sidB = F.newSid(`ss-${stage}`);
    F.stageFile(repoB, rel, dirty);
    F.writeFile(repoB, rel, clean);
    F.seedAt(sidB, F.STAGE_STEP[stage], repoB);
    const b = F.drift(sidB, stage, repoB, false);
    const hit = F.driftLines(b.all).find((d) => d.variant === "glossary-drift" && d.file.endsWith(rel));
    F.check(`T5-1 ${stage}: variant only in the staged blob → exit 1 with DRIFT at ${rel}`,
      F.reached(b) && b.code === 1 && !!hit, `code=${b.code} ${b.all}`);
  }
}

function issuesOnly(F) {
  const repo = F.mkRepo("issues");
  const sid = F.newSid("issues");
  F.writeIntent(sid, { goal: line(F.TERM), issues: `- #1 ${line("glossary-drift")}` });
  F.seedAt(sid, "clarify_intent", repo);
  const r = F.drift(sid, "intent", repo, false);
  F.check("T5-1 intent: a variant only under ## Issues → exit 0, no DRIFT",
    F.reached(r) && r.code === 0 && F.driftLines(r.all).length === 0, `code=${r.code} ${r.all}`);
}

// Review round 7 F1: the variant match compares the separator-stripped form whatever the word
// count, so a split single-word term and a merged multi-word term are variants too. Owner
// decision (round 8): a whitespace break only where the term has a word break, so ordinary
// English (`set up`, `in form`) is no variant of a one-word term; a hyphen split still is.
const SPLIT_MERGE = [
  ["single-word term split by a hyphen", ["workflow"], "the work-flow here", ["work-flow"]],
  ["single-word term split by a space (not a variant)", ["workflow"], "the work flow here", []],
  ["single-word term split and pluralized", ["workflow"], "the work-flows here", ["work-flows"]],
  ["single-word term split with case change", ["workflow"], "the Work-Flow here", ["Work-Flow"]],
  ["capital word never matches a lower-case term (not a variant)", ["workflow"], "the WORKFLOW here", []],
  ["single-word term split by a tab (not a variant)", ["workflow"], "the work\tflow here", []],
  ["single-word term split by a space and pluralized (not a variant)", ["workflow"], "the work flows here", []],
  ["ordinary English `set up` for setup", ["setup"], "please set up the repo", []],
  ["ordinary English `in form` for inform", ["inform"], "keep it in form here", []],
  ["setup split by a hyphen", ["setup"], "the set-up here", ["set-up"]],
  ["multi-word term spaced at its own break", ["presentation turn"], "the Presentation Turn here", ["Presentation Turn"]],
  ["multi-word term hyphenated at its own break", ["presentation turn"], "the presentation-turn here", ["presentation-turn"]],
  ["multi-word term with a space inside a word (not a variant)", ["presentation turn"], "the present ation turn here", []],
  ["multi-word term merged", ["glossary drift"], "the glossarydrift here", ["glossarydrift"]],
  ["multi-word term hyphenated (unchanged)", ["glossary drift"], "the glossary-drift here", ["glossary-drift"]],
  ["multi-word term with a regular plural (not a variant)", ["glossary drift"], "the glossary drifts", []],
  ["exact single-word spelling", ["workflow"], "the workflow here", []],
  ["exact multi-word spelling", ["glossary drift"], "the glossary drift here", []],
  ["exact spelling at a sentence start", ["workflow"], "Workflow starts here", []],
  ["split form that is itself a term", ["workflow", "work flow"], "the work flow here", []],
  ["identifier with an underscore", ["workflow"], "the work_flow here", []],
  ["sentence break between the parts", ["workflow"], "the work. flow here", []],
  ["spaced dash between the parts", ["workflow"], "the work - flow here", []],
  ["longer word that ends in the part", ["workflow"], "the network flow here", []],
  ["-us singular as a capital word (not a variant)", ["status"], "the STATUS here", []],
  ["-uses regular plural of a -us term (not a variant)", ["status"], "the statuses here", []],
  ["-uses plural, title case mid-sentence", ["status"], "the Statuses here", ["Statuses"]],
  ["-uses plural as a capital word (not a variant)", ["status"], "the STATUSES here", []],
  ["-yses plural of a -sis term", ["analysis"], "the Analyses here", ["Analyses"]],
  ["exact -us spelling", ["status"], "the status here", []],
];
// Identifier terms (one with `_`) follow the identifier context of the matching rules:
// docs/architecture/claude-code/glossary-check.md#matching-rules (SSOT).
const ID = ["AGENTS_MAIN_ROOT"];
const IDENT = [
  ["exact spelling", ID, "set AGENTS_MAIN_ROOT here", []],
  ["exact spelling at a sentence start", ID, "AGENTS_MAIN_ROOT is set", []],
  ["lower case, same separators (naming convention)", ID, "set agents_main_root here", []],
  ["title case, same separators (naming convention)", ID, "set Agents_Main_Root here", []],
  ["space-split, lower case", ID, "set agents main root here", ["agents main root"]],
  ["space-split, capitals", ID, "set AGENTS MAIN ROOT here", ["AGENTS MAIN ROOT"]],
  ["hyphen-split", ID, "set agents-main-root here", ["agents-main-root"]],
  ["merged, lower case", ID, "set agentsmainroot here", ["agentsmainroot"]],
  ["merged, capitals (naming convention)", ID, "set AGENTSMAINROOT here", []],
  ["mixed underscore and hyphen (naming convention)", ID, "set AGENTS_MAIN-ROOT here", []],
  ["mixed underscore and space", ID, "set agents_main root here", ["agents_main root"]],
  ["camelCase (not a variant)", ID, "set agentsMainRoot here", []],
  ["PascalCase (not a variant)", ID, "set AgentsMainRoot here", []],
  ["a space inside a word (not a variant)", ID, "set agen tsmainroot here", []],
  ["a longer identifier (not a variant)", ID, "set AGENTS_MAIN_ROOT_DIR here", []],
  ["code span is identifier context, naming convention is no variant", ID, "set `agents_main_root` here", []],
  ["known false positive: ordinary English", ["USER_VERIFIED"], "the user verified the fix", ["user verified"]],
  ["per-word singular form is a variant", ["WORKTREE_NOTES"], "the WORKTREE_NOTE here", ["WORKTREE_NOTE"]],
];

// The findDrift export, or null with the red reason logged.
function findDriftOf(F) {
  const drift = F.mod("bin/lib/glossary-drift.js");
  if (!drift) return null;
  if (typeof drift.findDrift === "function") return drift.findDrift;
  F.check("bin/lib/glossary-drift.js exports findDrift", false, Object.keys(drift).join(","));
  return null;
}

function table(F, label, rows) {
  const findDrift = findDriftOf(F);
  if (!findDrift) return;
  for (const [name, terms, text, want] of rows) {
    const got = findDrift(text, "markdown", terms).map((h) => h.variant);
    F.check(`T5-1 findDrift ${label}${name}: ${JSON.stringify(text)} -> ${JSON.stringify(want)}`,
      JSON.stringify(got) === JSON.stringify(want), JSON.stringify(got));
  }
}

// Review round 9: terms sharing a compact key are attributed by the variant's word breaks and
// separators, never by load order; each case runs with the terms in both orders.
const COLLIDE = [
  ["space split goes to the spaced term", ["workflow", "work flow"], "the Work Flow here", [["work flow", "Work Flow"]]],
  ["hyphen split goes to the one-word term", ["workflow", "work flow"], "the Work-Flow here", [["workflow", "Work-Flow"]]],
  ["inner capital goes to the one-word term", ["workflow", "work flow"], "the WorkFlow here", [["workflow", "WorkFlow"]]],
  ["exact spelling of either term", ["workflow", "work flow"], "the workflow and the work flow here", []],
  ["sentence start of the spaced term", ["workflow", "work flow"], "Work flow starts here", []],
  ["hyphen split goes to the hyphenated term", ["work-flow", "work flow"], "the Work-Flow here", [["work-flow", "Work-Flow"]]],
  ["space split goes to the spaced term", ["work-flow", "work flow"], "the Work Flow here", [["work flow", "Work Flow"]]],
  ["merged form ties, sorted order breaks it", ["work-flow", "work flow"], "the workflow here", [["work flow", "workflow"]]],
];
function collisions(F) {
  const findDrift = findDriftOf(F);
  if (!findDrift) return;
  for (const [name, terms, text, want] of COLLIDE) {
    for (const order of [terms, terms.slice().reverse()]) {
      const got = findDrift(text, "markdown", order).map((h) => [h.term, h.variant]);
      F.check(`T5-1 findDrift collision ${name} ${JSON.stringify(order)}: ${JSON.stringify(text)} -> ${JSON.stringify(want)}`,
        JSON.stringify(got) === JSON.stringify(want), JSON.stringify(got));
    }
  }
}

// Owner decision (round 8, round 9): a term an intent row deletes is no longer canonical, so its
// variants are no DRIFT even while the glossary file still lists it; an add / redefine row's term
// still is checked, and so is a delete + add of the same term (a category move).
const ROWS = [
  ["delete row", [], [["workflow", "delete"]], []],
  ["add row", [], [["workflow", "add"]], ["work-flow"]],
  ["redefine row", [], [["workflow", "redefine"]], ["work-flow"]],
  ["delete row of a term still in the glossary file", ["workflow"], [["workflow", "delete"]], []],
  ["delete row in another case than the glossary file", ["Workflow"], [["workflow", "delete"]], []],
  ["delete row of another term", ["workflow"], [["setup", "delete"]], ["work-flow"]],
  ["delete + add of the same term (category move)", ["workflow"], [["workflow", "delete", "user"], ["workflow", "add", "internal"]], ["work-flow"]],
];
function deleteRows(F) {
  const drift = F.mod("bin/lib/glossary-drift.js");
  if (!drift) return;
  for (const [name, fileTerms, rows, want] of ROWS) {
    const got = drift.scanStageInputs({
      glossary: { terms: fileTerms },
      intentRows: { rows: rows.map(([term, operation, category]) => ({ term, operation, category: category || "user" })) },
      artifact: { files: [{ path: "a.md", kind: "markdown", text: "the work-flow here\n" }] },
    }).map((h) => h.variant);
    F.check(`T5-1 scanStageInputs ${name}: -> ${JSON.stringify(want)}`, JSON.stringify(got) === JSON.stringify(want), JSON.stringify(got));
  }
}

// A delete row removes only the glossary terms of its own spelling (trimmed, case-insensitive),
// never every term with the same normalizeTerm form. Rows: [name, fileTerms, rows, text, [[term, variant]]].
const SPELLING_ROWS = [
  ["delete of the plural keeps the singular", ["workflow", "workflows"], [["workflows", "delete"]], "the Workflow here", [["workflow", "Workflow"]]],
  ["delete of the plural in another case", ["workflow", "workflows"], [["Workflows", "delete"]], "the Workflow here", [["workflow", "Workflow"]]],
  ["delete in another case removes the term", ["workflows"], [["Workflows", "delete"]], "the Workflows here", []],
  ["delete with padding and capitals removes the term", ["Workflow"], [["  WORKFLOW ", "delete"]], "the work-flow here", []],
  ["delete of the plural leaves a lone singular", ["workflow"], [["workflows", "delete"]], "the work-flow here", [["workflow", "work-flow"]]],
  ["delete + add of the same spelling keeps it", ["workflows"], [["workflows", "delete"], ["workflows", "add"]], "the Workflows here", [["workflows", "Workflows"]]],
  ["no delete row: both spellings stay exact", ["workflow", "workflows"], [], "the workflow and the workflows here", []],
];
function deleteSpelling(F) {
  const drift = F.mod("bin/lib/glossary-drift.js");
  if (!drift) return;
  for (const [name, fileTerms, rows, text, want] of SPELLING_ROWS) {
    const got = drift.scanStageInputs({
      glossary: { terms: fileTerms },
      intentRows: { rows: rows.map(([term, operation]) => ({ term, operation, category: "user" })) },
      artifact: { files: [{ path: "a.md", kind: "markdown", text: `${text}\n` }] },
    }).map((h) => [h.term, h.variant]);
    F.check(`T5-1 scanStageInputs delete spelling ${name}: -> ${JSON.stringify(want)}`,
      JSON.stringify(got) === JSON.stringify(want), JSON.stringify(got));
  }
}

// #2529 C2: no copyable accept command for a term holding a forbidden character. Of those, only a
// control character (a tab) still yields a deterministic finding, so the tab term stands for them.
const ACCEPT_ROWS = [
  ["safe term (control) keeps its accept command", "glossary drift", true],
  ["tab-holding term gets no accept command", "glossary\tdrift", false],
];
function forbiddenAccept(F) {
  for (const [name, term, wantAccept] of ACCEPT_ROWS) {
    const repo = F.mkRepo("acc", { "docs/glossary/user.md": `# Glossary — user terms\n\n${F.entry(term, "A fixture term.")}`,
      "docs/glossary/internal.md": `# Glossary — internal terms\n\n${F.entry(F.TERM2, "The per-round list of review concerns.")}` });
    const sid = F.newSid("acc");
    F.writeIntent(sid, { rows: [["scratch", "session", "add", "A session word."]] });
    F.writePlan(sid, "outline", "# Plan\n\n## Approach\n\nMid-line the Glossary-Drift shows up here.\n");
    F.seedAt(sid, "outline", repo);
    const r = F.drift(sid, "outline", repo, false);
    const accepts = r.all.split(/\r?\n/).filter((l) => l.includes("echo \"<<WORKFLOW_GLOSSARY_ACCEPTED") && l.includes(`term=${term} `));
    F.check(`T5-1 accept line ${name}: exit nonzero`, F.reached(r) && r.code !== 0, `code=${r.code} ${r.all}`);
    F.check(`T5-1 accept line ${name}: ${wantAccept ? "printed" : "omitted"}`, (accepts.length > 0) === wantAccept, r.all);
  }
}

function run(F) {
  forbiddenAccept(F);
  perStage(F);
  stagedBlob(F);
  issuesOnly(F);
  table(F, "", SPLIT_MERGE);
  table(F, "identifier ", IDENT);
  collisions(F);
  deleteRows(F);
  deleteSpelling(F);
}

module.exports = { run };
