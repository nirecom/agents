#!/usr/bin/env node
"use strict";
// Tests: bin/migrate-orphan-progress-files, hooks/lib/temporary-migrations/orphan-progress-file/index.js, hooks/lib/temporary-migrations/orphan-progress-file/merge.js, hooks/lib/temporary-migrations/orphan-progress-file/discover.js, skills/session-close/SKILL.md
// Tags: TL2, progress-file, migration, session-inherit, plan-artifact, regression-2748, scope:issue-specific, pwsh-not-required
// #2748 M19-M25 and M29-M33: --session and the session-close re-migration (M19-M23), loose facts and Plan files
// link forms (M24-M25, M29-M32), and unreadable directories (M33). Shared setup: fix-2748-orphan-progress-migration/shared.js.
// The session-close script's own behavior (forwarding, advisory exits, its markers) lives in tests/skills/fix-2748-migrate-own-session-chain.sh.

const { caseBegin, caseEnd } = require("../lib/harness");
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const { M, SCRATCH, planLines, writeOrphan, finish } = require("./fix-2748-orphan-progress-migration/shared");
const { F, PLANS, check, show, cli, why, progressOf, planOf, read, pinnedSid } = M;
const { section, count, setup, adoptChain, settle } = M;

caseBegin("facts-text-before-first-subsection-survives", "hooks/lib/temporary-migrations/orphan-progress-file/merge.js");
{
  const sids = setup("m24");
  const loose = ["m24 loose paragraph with no subsection heading", "- m24 loose bullet with no subsection heading"];
  writeOrphan(sids, M.downstreamText(sids.downstreamSid).replace("## Facts to carry over\n\n", () => `## Facts to carry over\n\n${loose.join("\n")}\n\n`));
  const r = cli(["--apply"]);
  const out = read(progressOf(sids.firstSid));
  check("M24: --apply exits 0", () => (r.status === 0 ? undefined : why(r)));
  for (const text of loose) {
    check(`M24: "${text}" survives exactly once inside Facts to carry over of the first_session_id progress file`, () => {
      const facts = section(out, "## Facts to carry over") || [];
      return count(out, text) === 1 && facts.includes(text) ? undefined : `count=${count(out, text)} orphan present=${fs.existsSync(progressOf(sids.downstreamSid))} Facts=${show(facts)}`;
    });
  }
}
caseEnd();

// M25: only a Plan files line whose link target is an existing regular file becomes a first_session_id plan line.
// Every row has <downstream>-detail.md on disk, so a dropped row is dropped by its own link target alone.
caseBegin("plan-files-line-link-forms", "hooks/lib/temporary-migrations/orphan-progress-file/merge.js");
{
  const dirTarget = path.join(SCRATCH, "m25-directory-target");
  fs.mkdirSync(dirTarget, { recursive: true });
  const cases = [
    { name: "bare-existing", raw: (p) => p.abs, want: true },
    { name: "backtick-existing", raw: (p) => `\`${p.abs}\``, want: true },
    { name: "mdlink-existing", raw: (p) => `[detail](${p.abs})`, want: true },
    { name: "relative-existing", raw: (p) => p.rel, want: true },
    { name: "bare-nonexistent", raw: (p) => p.missing, want: false },
    { name: "backtick-nonexistent", raw: (p) => `\`${p.missing}\``, want: false },
    { name: "mdlink-nonexistent", raw: (p) => `[detail](${p.missing})`, want: false },
    { name: "relative-nonexistent", raw: (p) => path.basename(p.missing), want: false },
    { name: "bare-directory", raw: () => dirTarget, want: false },
    { name: "mdlink-directory", raw: () => `[detail](${dirTarget})`, want: false },
  ];
  for (const { name, raw, want } of cases) {
    const prefix = `m25-${name}`;
    const sids = setup(prefix, { downstreamPlans: { detail: `${name} detail\n` } });
    const p = { abs: planOf(sids.downstreamSid, "detail"), rel: `${sids.downstreamSid}-detail.md`, missing: path.join(PLANS, `${prefix}-missing.md`) };
    const line = `- detail: ${raw(p)}`;
    writeOrphan(sids, M.downstreamText(sids.downstreamSid).replace(/- intent: .*\n- outline: .*\n- detail: .*\n/, () => `${line}\n`));
    const r = cli(["--apply"]);
    const lines = planLines(read(progressOf(sids.firstSid))).filter((l) => l.startsWith("- detail:"));
    const carried = lines.length === 1 && lines[0].includes(`${sids.firstSid}-detail.md`);
    check(`M25 ${name}: ${show(line)} is ${want ? "carried as <first>-detail.md" : "dropped"}`, () => (r.status === 0 && (want ? carried : lines.length === 0)
      ? undefined : `${why(r)} detail lines=${show(lines)}`));
  }
}
caseEnd();

const SCRIPT_REL = "skills/session-close/scripts/migrate-own-session-chain.sh";
// withOtherChain(prefix, opts) — setup(prefix, opts) plus an unrelated, settled session chain with its own orphan progress file.
function withOtherChain(prefix, opts) {
  const own = setup(prefix, opts);
  const [otherFirstSid, otherDownstreamSid] = [`${prefix}-other-first`, `${prefix}-other-downstream`];
  adoptChain([otherFirstSid, otherDownstreamSid]);
  fs.writeFileSync(progressOf(otherFirstSid), M.firstText(otherFirstSid));
  fs.writeFileSync(progressOf(otherDownstreamSid), M.downstreamText(otherDownstreamSid));
  settle([otherFirstSid, otherDownstreamSid]);
  const files = [progressOf(otherFirstSid), progressOf(otherDownstreamSid), F.statePath(otherFirstSid), F.statePath(otherDownstreamSid)];
  const before = files.map(read);
  const otherUntouched = () => {
    const changed = files.filter((p, i) => read(p) !== before[i]);
    return changed.length === 0 && pinnedSid(otherDownstreamSid) === otherDownstreamSid ? undefined : `changed=${show(changed)} root_sid=${show(pinnedSid(otherDownstreamSid))}`;
  };
  return Object.assign({ otherFirstSid, otherDownstreamSid, otherUntouched }, own);
}

caseBegin("session-option-migrates-only-own-chain", "bin/migrate-orphan-progress-files");
{
  const { firstSid, downstreamSid, otherFirstSid, otherDownstreamSid, otherUntouched } = withOtherChain("m19");
  const dry = cli(["--session", downstreamSid]);
  check("M19: a --session dry-run reports the own session chain and not the other one", () => {
    const out = String(dry.stdout);
    return dry.status === 0 && out.includes(`${firstSid} <- ${downstreamSid}`) && !out.includes(otherDownstreamSid) ? undefined : why(dry);
  });
  const r = cli(["--apply", "--session", downstreamSid]);
  check("M19: --apply --session <downstream> exits 0 and migrates the own session chain", () => (r.status === 0 && !fs.existsSync(progressOf(downstreamSid))
    && pinnedSid(downstreamSid) === firstSid ? undefined : `${why(r)} root_sid=${show(pinnedSid(downstreamSid))}`));
  check("M19: the other session chain's orphan progress file, state and sidecar are untouched", otherUntouched);
  check("M19: the other session chain's first generation is not handed the own facts", () => (!String(read(progressOf(otherFirstSid))).includes("marker-cs-downstream") ? undefined : "merged"));
}
caseEnd();

caseBegin("session-option-invalid-sid-exits-2", "bin/migrate-orphan-progress-files");
{
  for (const args of [["--apply", "--session", "../x"], ["--session", "a/b"], ["--session"]]) {
    const r = cli(args);
    check(`M20: ${args.join(" ")} exits 2`, () => (r.status === 2 ? undefined : why(r)));
  }
}
caseEnd();

// M21 (end to end): the session-close script run against the real CLI migrates only the own, still-active chain.
// Forwarding, advisory exits and the script's markers: tests/skills/fix-2748-migrate-own-session-chain.sh.
caseBegin("session-close-script-migrates-own-active-chain", "bin/migrate-orphan-progress-files");
{
  const { firstSid, downstreamSid, otherUntouched } = withOtherChain("m21", { settle: false });
  const env = Object.assign({}, process.env, { AGENTS_MAIN_ROOT: String(F.ROOT).replace(/\\/g, "/") });
  delete env.CLAUDE_CODE_SESSION_ID;
  const r = spawnSync("bash", [path.join(F.ROOT, SCRIPT_REL).replace(/\\/g, "/"), downstreamSid], { cwd: SCRATCH, env, encoding: "utf8", timeout: 60000 });
  check("M21: the script exits 0", () => (r.status === 0 ? undefined : why(r)));
  check("M21: the own session chain updated within 30 minutes is migrated (--include-active)", () => (!fs.existsSync(progressOf(downstreamSid))
    && pinnedSid(downstreamSid) === firstSid && (section(read(progressOf(firstSid)), "### User decisions") || []).includes("- downstream decision")
    ? undefined : `${why(r)} orphan present=${fs.existsSync(progressOf(downstreamSid))}`));
  check("M21: the other session chain is untouched", otherUntouched);
}
caseEnd();

caseBegin("temporary-migration-markers-in-cli", "bin/migrate-orphan-progress-files");
{
  const desc = "orphan progress file -> first_session_id progress file migration";
  const markersInOrder = (rel, prefix) => {
    const text = read(path.join(F.ROOT, rel));
    if (text === null) return `${rel} does not exist`;
    const lines = text.split(/\r?\n/);
    const begin = lines.indexOf(`${prefix} --- BEGIN temporary: ${desc} added 2026-10-24 ---`);
    const end = lines.indexOf(`${prefix} --- END temporary: ${desc} ---`);
    if (begin < 0) return `${rel}: BEGIN line missing`;
    if (!String(lines[begin + 1]).startsWith(`${prefix} deletion-condition: remove after 2026-11-22`)) return `${rel}: line after BEGIN=${show(lines[begin + 1])}`;
    return end > begin + 1 ? undefined : `${rel}: END line missing or before BEGIN (begin=${begin} end=${end})`;
  };
  check("M22: the CLI has the // BEGIN, deletion-condition and END in this order", () => markersInOrder("bin/migrate-orphan-progress-files", "//"));
}
caseEnd();

caseBegin("session-close-skill-wires-sc10", "skills/session-close/SKILL.md");
{
  const lines = String(read(path.join(F.ROOT, "skills/session-close/SKILL.md"))).split(/\r?\n/);
  const isHeading = (l) => /^#{1,6} /.test(l);
  const sc9 = lines.findIndex((l) => isHeading(l) && /\bSC-9\b/.test(l));
  const sc10 = lines.findIndex((l) => isHeading(l) && /\bSC-10\b/.test(l) && l.includes("(temporary, #2748)"));
  const next = lines.findIndex((l, i) => i > sc10 && isHeading(l));
  const body = sc10 < 0 ? [] : lines.slice(sc10 + 1, next < 0 ? lines.length : next);
  check("M23: SKILL.md has an SC-10 heading marked (temporary, #2748)", () => (sc10 >= 0 ? undefined : "SC-10 heading missing"));
  check("M23: the SC-10 section runs the session-close script with \"<session-id>\"", () => (body.some((l) => l.includes(SCRIPT_REL) && l.includes("\"<session-id>\""))
    ? undefined : `SC-10 body=${show(body)}`));
  check("M23: the SC-10 heading comes after the SC-9 heading", () => (sc9 >= 0 && sc10 > sc9 ? undefined : `sc9=${sc9} sc10=${sc10}`));
}
caseEnd();

// M29: a Plan files line is re-pointed to <first>-<stage>.md only when that plan exists after the renames;
// an orphan line naming some other existing file leaves the first generation's line for that stage alone.
caseBegin("plan-files-line-not-repointed-to-missing-first-plan", "hooks/lib/temporary-migrations/orphan-progress-file/index.js");
{
  const elsewhere = path.join(SCRATCH, "m29-elsewhere-detail.md");
  fs.writeFileSync(elsewhere, "m29 elsewhere\n");
  for (const { name, firstPlans, want } of [
    { name: "no-first-plan", firstPlans: {}, want: "kept" },
    { name: "first-plan-exists", firstPlans: { detail: "m29 first detail\n" }, want: "repointed" },
  ]) {
    const prefix = `m29-${name}`;
    const firstIntent = `- intent: ${planOf(`${prefix}-first`, "intent")}\n`;
    const firstBody = M.firstText(`${prefix}-first`).replace(firstIntent, () => `${firstIntent}- detail: ${elsewhere}\n`);
    const sids = setup(prefix, { firstBody, firstPlans });
    writeOrphan(sids, M.downstreamText(sids.downstreamSid).replace(/- detail: .*\n/, () => `- detail: ${elsewhere}\n`));
    const r = cli(["--apply"]);
    const lines = planLines(read(progressOf(sids.firstSid))).filter((l) => l.startsWith("- detail:"));
    const expected = want === "kept" ? `- detail: ${elsewhere}` : `- detail: ${planOf(sids.firstSid, "detail")}`;
    check(`M29 ${name}: the first generation's detail line is ${want === "kept" ? "kept, not re-pointed to a missing <first>-detail.md" : "re-pointed to the existing <first>-detail.md"}`, () => (r.status === 0
      && lines.length === 1 && lines[0] === expected ? undefined : `${why(r)} detail lines=${show(lines)} first detail exists=${fs.existsSync(planOf(sids.firstSid, "detail"))}`));
  }
}
caseEnd();

// M30: a Facts subsection body keeps its inner blank lines (paragraph breaks) and fenced code blocks when merged.
caseBegin("facts-paragraphs-and-code-blocks-survive-merge", "hooks/lib/temporary-migrations/orphan-progress-file/merge.js");
{
  const sids = setup("m30");
  const body = ["- downstream deviation", "", "m30 paragraph one", "m30 paragraph one continued", "", "m30 paragraph two", "",
    "```text", "m30 code first", "", "m30 code after blank", "```"].join("\n");
  writeOrphan(sids, M.downstreamText(sids.downstreamSid).replace("- downstream deviation\n", () => `${body}\n`));
  const r = cli(["--apply"]);
  const out = read(progressOf(sids.firstSid));
  check("M30: --apply exits 0", () => (r.status === 0 ? undefined : why(r)));
  check("M30: the Deviations body lands with its blank lines and code block intact, after the base fact", () => (count(out, `- first deviation\n${body}\n`) === 1
    ? undefined : `Deviations=${show(String(out).split("### Deviations")[1])}`));
}
caseEnd();

// M31: dedupe is per block — a top-level list item with its nested items is one block, and a block is
// skipped only when the identical block (indentation included) is already in the base subsection.
caseBegin("facts-dedupe-per-block", "hooks/lib/temporary-migrations/orphan-progress-file/merge.js");
{
  const firstBody = M.firstText("m31-first").replace("- shared bullet\n", "- shared bullet\n- m31 A\n  - m31 keep logs\n");
  const sids = setup("m31", { firstBody });
  writeOrphan(sids, M.downstreamText(sids.downstreamSid)
    .replace("- downstream decision\n", "- m31 B\n  - m31 keep logs\n- first decision\n- downstream decision\n")
    .replace("- downstream deviation\n", "- downstream deviation\n\n```\n- first deviation\n```\n"));
  const r = cli(["--apply"]);
  const out = read(progressOf(sids.firstSid));
  check("M31: --apply exits 0", () => (r.status === 0 ? undefined : why(r)));
  check("M31 (a): a new item keeps its nested child even when the base has the same child under another item", () => (count(out, "- m31 A\n  - m31 keep logs\n") === 1
    && count(out, "- m31 B\n  - m31 keep logs\n") === 1 && count(out, "  - m31 keep logs\n") === 2 ? undefined : `User decisions=${show(section(out, "### User decisions"))}`));
  check("M31 (b): a code-block line identical to a fact line elsewhere is kept", () => (count(out, "```\n- first deviation\n```\n") === 1 && count(out, "- first deviation\n") === 2
    ? undefined : `Deviations=${show(String(out).split("### Deviations")[1])}`));
  check("M31 (c): an identical whole bullet is not duplicated", () => (count(out, "- first decision\n") === 1 && count(out, "- shared bullet") === 1
    ? undefined : `User decisions=${show(section(out, "### User decisions"))}`));
}
caseEnd();

// M32: a markdown link with angle brackets [detail](<path>) counts as existing only when <path> is an existing plan.
caseBegin("plan-files-line-angle-bracket-link", "hooks/lib/temporary-migrations/orphan-progress-file/merge.js");
{
  for (const { name, want } of [{ name: "existing", want: true }, { name: "nonexistent", want: false }]) {
    const prefix = `m32-${name}`;
    const sids = setup(prefix, { downstreamPlans: { detail: `${name} detail\n` } });
    const target = want ? planOf(sids.downstreamSid, "detail") : path.join(PLANS, `${prefix}-missing.md`);
    const line = `- detail: [detail](<${target}>)`;
    writeOrphan(sids, M.downstreamText(sids.downstreamSid).replace(/- intent: .*\n- outline: .*\n- detail: .*\n/, () => `${line}\n`));
    const r = cli(["--apply"]);
    const lines = planLines(read(progressOf(sids.firstSid))).filter((l) => l.startsWith("- detail:"));
    const carried = lines.length === 1 && lines[0].includes(`${sids.firstSid}-detail.md`);
    check(`M32 ${name}: ${show(line)} is ${want ? "carried as <first>-detail.md" : "dropped"}`, () => (r.status === 0 && (want ? carried : lines.length === 0)
      ? undefined : `${why(r)} detail lines=${show(lines)}`));
  }
}
caseEnd();

// M33: a missing plans dir holds nothing (exit 0); a missing first state root, or any other readdir failure
// (here ENOTDIR: the directory is a regular file), is reported and the run exits 1 instead of "nothing to do".
caseBegin("unreadable-dir-exits-1", "hooks/lib/temporary-migrations/orphan-progress-file/discover.js");
{
  const base = path.join(SCRATCH, "m33");
  fs.mkdirSync(base, { recursive: true });
  const asFile = path.join(base, "regular-file");
  fs.writeFileSync(asFile, "m33 not a directory\n");
  const missing = path.join(base, "missing");
  const realDir = fs.mkdtempSync(path.join(base, "dir-"));
  const rows = [
    { name: "plans-dir-is-a-file", stateDir: realDir, plansDir: asFile, exit: 1 },
    { name: "state-root-is-a-file", stateDir: asFile, plansDir: realDir, exit: 1 },
    { name: "state-root-missing", stateDir: missing, plansDir: realDir, exit: 1 },
    { name: "both-missing", stateDir: missing, plansDir: path.join(base, "missing-plans"), exit: 1 },
    { name: "plans-dir-missing", stateDir: fs.mkdtempSync(path.join(base, "empty-state-")), plansDir: path.join(base, "missing-plans"), exit: 0 },
  ];
  for (const { name, stateDir, plansDir, exit } of rows) {
    const env = Object.assign({}, process.env, { HOME: realDir, USERPROFILE: realDir, WORKFLOW_STATE_DIR: stateDir, WORKFLOW_PLANS_DIR: plansDir });
    delete env.CLAUDE_CODE_SESSION_ID;
    const r = spawnSync(process.execPath, [M.CLI, "--apply"], { cwd: realDir, env, encoding: "utf8", timeout: 60000 });
    check(`M33 ${name}: the run exits ${exit}${exit === 1 ? " and reports it on stderr" : ""}`, () => (r.status === exit
      && (exit === 0 || String(r.stderr).includes("migrate-orphan-progress-files: cannot list the session chains: ")) ? undefined : why(r)));
  }
}
caseEnd();

finish();
