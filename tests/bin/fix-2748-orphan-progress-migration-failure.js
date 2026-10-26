#!/usr/bin/env node
"use strict";
// Tests: hooks/lib/temporary-migrations/orphan-progress-file/index.js, hooks/lib/temporary-migrations/orphan-progress-file/merge.js, hooks/lib/temporary-migrations/orphan-progress-file/discover.js
// Tags: TL2, progress-file, migration, session-inherit, plan-artifact, regression-2748, scope:issue-specific, pwsh-not-required
// #2748 M34-M40 (loose-list blocks, a created Plan files section, unreadable states, a bare <path> link) and
// M5/M17/M18/M26/M27 (CAS, crash and I/O failure injected into index.js in-process through run(argv, hooks)).
// Shared setup: fix-2748-orphan-progress-migration/shared.js.

const { caseBegin, caseEnd } = require("../lib/harness");
const fs = require("fs");
const path = require("path");
const { M, planLines, samePath, writeOrphan, finish } = require("./fix-2748-orphan-progress-migration/shared");
const { PLANS, check, show, cli, why, runIndex, progressOf, planOf, read, pinnedSid } = M;
const { section, count, setup, age, HOUR } = M;

// M34: in a loose list an indented child after a blank line stays in its item, so a child shared with
// a base fact under another parent is not deduped away; the whole new item is added and the orphan deleted.
caseBegin("facts-loose-list-child-kept-under-other-parent", "hooks/lib/temporary-migrations/orphan-progress-file/merge.js");
{
  const firstBody = M.firstText("m34-first").replace("- shared bullet\n", "- shared bullet\n- m34 parent A\n\n  - m34 shared child\n");
  const sids = setup("m34", { firstBody });
  writeOrphan(sids, M.downstreamText(sids.downstreamSid).replace("- downstream decision\n", "- downstream decision\n- m34 parent B\n\n  - m34 shared child\n"));
  const r = cli(["--apply"]);
  const out = read(progressOf(sids.firstSid));
  check("M34: --apply exits 0", () => (r.status === 0 ? undefined : why(r)));
  check("M34: the parent B item lands whole, its blank line and child included, beside the base parent A item", () => (count(out, "- m34 parent A\n\n  - m34 shared child\n") === 1
    && count(out, "- m34 parent B\n\n  - m34 shared child\n") === 1 && count(out, "  - m34 shared child\n") === 2 ? undefined : `User decisions=${show(String(out).split("### User decisions")[1])}`));
  check("M34: the orphan progress file is deleted", () => (!fs.existsSync(progressOf(sids.downstreamSid)) ? undefined : why(r)));
}
caseEnd();

// M35: an identical whole loose item (blank lines and indented fenced code with an inner blank line) is deduped.
caseBegin("facts-identical-loose-block-not-duplicated", "hooks/lib/temporary-migrations/orphan-progress-file/merge.js");
{
  const loose = "- m35 parent\n\n  - m35 child\n\n  ```text\n  m35 code\n\n  m35 code after blank\n  ```\n";
  const sids = setup("m35", { firstBody: M.firstText("m35-first").replace("- shared bullet\n", () => `- shared bullet\n${loose}`) });
  writeOrphan(sids, M.downstreamText(sids.downstreamSid).replace("- downstream decision\n", () => `- downstream decision\n${loose}`));
  const r = cli(["--apply"]);
  const out = read(progressOf(sids.firstSid));
  check("M35: --apply exits 0", () => (r.status === 0 ? undefined : why(r)));
  check("M35: the identical loose item appears once and none of its lines is repeated", () => (count(out, loose) === 1 && count(out, "m35 child") === 1
    && count(out, "m35 code after blank") === 1 && count(out, "- downstream decision\n") === 1 ? undefined : `User decisions=${show(String(out).split("### User decisions")[1])}`));
  check("M35: the orphan progress file is deleted", () => (!fs.existsSync(progressOf(sids.downstreamSid)) ? undefined : why(r)));
}
caseEnd();

// M36: a first_session_id progress file without a Plan files section gets one just before Facts to carry over.
caseBegin("plan-files-section-created-before-facts", "hooks/lib/temporary-migrations/orphan-progress-file/merge.js");
{
  const firstBody = M.firstText("m36-first").replace(`## Plan files\n\n- intent: ${planOf("m36-first", "intent")}\n\n`, "");
  const sids = setup("m36", { firstBody, downstreamPlans: { intent: "m36 downstream intent\n" } });
  const r = cli(["--apply"]);
  const out = read(progressOf(sids.firstSid));
  const lines = String(out).split(/\r?\n/);
  check("M36: the fixture base has no Plan files section", () => (!firstBody.includes("## Plan files") ? undefined : `base=${show(firstBody)}`));
  check("M36: --apply exits 0", () => (r.status === 0 ? undefined : why(r)));
  check("M36: exactly one Plan files section is created, before Facts to carry over", () => {
    const at = lines.indexOf("## Plan files");
    const facts = lines.indexOf("## Facts to carry over");
    return count(out, "## Plan files") === 1 && at >= 0 && facts > at ? undefined : `plan=${at} facts=${facts} first=${show(out)}`;
  });
  check("M36: the section carries the existing plan as - intent: <first_session_id plan path>", () => {
    const pl = planLines(out);
    return pl.length === 1 && pl[0] === `- intent: ${planOf(sids.firstSid, "intent")}` && read(planOf(sids.firstSid, "intent")) === "m36 downstream intent\n"
      ? undefined : `Plan files=${show(pl)}`;
  });
}
caseEnd();

// corruptState(prefix) — setup(prefix) plus a state file that exists but is not JSON, with its own progress file.
function corruptState(prefix) {
  const sids = setup(prefix);
  const badSid = `${prefix}-corrupt`;
  fs.writeFileSync(M.F.statePath(badSid), "{ m37 not json");
  fs.writeFileSync(progressOf(badSid), M.downstreamText(badSid));
  age(progressOf(badSid), 2 * HOUR);
  return Object.assign({ badSid, line: `migrate-orphan-progress-files: ${badSid}: cannot read the state; its session chain was not migrated` }, sids);
}

// M37: in a full run an unreadable state is reported on stderr and makes the run exit 1; it is not listed as unknown.
caseBegin("unreadable-state-full-run-exits-1", "hooks/lib/temporary-migrations/orphan-progress-file/discover.js");
{
  const { firstSid, downstreamSid, badSid, line } = corruptState("m37");
  for (const args of [[], ["--apply"]]) {
    const label = args.length ? "--apply" : "the dry-run";
    const r = cli(args);
    const stderrLines = String(r.stderr).split(/\r?\n/);
    check(`M37 ${label}: exits 1 and reports the unreadable state on stderr`, () => (r.status === 1 && stderrLines.includes(line) ? undefined : `exit=${r.status} stderr=${show(r.stderr)}`));
    check(`M37 ${label}: the unreadable sid is not listed as (unknown)`, () => (!String(r.stdout).split("\n").some((l) => l.includes(badSid) && l.includes("(unknown)")) ? undefined : `stdout=${show(r.stdout)}`));
    if (!args.length) check("M37 the dry-run: the valid session chain is still reported", () => (String(r.stdout).includes(`${firstSid} <- ${downstreamSid}`) ? undefined : why(r)));
  }
  check("M37: --apply still migrates the valid session chain", () => (!fs.existsSync(progressOf(downstreamSid)) && pinnedSid(downstreamSid) === firstSid
    ? undefined : `orphan present=${fs.existsSync(progressOf(downstreamSid))} root_sid=${show(pinnedSid(downstreamSid))}`));
  check("M37: the unreadable state's progress file is kept", () => (read(progressOf(badSid)) === M.downstreamText(badSid) ? undefined : "changed or removed"));
}
caseEnd();

// M38: a --session run of another, valid session chain does not report the unreadable state and exits 0.
caseBegin("unreadable-state-not-reported-with-session", "hooks/lib/temporary-migrations/orphan-progress-file/discover.js");
{
  const { firstSid, downstreamSid, badSid } = corruptState("m38");
  for (const args of [["--session", downstreamSid], ["--apply", "--session", downstreamSid]]) {
    const r = cli(args);
    check(`M38 ${args.join(" ")}: exits 0 with no unreadable-state report`, () => (r.status === 0 && !String(r.stderr).includes("cannot read the state")
      && !String(r.stdout).includes(badSid) ? undefined : `exit=${r.status} stdout=${show(r.stdout)} stderr=${show(r.stderr)}`));
  }
  check("M38: the own session chain is migrated", () => (!fs.existsSync(progressOf(downstreamSid)) && pinnedSid(downstreamSid) === firstSid ? undefined : "not migrated"));
}
caseEnd();

// M39: a --session run whose own sid has the unreadable state reports it on stderr and exits 1.
caseBegin("unreadable-state-reported-for-own-session", "hooks/lib/temporary-migrations/orphan-progress-file/discover.js");
{
  const { badSid, line } = corruptState("m39");
  for (const args of [["--session", badSid], ["--apply", "--session", badSid]]) {
    const r = cli(args);
    check(`M39 ${args.join(" ")}: exits 1 and reports the unreadable state on stderr`, () => (r.status === 1 && String(r.stderr).split(/\r?\n/).includes(line)
      ? undefined : `exit=${r.status} stdout=${show(r.stdout)} stderr=${show(r.stderr)}`));
  }
  check("M39: the unreadable state's progress file is kept", () => (read(progressOf(badSid)) === M.downstreamText(badSid) ? undefined : "changed or removed"));
}
caseEnd();

// M40: a bare angle-bracket Plan files value <path> counts as existing only when <path> is an existing plan.
caseBegin("plan-files-line-bare-angle-bracket", "hooks/lib/temporary-migrations/orphan-progress-file/merge.js");
{
  for (const { name, want } of [{ name: "existing", want: true }, { name: "nonexistent", want: false }]) {
    const prefix = `m40-${name}`;
    const sids = setup(prefix, { downstreamPlans: { detail: `${name} detail\n` } });
    const target = want ? planOf(sids.downstreamSid, "detail") : path.join(PLANS, `${prefix}-missing.md`);
    const line = `- detail: <${target}>`;
    writeOrphan(sids, M.downstreamText(sids.downstreamSid).replace(/- intent: .*\n- outline: .*\n- detail: .*\n/, () => `${line}\n`));
    const r = cli(["--apply"]);
    const lines = planLines(read(progressOf(sids.firstSid))).filter((l) => l.startsWith("- detail:"));
    const carried = lines.length === 1 && lines[0].includes(`${sids.firstSid}-detail.md`);
    check(`M40 ${name}: ${show(line)} is ${want ? "carried as <first>-detail.md" : "dropped"}`, () => (r.status === 0 && (want ? carried : lines.length === 0)
      ? undefined : `${why(r)} detail lines=${show(lines)}`));
  }
}
caseEnd();

// M5/M17/M18 drive index.js in-process (run may return a Promise), so they run last.
async function m5() {
  const { firstSid, downstreamSid } = setup("m5");
  const sidecarBefore = pinnedSid(downstreamSid);
  const edit = "- m5 concurrent edit\n";
  let hooked = false;
  const res = await runIndex(["--apply"], {
    beforeCommit: (info) => {
      if (!info || info.firstSid !== firstSid) return;
      hooked = true;
      fs.appendFileSync(info.firstPath, edit);
    },
  });
  const pre = () => res.unavailable || null;
  check("M5: the beforeCommit hook ran with { firstSid, firstPath }", () => pre() || (hooked ? undefined : `hook not called; error=${show(res.error && res.error.message)}`));
  check("M5: the session chain fails and run exits 1", () => pre() || (res.code === 1 && (res.written.includes(downstreamSid) || res.written.includes(firstSid)) ? undefined : `exit=${show(res.code)} out=${show(res.written)}`));
  check("M5: the first generation keeps the concurrent write", () => pre() || (read(progressOf(firstSid)) === M.firstText(firstSid) + edit ? undefined : `first=${show(read(progressOf(firstSid)))}`));
  check("M5: the orphan progress file and sidecar are unchanged", () => pre() || (read(progressOf(downstreamSid)) === M.downstreamText(downstreamSid) && pinnedSid(downstreamSid) === sidecarBefore
    ? undefined : `root_sid=${show(pinnedSid(downstreamSid))}`));
}

async function m17() {
  const { firstSid, downstreamSid } = setup("m17", { downstreamPlans: { detail: "m17 detail\n" } });
  let reached = 0;
  const res = await runIndex(["--apply"], { beforeRename: () => { reached += 1; throw new Error("m17 crash before rename"); } });
  const pre = () => res.unavailable || null;
  const mid = read(progressOf(firstSid));
  check("M17: the injected first run reached beforeRename and exits 1", () => pre() || (reached === 1 && res.code === 1 ? undefined : `reached=${reached} exit=${show(res.code)} error=${show(res.error && res.error.message)}`));
  check("M17: before the re-run the first_session_id progress file is already merged (facts and <first>-detail.md line)", () => pre()
    || ((section(mid, "### User decisions") || []).includes("- downstream decision") && planLines(mid).some((l) => l.startsWith("- detail:") && l.includes(`${firstSid}-detail.md`))
      ? undefined : `first=${show(mid)}`));
  check("M17: before the re-run the plan keeps its session-downstream name, the orphan is intact and the sidecar is still self-pinned", () => pre()
    || (read(planOf(downstreamSid, "detail")) === "m17 detail\n" && !fs.existsSync(planOf(firstSid, "detail"))
      && read(progressOf(downstreamSid)) === M.downstreamText(downstreamSid) && pinnedSid(downstreamSid) === downstreamSid
      ? undefined : `downstream detail=${fs.existsSync(planOf(downstreamSid, "detail"))} first detail=${fs.existsSync(planOf(firstSid, "detail"))} root_sid=${show(pinnedSid(downstreamSid))}`));
  const again = cli(["--apply", "--include-active"]);
  const out = read(progressOf(firstSid));
  check("M17: the re-run after a crash before rename exits 0", () => pre() || (again.status === 0 ? undefined : why(again)));
  check("M17: the first generation's detail line names <first>-detail.md", () => pre() || (planLines(out).some((l) => l.startsWith("- detail:") && l.includes(`${firstSid}-detail.md`))
    ? undefined : `Plan files=${show(planLines(out))}`));
  check("M17: the plan is renamed and the orphan progress file is gone", () => pre() || (read(planOf(firstSid, "detail")) === "m17 detail\n" && !fs.existsSync(planOf(downstreamSid, "detail"))
    && !fs.existsSync(progressOf(downstreamSid)) ? undefined : `first detail=${show(read(planOf(firstSid, "detail")))} orphan=${fs.existsSync(progressOf(downstreamSid))}`));
}

async function m18() {
  const { firstSid, downstreamSid } = setup("m18");
  const late = "- m18 late note\n";
  let hooked = false;
  const res = await runIndex(["--apply"], {
    beforeDelete: () => {
      if (hooked) return;
      hooked = true;
      fs.appendFileSync(progressOf(downstreamSid), late);
    },
  });
  const pre = () => res.unavailable || null;
  check("M18: an orphan written after the merge is not deleted and run exits 1", () => pre() || (hooked && res.code === 1 && read(progressOf(downstreamSid)) === M.downstreamText(downstreamSid) + late
    ? undefined : `hooked=${hooked} exit=${show(res.code)} error=${show(res.error && res.error.message)}`));
  const again = cli(["--apply", "--include-active"]);
  check("M18: the re-run merges the late record and deletes the orphan", () => pre() || (again.status === 0 && (section(read(progressOf(firstSid)), "### Extra notes") || []).includes("- m18 late note")
    && !fs.existsSync(progressOf(downstreamSid)) ? undefined : `${why(again)} first=${show(read(progressOf(firstSid)))}`));
}

// M26: an I/O failure injected at each write point exits 1, keeps the orphan progress file intact, and a re-run finishes.
async function m26() {
  for (const hook of ["beforeCommit", "beforeRename", "beforeDelete"]) {
    const sids = setup(`m26-${hook.toLowerCase()}`);
    const orphanBefore = read(progressOf(sids.downstreamSid));
    const firstBefore = read(progressOf(sids.firstSid));
    const fail = () => { throw Object.assign(new Error(`m26 injected EIO at ${hook}`), { code: "EIO" }); };
    const res = await runIndex(["--apply"], { [hook]: fail });
    const pre = () => res.unavailable || null;
    check(`M26 ${hook}: the I/O failure makes run exit 1`, () => pre() || (res.code === 1 ? undefined : `exit=${show(res.code)} error=${show(res.error && res.error.message)} out=${show(res.written)}`));
    check(`M26 ${hook}: the orphan progress file is preserved intact`, () => pre() || (read(progressOf(sids.downstreamSid)) === orphanBefore ? undefined : `orphan=${show(read(progressOf(sids.downstreamSid)))}`));
    if (hook === "beforeCommit") {
      check(`M26 ${hook}: the first_session_id progress file is unchanged`, () => pre() || (read(progressOf(sids.firstSid)) === firstBefore ? undefined : `first=${show(read(progressOf(sids.firstSid)))}`));
    }
    const again = cli(["--apply", "--include-active"]);
    const out = read(progressOf(sids.firstSid));
    check(`M26 ${hook}: the re-run exits 0, merges each downstream bullet once and deletes the orphan progress file`, () => pre() || (again.status === 0
      && ["- downstream decision\n", "- downstream deviation\n", "- downstream extra\n"].every((b) => count(out, b) === 1) && !fs.existsSync(progressOf(sids.downstreamSid))
      && pinnedSid(sids.downstreamSid) === sids.firstSid ? undefined : `${why(again)} first=${show(out)}`));
  }
}

// M27: the same failure at the real fs layer — the fs call of each phase is stubbed to throw for its one target path.
async function m27() {
  const rows = [
    { name: "commit-tmp-write", fn: "writeFileSync", code: "EPERM", target: () => (p) => String(p).endsWith(".migrating.tmp"), firstKept: true },
    { name: "commit-rename", fn: "renameSync", code: "EACCES", target: (s) => (from, to) => samePath(to, progressOf(s.firstSid)), firstKept: true },
    { name: "plan-rename", fn: "renameSync", code: "EACCES", target: (s) => (from) => samePath(from, planOf(s.downstreamSid, "detail")), firstKept: false },
    { name: "orphan-unlink", fn: "unlinkSync", code: "EPERM", target: (s) => (p) => samePath(p, progressOf(s.downstreamSid)), firstKept: false },
  ];
  for (const { name, fn, code, target, firstKept } of rows) {
    const sids = setup(`m27-${name}`, { downstreamPlans: { detail: `m27 ${name} detail\n` } });
    const orphanBefore = read(progressOf(sids.downstreamSid));
    const firstBefore = read(progressOf(sids.firstSid));
    const hits = target(sids);
    const real = fs[fn];
    let thrown = 0;
    fs[fn] = function stubbed(...args) {
      if (hits(...args)) {
        thrown += 1;
        throw Object.assign(new Error(`${code}: m27 injected at ${fn}`), { code });
      }
      return real.apply(fs, args);
    };
    let res;
    try {
      res = await runIndex(["--apply"]);
    } finally {
      fs[fn] = real;
    }
    const pre = () => res.unavailable || null;
    check(`M27 ${name}: a ${code} from fs.${fn} makes run exit 1`, () => pre() || (thrown > 0 && res.code === 1 ? undefined : `thrown=${thrown} exit=${show(res.code)} error=${show(res.error && res.error.message)}`));
    check(`M27 ${name}: the orphan progress file is preserved intact`, () => pre() || (read(progressOf(sids.downstreamSid)) === orphanBefore ? undefined : `orphan=${show(read(progressOf(sids.downstreamSid)))}`));
    if (firstKept) {
      check(`M27 ${name}: the first_session_id progress file is unchanged and no .migrating.tmp file is left`, () => pre() || (read(progressOf(sids.firstSid)) === firstBefore
        && !fs.readdirSync(PLANS).some((n) => n.endsWith(".migrating.tmp")) ? undefined : `first=${show(read(progressOf(sids.firstSid)))} plans=${show(fs.readdirSync(PLANS))}`));
    }
    const again = cli(["--apply", "--include-active"]);
    const out = read(progressOf(sids.firstSid));
    check(`M27 ${name}: the clean re-run exits 0, merges each downstream bullet once, renames the plan and deletes the orphan progress file`, () => pre() || (again.status === 0
      && ["- downstream decision\n", "- downstream deviation\n", "- downstream extra\n"].every((b) => count(out, b) === 1)
      && read(planOf(sids.firstSid, "detail")) === `m27 ${name} detail\n` && !fs.existsSync(planOf(sids.downstreamSid, "detail"))
      && !fs.existsSync(progressOf(sids.downstreamSid)) && pinnedSid(sids.downstreamSid) === sids.firstSid ? undefined : `${why(again)} first=${show(out)}`));
  }
}

caseBegin("cas-aborts-on-concurrent-first-write", "hooks/lib/temporary-migrations/orphan-progress-file/merge.js");
m5().catch((e) => check("M5: harness", () => String(e && e.message))).finally(() => {
caseEnd();
caseBegin("resume-after-crash-before-rename", "hooks/lib/temporary-migrations/orphan-progress-file/index.js");
  return m17().catch((e) => check("M17: harness", () => String(e && e.message)));
}).finally(() => {
caseEnd();
caseBegin("orphan-written-after-merge-is-kept", "hooks/lib/temporary-migrations/orphan-progress-file/index.js");
  return m18().catch((e) => check("M18: harness", () => String(e && e.message)));
}).finally(() => {
caseEnd();
caseBegin("io-failure-during-merge-keeps-orphan", "hooks/lib/temporary-migrations/orphan-progress-file/index.js");
  return m26().catch((e) => check("M26: harness", () => String(e && e.message)));
}).finally(() => {
caseEnd();
caseBegin("fs-layer-failure-during-merge-keeps-orphan", "hooks/lib/temporary-migrations/orphan-progress-file/index.js");
  return m27().catch((e) => check("M27: harness", () => String(e && e.message)));
}).finally(() => {
caseEnd();
  finish();
});
