#!/usr/bin/env node
// tests/hooks/feature-2631-size-limits.js
// Tests: hooks/lib/size-limits.js, hooks/lib/size-classify.js, hooks/lib/size-session-gate.js, bin/print-size-limits, rules/coding/file-split.md, templates/progress.md
// Tags: scope:issue-specific, size-limits, file-split, ssot, layer:TL2
// TL3 gap (what this test does NOT catch):
// - the real Claude Code host and git calling these predicates (the sibling feature-2631 hook tests drive them)
// Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
// via bin/check-verification-gate.sh category: hook-registration.
"use strict";
// #2631 stage 1: one SSOT for every size limit (code, prompt, docs, history, intent, outline,
// detail, progress) and the shared predicates the edit-time, CONFIRM and commit paths call.
// Verdict contract: post > HARD is "hard" unless post < pre ("shrink"); WARN < post <= HARD is "warn".
// The bin/size-check CLI (L9) lives in feature-2631-precommit-size-gate-cli.sh (size-check-* cases).

const fs = require("fs");
const path = require("path");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const restore = isolate();
const savedCwd = process.cwd();
const F = require("./feature-2631-size-limits/fixture");
process.chdir(F.work());

const SL = () => F.load("hooks/lib/size-limits.js");
const SC = () => F.load("hooks/lib/size-classify.js");
const EXTS = ["js", "sh", "py"];

caseBegin("limits-table-is-the-ssot", "hooks/lib/size-limits.js");
F.run("LIMITS", () => {
  const { LIMITS } = SL();
  for (const [kind, [warn, hard, unit]] of Object.entries(F.EXPECTED)) {
    const l = LIMITS[kind] || {};
    F.check(`LIMITS.${kind} = ${warn}/${hard} ${unit}`, l.warn === warn && l.hard === hard && l.unit === unit, JSON.stringify(l));
  }
  F.check("LIMITS.history carries role rotation", (LIMITS.history || {}).role === "rotation", JSON.stringify(LIMITS.history));
  F.check("LIMITS has exactly the 8 kinds", Object.keys(LIMITS).sort().join(",") === Object.keys(F.EXPECTED).sort().join(","),
    Object.keys(LIMITS).join(","));
});
caseEnd();

caseBegin("L1-count-lines", "hooks/lib/size-limits.js");
F.run("countLines", () => {
  const { countLines, measure } = SL();
  for (const [text, want] of [["", 0], ["a", 1], ["a\n", 1], ["a\nb", 2], ["a\nb\n", 2], ["a\r\nb\r\n", 2], ["a\r\nb", 2], ["\n", 1]]) {
    F.check(`countLines(${JSON.stringify(text)}) = ${want}`, countLines(text) === want, countLines(text));
  }
  F.check("measure(code) uses countLines", measure("code", "a\nb") === 2, measure("code", "a\nb"));
  F.check("measure(detail) uses countLines", measure("detail", F.proseLines(7)) === 7, measure("detail", F.proseLines(7)));
});
caseEnd();

caseBegin("L2-current-state-chars", "hooks/lib/size-limits.js");
F.run("currentStateChars", () => {
  const { currentStateChars, measure } = SL();
  const cases = [
    ["next ## heading ends the section", "## Current state\n\nabc\n\n## Plan files\nzzzzzz\n", 3],
    ["### does not end the section", "## Current state\nab\n### Sub\ncd\n## Next\nqq\n", 13],
    ["surrounding whitespace trimmed, EOF ends", "# t\n\n## Current state\n\n   hello  \n\n", 5],
    ["surrogate pair is one char", "## Current state\n😀😀\n## X\n", 2],
    ["missing section is 0", "# t\n\n## Plan files\n\n- a\n", 0],
    ["fixture builder is exact", F.progressDoc(401), 401],
  ];
  for (const [name, text, want] of cases) {
    const got = currentStateChars(text);
    F.check(`currentStateChars: ${name}`, got === want, `want ${want} got ${got}`);
  }
  F.check("measure(progress) = currentStateChars", measure("progress", F.progressDoc(600)) === 600, measure("progress", F.progressDoc(600)));
});
caseEnd();

caseBegin("L3-boundaries-all-kinds", "hooks/lib/size-limits.js");
F.run("judge boundaries", () => {
  const { judge } = SL();
  for (const [kind, [w, h]] of Object.entries(F.EXPECTED)) {
    const rows = [[w - 1, "ok"], [w, "ok"], [w + 1, "warn"], [h - 1, "warn"], [h, "warn"], [h + 1, "hard"]];
    for (const [v, want] of rows) {
      const r = judge(kind, 0, v) || {};
      F.check(`judge(${kind}, 0, ${v}) = ${want}`, r.verdict === want, JSON.stringify(r));
    }
  }
});
caseEnd();

caseBegin("L4-shrink-exception", "hooks/lib/size-limits.js");
F.run("judge shrink", () => {
  const { judge } = SL();
  for (const [kind, [, h]] of Object.entries(F.EXPECTED)) {
    const v = (pre, post) => (judge(kind, pre, post) || {}).verdict;
    F.check(`${kind}: pre HARD+10 -> post HARD+5 is shrink`, v(h + 10, h + 5) === "shrink", v(h + 10, h + 5));
    F.check(`${kind}: pre = post = HARD+1 is hard`, v(h + 1, h + 1) === "hard", v(h + 1, h + 1));
    F.check(`${kind}: pre HARD+1 -> post HARD+2 is hard`, v(h + 1, h + 2) === "hard", v(h + 1, h + 2));
    F.check(`${kind}: new file (pre 0) at HARD+1 is hard`, v(0, h + 1) === "hard", v(0, h + 1));
  }
});
caseEnd();

caseBegin("L5-fragment-deltas", "hooks/lib/size-limits.js");
F.run("deltas", () => {
  const { newlineDelta, codePointDelta } = SL();
  const less = [{ old_string: "a\nb\nc\n", new_string: "a\n" }];
  const more = [{ old_string: "a\n", new_string: "a\nb\nc\n" }];
  const same = [{ old_string: "a\nb", new_string: "x\ny" }];
  F.check("newlineDelta < 0 when lines are removed", newlineDelta(less) < 0, newlineDelta(less));
  F.check("newlineDelta > 0 when lines are added", newlineDelta(more) > 0, newlineDelta(more));
  F.check("newlineDelta = 0 for a same-shape edit", newlineDelta(same) === 0, newlineDelta(same));
  F.check("codePointDelta < 0 when text shrinks", codePointDelta([{ old_string: "abcd", new_string: "a" }]) < 0, "");
  F.check("codePointDelta > 0 when text grows", codePointDelta([{ old_string: "a", new_string: "abcd" }]) > 0, "");
  F.check("codePointDelta counts a surrogate pair as 1",
    codePointDelta([{ old_string: "ab", new_string: "😀" }]) === -1, codePointDelta([{ old_string: "ab", new_string: "😀" }]));
  // A replace_all growth repeats an unknown number of times: it must never net out into a decrease.
  const mixed = [{ old_string: "x", new_string: "x\ny\nz", replace_all: true }, { old_string: "a\nb\nc\nd", new_string: "a" }];
  F.check("newlineDelta: replace_all growth is not reported as a decrease", newlineDelta(mixed) >= 0, newlineDelta(mixed));
  const mixedCp = [{ old_string: "x", new_string: "xyz", replace_all: true }, { old_string: "abcdef", new_string: "a" }];
  F.check("codePointDelta: replace_all growth is not reported as a decrease", codePointDelta(mixedCp) >= 0, codePointDelta(mixedCp));
  F.check("newlineDelta: a pure replace_all removal is still a decrease",
    newlineDelta([{ old_string: "a\nb", new_string: "a", replace_all: true }]) < 0, "");
});
caseEnd();

caseBegin("L6-classify-repo-path", "hooks/lib/size-classify.js");
F.run("classifyRepoPath", () => {
  const { classifyRepoPath, matchesKind } = SC();
  const rows = [
    ["skills/foo/SKILL.md", "prompt"], ["rules/coding/file-split.md", "prompt"], ["agents/planner.md", "prompt"],
    ["skills/_shared/test-design.md", "prompt"], ["docs/architecture/x.md", "docs"], ["README.md", "docs"],
    ["hooks/a.js", "code"], ["bin/tool.py", "code"], ["install.sh", "code"], ["notes.txt", null], ["hooks/a.ts", null],
    ["docs/history.md", null], ["CHANGELOG.md", null], ["docs/_archive/old.md", null], ["skills/_archived/x/SKILL.md", null],
    ["docs/history/2026.md", null], ["changelog/2026.md", null], ["hooks/_archive/a.js", null],
  ];
  for (const [rel, want] of rows) {
    const got = classifyRepoPath(rel, EXTS);
    F.check(`classifyRepoPath(${rel}) = ${want}`, (got == null ? null : got) === want, got);
  }
  F.check("exts decide code: a.ts with [ts] is code", classifyRepoPath("hooks/a.ts", ["ts"]) === "code", classifyRepoPath("hooks/a.ts", ["ts"]));
  F.check("matchesKind(docs) keeps every non-exempt .md (prompt files too)", matchesKind("docs", "rules/x.md", EXTS) === true, "");
  F.check("matchesKind(docs) drops exempt history.md", matchesKind("docs", "docs/history.md", EXTS) === false, "");
  F.check("matchesKind(prompt) drops a plain docs file", matchesKind("prompt", "docs/a.md", EXTS) === false, "");
  F.check("matchesKind(code) follows exts", matchesKind("code", "a.js", EXTS) === true && matchesKind("code", "a.md", EXTS) === false, "");
});
F.run("isExemptRepoPath", () => {
  const { isExemptRepoPath } = SL();
  for (const rel of ["docs/history.md", "CHANGELOG.md", "x/_archive/a.md", "x/_archived/a.md", "docs/history/2026.md", "changelog/2026.md"]) {
    F.check(`isExemptRepoPath(${rel})`, isExemptRepoPath(rel) === true, "");
  }
  for (const rel of ["docs/a.md", "hooks/history.js", "docs/historyx/a.md", "bin/history/tool.js", "hooks/changelog/x.sh"]) {
    F.check(`not exempt: ${rel}`, isExemptRepoPath(rel) === false, "");
  }
});
caseEnd();

caseBegin("L6-classify-plans-path", "hooks/lib/size-classify.js");
F.run("classifyPlansPath", () => {
  const { classifyPlansPath } = SC();
  const sid = F.newSid();
  const plans = process.env.WORKFLOW_PLANS_DIR;
  for (const [leaf, want] of [["intent", "intent"], ["outline", "outline"], ["detail", "detail"], ["session-progress", "progress"], ["context", null]]) {
    const got = classifyPlansPath(path.join(plans, `${sid}-${leaf}.md`));
    F.check(`classifyPlansPath(<sid>-${leaf}.md) = ${want}`, (got == null ? null : got) === want, got);
  }
  const outside = path.join(F.work(), "elsewhere", `${sid}-detail.md`);
  F.check("a <sid>-detail.md outside the plans dir is not a plan", classifyPlansPath(outside) == null, classifyPlansPath(outside));
});
caseEnd();

caseBegin("size-session-gate", "hooks/lib/size-session-gate.js");
F.run("sizeCheckActive", () => {
  const { sizeCheckActive } = F.load("hooks/lib/size-session-gate.js");
  const started = F.newSid();
  F.writeStartedState(started);
  F.startedSanity(started);
  F.check("started session is active", sizeCheckActive(started) === true, "");
  F.check("no sid is inactive", sizeCheckActive("") === false && sizeCheckActive(undefined) === false, "");
  F.check("no state (workflow not started) is inactive", sizeCheckActive(F.newSid()) === false, "");
  const off = F.newSid();
  F.writeStartedState(off);
  F.writeMarker(off, "workflow-off");
  F.check("WORKFLOW_OFF session is inactive", sizeCheckActive(off) === false, "");
  const wt = F.newSid();
  F.writeStartedState(wt);
  F.writeMarker(wt, "worktree-off");
  F.check("WORKTREE_OFF alone keeps the edit-time gate active", sizeCheckActive(wt) === true, "");
  const { commitSizeCheckActive } = F.load("hooks/lib/size-session-gate.js");
  F.check("WORKTREE_OFF is not honoured at pre-commit (the commit check stays active)", commitSizeCheckActive(wt) === true, "");
  F.check("control: WORKFLOW_OFF is honoured at pre-commit (the commit check is off)", commitSizeCheckActive(off) === false, "");
});
caseEnd();

caseBegin("L7-generated-table-in-file-split", "bin/print-size-limits");
F.run("print-size-limits", () => {
  const name = "size-limits";
  const begin = "<!-- BEGIN GENERATED: " + name + " -->";
  const end = "<!-- END GENERATED: " + name + " -->";
  const src = fs.readFileSync(path.join(F.ROOT, "rules", "coding", "file-split.md"), "utf8").replace(/\r\n/g, "\n");
  const i = src.indexOf(begin);
  const j = src.indexOf(end);
  F.check("file-split.md carries the size-limits generated block", i !== -1 && j > i, `begin ${i} end ${j}`);
  const block = i !== -1 && j > i ? src.slice(i + begin.length, j).replace(/^\n+/, "").replace(/\n+$/, "") : "";
  const r = F.nodeCli("bin/print-size-limits", ["--markdown-table"]);
  const table = r.stdout.replace(/\r\n/g, "\n").replace(/^\n+/, "").replace(/\n+$/, "");
  F.check("print-size-limits --markdown-table exits 0", r.status === 0, r.stderr || r.status);
  F.check("generated block is byte-equal to --markdown-table", table !== "" && block === table, `block=${block.slice(0, 120)} table=${table.slice(0, 120)}`);
  const again = F.nodeCli("bin/print-size-limits", ["--markdown-table"]);
  F.check("--markdown-table is identical across two runs", r.status === 0 && again.status === 0 && r.stdout !== "" && again.stdout === r.stdout, `${again.status} ${again.stderr}`);
  const outside = (i !== -1 && j > i) ? src.slice(0, i) + src.slice(j + end.length) : src;
  const stray = outside.split("\n").filter((l) => /(WARN|HARD)[^\n]*\b\d{3}\b/.test(l));
  F.check("file-split.md states no threshold number outside the generated block", stray.length === 0, stray.join(" | "));
  const { LIMITS } = SL();
  for (const kind of Object.keys(F.EXPECTED)) {
    const g = F.nodeCli("bin/print-size-limits", ["--get", kind]);
    const want = `${(LIMITS[kind] || {}).warn} ${(LIMITS[kind] || {}).hard}`;
    F.check(`--get ${kind} prints "${want}"`, g.status === 0 && g.stdout.trim() === want, `${g.status} ${g.stdout} ${g.stderr}`);
  }
  const bad = F.nodeCli("bin/print-size-limits", ["--get", "nosuchkind"]);
  F.check("--get with an unknown kind is a non-zero exit", bad.status !== 0 && bad.status !== null && !/Cannot find module/.test(bad.stderr), `${bad.status} ${bad.stderr}`);
});
caseEnd();

caseBegin("L8-progress-template-within-warn", "templates/progress.md");
F.run("template", () => {
  const { currentStateChars, LIMITS } = SL();
  const text = fs.readFileSync(path.join(F.ROOT, "templates", "progress.md"), "utf8");
  const n = currentStateChars(text);
  F.check("template Current state placeholder is non-empty and <= progress WARN", n > 0 && n <= LIMITS.progress.warn, n);
});
caseEnd();

process.chdir(savedCwd);
restore();
process.exitCode = F.failureCount() ? 1 : 0;
