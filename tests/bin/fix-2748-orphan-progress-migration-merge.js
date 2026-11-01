#!/usr/bin/env node
"use strict";
// Tests: bin/migrate-orphan-progress-files, hooks/lib/temporary-migrations/orphan-progress-file/index.js, hooks/lib/temporary-migrations/orphan-progress-file/merge.js
// Tags: TL2, progress-file, migration, session-inherit, plan-artifact, regression-2748, scope:issue-specific, pwsh-not-required
// #2748 M1-M16 (core --apply flow): the one-off CLI that folds an orphan progress file <downstream>-session-progress.md
// back into the first generation's <first>-session-progress.md, renames the session-downstream's own-name plans to
// the first_session_id names, re-points approval records and the sidecar, and deletes the orphan progress file.
// Each session chain is built with the real applyInheritance (fixture.js). Shared setup: fix-2748-orphan-progress-migration/shared.js.

const { caseBegin, caseEnd } = require("../lib/harness");
const { after, test } = require("node:test");
const { noNewFailures } = require("../lib/case-verdict");
const fs = require("fs");
const { M, planLines, samePath, finish, failureCount } = require("./fix-2748-orphan-progress-migration/shared");
const { F, PF, check, show, cli, why, progressOf, planOf, read, pinnedSid, pin } = M;
const { section, count, setup, settle, snapshot, changedSince, adoptChain, resetAll, age, HOUR } = M;
after(finish);

// crashResume(label, prefix, pinTo) — M4 (crash after step 2, downstream still self-pinned) and M4b
// (crash after step 5, downstream already pinned to first): the re-run neither duplicates nor
// changes the first generation's file and finishes the deletion.
function crashResume(label, prefix, pinTo) {
  const { firstSid, downstreamSid } = setup(prefix, { firstBody: M.mergedFirst(`${prefix}-first`), downstreamNewer: false });
  if (pinTo === "first") pin(downstreamSid, firstSid);
  const firstBefore = read(progressOf(firstSid));
  const r = cli(["--apply"]);
  const out = read(progressOf(firstSid));
  check(`${label}: the re-run exits 0`, () => (r.status === 0 ? undefined : why(r)));
  check(`${label}: no bullet is duplicated in the first generation's file`, () => (["- downstream decision", "- downstream deviation", "- downstream extra", "### Extra notes"]
    .every((b) => count(out, `${b}\n`) === 1) ? undefined : `first=${show(out)}`));
  check(`${label}: the first generation's file is unchanged`, () => (out === firstBefore ? undefined : `first=${show(out)}`));
  check(`${label}: the downstream sidecar ends pinned to the first generation`, () => (pinnedSid(downstreamSid) === firstSid ? undefined : `root_sid=${show(pinnedSid(downstreamSid))}`));
  check(`${label}: the orphan progress file is gone`, () => (!fs.existsSync(progressOf(downstreamSid)) ? undefined : why(r)));
}

caseBegin("dry-run-reports-and-changes-nothing", "bin/migrate-orphan-progress-files");
test("dry-run-reports-and-changes-nothing", () => noNewFailures(failureCount, () => {
  const { firstSid, downstreamSid } = setup("m1");
  const before = snapshot();
  const r = cli([]);
  check("M1: the default dry-run exits 0 and reports <first> <- <downstream> (merge)", () => (r.status === 0 && String(r.stdout).includes(`${firstSid} <- ${downstreamSid} (merge)`) ? undefined : why(r)));
  check("M1: the dry-run leaves every file byte-identical", () => {
    const diff = changedSince(before);
    return diff.length === 0 ? undefined : `changed=${show(diff)}`;
  });
}));
caseEnd();

caseBegin("apply-merges-repins-and-deletes-orphan", "hooks/lib/temporary-migrations/orphan-progress-file/merge.js");
test("apply-merges-repins-and-deletes-orphan", () => noNewFailures(failureCount, () => {
  const { firstSid, downstreamSid } = setup("m2", { downstreamPlans: { intent: "m2 downstream intent\n", detail: "m2 downstream detail\n" } });
  const r = cli(["--apply"]);
  const out = read(progressOf(firstSid));
  check("M2: --apply exits 0", () => (r.status === 0 ? undefined : why(r)));
  check("M2: the downstream User decisions bullet lands under the same heading, the shared bullet once", () => {
    const ud = section(out, "### User decisions") || [];
    return ud.includes("- downstream decision") && ud.includes("- first decision") && ud.filter((l) => l === "- shared bullet").length === 1
      ? undefined : `User decisions=${show(ud)}`;
  });
  check("M2: the downstream Deviations bullet lands under Deviations", () => {
    const dv = section(out, "### Deviations") || [];
    return dv.includes("- downstream deviation") && dv.includes("- first deviation") ? undefined : `Deviations=${show(dv)}`;
  });
  check("M2: a heading the first generation lacks is appended inside Facts to carry over", () => {
    const facts = section(out, "## Facts to carry over") || [];
    return facts.includes("### Extra notes") && (section(out, "### Extra notes") || []).includes("- downstream extra") ? undefined : `Facts=${show(facts)}`;
  });
  check("M2: the intent line (target existed) is one line naming <first>-intent.md", () => {
    const lines = planLines(out).filter((l) => l.startsWith("- intent:"));
    return lines.length === 1 && lines[0].includes(`${firstSid}-intent.md`) ? undefined : `Plan files=${show(planLines(out))}`;
  });
  check("M2: the outline line (target missing) is not carried", () => (planLines(out).some((l) => l.startsWith("- outline:")) ? `Plan files=${show(planLines(out))}` : undefined));
  check("M2: the detail line renamed in the same run is carried as <first>-detail.md", () => {
    const lines = planLines(out).filter((l) => l.startsWith("- detail:"));
    return lines.length === 1 && lines[0].includes(`${firstSid}-detail.md`) ? undefined : `Plan files=${show(planLines(out))}`;
  });
  check("M2: no Plan files line names the session-downstream", () => (out !== null && !planLines(out).some((l) => l.includes(downstreamSid)) ? undefined : `Plan files=${show(planLines(out))}`));
  check("M2: Current state comes from the newer file (the orphan progress file)", () => {
    const cs = section(out, "## Current state") || [];
    return cs.includes("marker-cs-downstream") && !cs.includes("marker-cs-first") ? undefined : `Current state=${show(cs)}`;
  });
  check("M2: the downstream sidecar root_sid is re-pinned to the first generation", () => (pinnedSid(downstreamSid) === firstSid ? undefined : `root_sid=${show(pinnedSid(downstreamSid))}`));
  check("M2: the orphan progress file is deleted and no -note- file is created", () => (!fs.existsSync(progressOf(downstreamSid)) && M.noteFiles().length === 0
    ? undefined : `orphan present=${fs.existsSync(progressOf(downstreamSid))} notes=${show(M.noteFiles())}`));
  check("M2: resolveFirstSid(downstream) is the first generation", () => {
    const got = M.firstSidOf(downstreamSid);
    return got === firstSid ? undefined : `resolveFirstSid=${show(got)}`;
  });
  check("M2: progressPathFor(downstream) is the first generation's progress file", () => {
    const got = PF.progressPathFor(downstreamSid);
    return got && samePath(got, progressOf(firstSid)) ? undefined : `progressPathFor=${show(got)}`;
  });
  const before = snapshot();
  const again = cli(["--apply"]);
  check("M3: a second --apply exits 0 and changes nothing", () => {
    const diff = changedSince(before);
    return again.status === 0 && diff.length === 0 ? undefined : `${why(again)} changed=${show(diff)}`;
  });
}));
caseEnd();

caseBegin("resume-after-crash-before-repin", "hooks/lib/temporary-migrations/orphan-progress-file/index.js");
test("resume-after-crash-before-repin", () => noNewFailures(failureCount, () => crashResume("M4", "m4", "downstream")));
caseEnd();

caseBegin("resume-after-crash-before-delete", "hooks/lib/temporary-migrations/orphan-progress-file/index.js");
test("resume-after-crash-before-delete", () => noNewFailures(failureCount, () => crashResume("M4b", "m4b", "first")));
caseEnd();

caseBegin("skip-active-and-include-active", "hooks/lib/temporary-migrations/orphan-progress-file/index.js");
test("skip-active-and-include-active", () => noNewFailures(failureCount, () => {
  const { firstSid, downstreamSid } = setup("m6", { settle: false });
  const firstBefore = read(progressOf(firstSid));
  const statesBefore = [firstSid, downstreamSid].map((s) => read(F.statePath(s)));
  const sidecarFile = F.mod("hooks/lib/control-sidecar").sidecarPath(downstreamSid, "progress-pressure.json");
  const sidecarBefore = read(sidecarFile);
  const r = cli(["--apply"]);
  check("M6: a session chain touched within 30 minutes is reported skip-active", () => (r.status === 0 && String(r.stdout).includes(`${firstSid} <- ${downstreamSid} (skip-active)`) ? undefined : why(r)));
  check("M6: skip-active leaves both progress files untouched", () => (read(progressOf(firstSid)) === firstBefore && read(progressOf(downstreamSid)) === M.downstreamText(downstreamSid)
    ? undefined : why(r)));
  check("M6: skip-active leaves both state files byte-identical", () => {
    const after = [firstSid, downstreamSid].map((s) => read(F.statePath(s)));
    return statesBefore[0] !== null && after.every((t, i) => t === statesBefore[i]) ? undefined : "a state file changed";
  });
  check("M6: skip-active leaves the downstream sidecar byte-identical (still pinned to itself)", () => {
    const now = read(sidecarFile);
    return sidecarBefore !== null && now === sidecarBefore && pinnedSid(downstreamSid) === downstreamSid ? undefined : `sidecar before=${show(sidecarBefore)} after=${show(now)}`;
  });
  const inc = cli(["--apply", "--include-active"]);
  check("M6: --include-active processes it (no orphan progress file left)", () => (inc.status === 0 && !fs.existsSync(progressOf(downstreamSid)) ? undefined : why(inc)));
}));
caseEnd();

caseBegin("no-state-is-unknown", "hooks/lib/temporary-migrations/orphan-progress-file/index.js");
test("no-state-is-unknown", () => noNewFailures(failureCount, () => {
  resetAll();
  const orphanSid = "m7-nostate";
  fs.writeFileSync(progressOf(orphanSid), M.downstreamText(orphanSid));
  age(progressOf(orphanSid), 2 * HOUR);
  const dry = cli([]);
  check("M7: a progress file with no state is reported unknown", () => (dry.status === 0 && String(dry.stdout).split("\n").some((l) => l.includes(orphanSid) && l.includes("(unknown)")) ? undefined : why(dry)));
  const r = cli(["--apply"]);
  check("M7: --apply skips it and keeps its file", () => (r.status === 0 && read(progressOf(orphanSid)) === M.downstreamText(orphanSid) ? undefined : why(r)));
}));
caseEnd();

caseBegin("missing-first-file-starts-from-template", "hooks/lib/temporary-migrations/orphan-progress-file/merge.js");
test("missing-first-file-starts-from-template", () => noNewFailures(failureCount, () => {
  const { firstSid, downstreamSid } = setup("m8", { firstFile: false });
  const r = cli(["--apply"]);
  const out = read(progressOf(firstSid));
  check("M8: --apply creates the first generation's file", () => (r.status === 0 && out !== null ? undefined : why(r)));
  check("M8: the file is the template naming the first generation's plans, none of the downstream's", () => (out !== null && out.includes(`${firstSid}-intent.md`)
    && !out.includes(`${downstreamSid}-`) && section(out, "### Open questions") !== null ? undefined : `first=${show(out)}`));
  check("M8: the downstream facts land under their headings", () => ((section(out, "### User decisions") || []).includes("- downstream decision")
    && (section(out, "### Extra notes") || []).includes("- downstream extra") ? undefined : `first=${show(out)}`));
  check("M8: Current state is the orphan progress file's, not the template default", () => {
    const cs = section(out, "## Current state") || [];
    return cs.includes("marker-cs-downstream") && !cs.some((l) => l.startsWith("(In a few lines")) ? undefined : `Current state=${show(cs)}`;
  });
}));
caseEnd();

caseBegin("apply-creates-no-note-files", "hooks/lib/temporary-migrations/orphan-progress-file/index.js");
test("apply-creates-no-note-files", () => noNewFailures(failureCount, () => {
  setup("m9", { downstreamPlans: { detail: "m9 detail\n" } });
  const r = cli(["--apply"]);
  check("M9: --apply adds no -note- file to the plans dir", () => (r.status === 0 && M.noteFiles().length === 0 ? undefined : `${why(r)} notes=${show(M.noteFiles())}`));
}));
caseEnd();

// M11/M13: firstSid -> downstreamSid1 -> downstreamSid2, both downstreams carrying the pre-#2748 trace.
caseBegin("three-generation-session-chain-folds-into-first", "hooks/lib/temporary-migrations/orphan-progress-file/index.js");
test("three-generation-session-chain-folds-into-first", () => noNewFailures(failureCount, () => {
  resetAll();
  const [firstSid, downstreamSid1, downstreamSid2] = ["m11-first", "m11-downstream1", "m11-downstream2"];
  const chain = [firstSid, downstreamSid1, downstreamSid2];
  adoptChain(chain);
  const body = {};
  for (const sid of [downstreamSid1, downstreamSid2]) {
    body[sid] = M.downstreamText(sid).replace("- downstream decision\n", `- ${sid} only decision\n`);
    fs.writeFileSync(progressOf(sid), body[sid]);
  }
  fs.writeFileSync(progressOf(firstSid), M.firstText(firstSid));
  for (const sid of chain) fs.writeFileSync(planOf(sid, "intent"), `intent of ${sid}\n`);
  settle(chain);
  const r = cli(["--apply"]);
  const out = read(progressOf(firstSid));
  check("M11: --apply exits 0", () => (r.status === 0 ? undefined : why(r)));
  check("M11: each downstream's facts appear in the first generation's file exactly once", () => {
    const ud = section(out, "### User decisions") || [];
    const n1 = ud.filter((l) => l === `- ${downstreamSid1} only decision`).length;
    const n2 = ud.filter((l) => l === `- ${downstreamSid2} only decision`).length;
    return n1 === 1 && n2 === 1 && ud.includes("- first decision") ? undefined : `User decisions=${show(ud)}`;
  });
  check("M13: on a three-generation collision the newest generation's intent wins", () => (read(planOf(firstSid, "intent")) === `intent of ${downstreamSid2}\n`
    ? undefined : `<first>-intent.md=${show(read(planOf(firstSid, "intent")))}`));
  for (const sid of [downstreamSid1, downstreamSid2]) {
    check(`M11: ${sid}'s orphan progress file and own-name intent are gone`, () => (!fs.existsSync(progressOf(sid)) && !fs.existsSync(planOf(sid, "intent"))
      ? undefined : `progress=${fs.existsSync(progressOf(sid))} intent=${fs.existsSync(planOf(sid, "intent"))}`));
    check(`M11: ${sid} resolves to the first generation`, () => {
      const got = M.firstSidOf(sid);
      return got === firstSid ? undefined : `resolveFirstSid=${show(got)}`;
    });
    check(`M11: progressPathFor(${sid}) is the first generation's progress file`, () => {
      const got = PF.progressPathFor(sid);
      return got && samePath(got, progressOf(firstSid)) ? undefined : `progressPathFor=${show(got)}`;
    });
  }
  const before = snapshot();
  const again = cli(["--apply"]);
  check("M11: a second --apply exits 0 and changes nothing", () => {
    const diff = changedSince(before);
    return again.status === 0 && diff.length === 0 ? undefined : `${why(again)} changed=${show(diff)}`;
  });
}));
caseEnd();

caseBegin("plan-rename-to-first-session-name", "hooks/lib/temporary-migrations/orphan-progress-file/index.js");
test("plan-rename-to-first-session-name", () => noNewFailures(failureCount, () => {
  const { firstSid, downstreamSid } = setup("m12", { downstreamPlans: { detail: "m12 detail body\n" } });
  const r = cli(["--apply"]);
  check("M12: <downstream>-detail.md becomes <first>-detail.md with the same bytes", () => (r.status === 0 && read(planOf(firstSid, "detail")) === "m12 detail body\n"
    ? undefined : `${why(r)} first detail=${show(read(planOf(firstSid, "detail")))}`));
  check("M12: no file keeps the session-downstream's plan name", () => (fs.existsSync(planOf(downstreamSid, "detail")) ? "<downstream>-detail.md still exists" : undefined));
}));
caseEnd();

caseBegin("plan-collision-newer-wins", "hooks/lib/temporary-migrations/orphan-progress-file/index.js");
test("plan-collision-newer-wins", () => noNewFailures(failureCount, () => {
  const { firstSid, downstreamSid } = setup("m13", { firstPlans: { intent: "m13 first intent\n" }, downstreamPlans: { intent: "m13 downstream intent\n" } });
  const r = cli(["--apply"]);
  check("M13: <first>-intent.md holds the session-downstream's intent", () => (r.status === 0 && read(planOf(firstSid, "intent")) === "m13 downstream intent\n"
    ? undefined : `${why(r)} first intent=${show(read(planOf(firstSid, "intent")))}`));
  check("M13: <downstream>-intent.md is gone", () => (fs.existsSync(planOf(downstreamSid, "intent")) ? "still exists" : undefined));
}));
caseEnd();

caseBegin("approval-record-repointed-to-first-session", "hooks/lib/temporary-migrations/orphan-progress-file/index.js");
test("approval-record-repointed-to-first-session", () => noNewFailures(failureCount, () => {
  const { firstSid, downstreamSid } = setup("m14", { downstreamPlans: { detail: "# detail\n\nm14 body\n" } });
  const CA = F.mod("hooks/workflow-state/completion-approval");
  const sha = CA.shaOfArtifactBuffer(fs.readFileSync(planOf(downstreamSid, "detail")), "detail");
  F.S().appendEvents(downstreamSid, [{ kind: "plan_approval", step: "detail", source: "confirm-sentinel", reason: "m14 approval",
    artifact_sha256: sha, artifact_session_id: downstreamSid, artifact_hash_status: "recorded", provenance: "declared", origin: "test-fixture" }]);
  settle([firstSid, downstreamSid]);
  const r = cli(["--apply"]);
  const st = F.S().readState(downstreamSid);
  check("M14: --apply exits 0", () => (r.status === 0 ? undefined : why(r)));
  check("M14: plan_approvals.detail.artifact_session_id is the first generation", () => {
    const rec = ((st || {}).plan_approvals || {}).detail || {};
    return rec.artifact_session_id === firstSid && rec.artifact_sha256 === sha ? undefined : `record=${show(rec)}`;
  });
  check("M14: evaluateCompletionApproval(downstream, detail) is approved", () => {
    const v = CA.evaluateCompletionApproval(downstreamSid, "detail", st, { gate: "ON" });
    return v && v.approved === true ? undefined : `verdict=${show(v)}`;
  });
  check("M14: the added event is backfilled by the migration", () => {
    const ev = (F.raw(downstreamSid).events || []).filter((e) => e.kind === "plan_approval" && e.step === "detail").pop() || {};
    return ev.provenance === "backfilled" && ev.origin === "migrate-orphan-progress-file" && ev.artifact_session_id === firstSid ? undefined : `event=${show(ev)}`;
  });
}));
caseEnd();

// M28: a plan collision where both plans carry an approval record — the newer (session-downstream) plan wins,
// its realigned approval validates, and the replaced first_session_id plan's approval no longer does.
caseBegin("plan-collision-realigns-approvals", "hooks/lib/temporary-migrations/orphan-progress-file/index.js");
test("plan-collision-realigns-approvals", () => noNewFailures(failureCount, () => {
  const { firstSid, downstreamSid } = setup("m28", { firstPlans: { detail: "# detail\n\nm28 first body\n" }, downstreamPlans: { detail: "# detail\n\nm28 downstream body\n" } });
  const CA = F.mod("hooks/workflow-state/completion-approval");
  const approve = (sid) => {
    const sha = CA.shaOfArtifactBuffer(fs.readFileSync(planOf(sid, "detail")), "detail");
    F.S().appendEvents(sid, [{ kind: "plan_approval", step: "detail", source: "confirm-sentinel", reason: `m28 approval of ${sid}`,
      artifact_sha256: sha, artifact_session_id: sid, artifact_hash_status: "recorded", provenance: "declared", origin: "test-fixture" }]);
    return sha;
  };
  const firstSha = approve(firstSid);
  const downstreamSha = approve(downstreamSid);
  settle([firstSid, downstreamSid]);
  const verdict = (sid) => CA.evaluateCompletionApproval(sid, "detail", F.S().readState(sid), { gate: "ON" });
  const firstBefore = verdict(firstSid);
  check("M28: before the migration the first_session_id plan's approval validates", () => (firstBefore && firstBefore.approved === true ? undefined : `verdict=${show(firstBefore)}`));
  const r = cli(["--apply"]);
  check("M28: --apply exits 0", () => (r.status === 0 ? undefined : why(r)));
  check("M28: <first>-detail.md holds the newer session-downstream plan", () => (read(planOf(firstSid, "detail")) === "# detail\n\nm28 downstream body\n"
    && !fs.existsSync(planOf(downstreamSid, "detail")) ? undefined : `first detail=${show(read(planOf(firstSid, "detail")))}`));
  check("M28: the winning plan's approval is realigned to first_session_id with its own sha", () => {
    const rec = ((F.S().readState(downstreamSid) || {}).plan_approvals || {}).detail || {};
    return rec.artifact_session_id === firstSid && rec.artifact_sha256 === downstreamSha ? undefined : `record=${show(rec)}`;
  });
  check("M28: the winning plan's approval validates", () => {
    const v = verdict(downstreamSid);
    return v && v.approved === true ? undefined : `verdict=${show(v)}`;
  });
  check("M28: the replaced plan's approval no longer validates", () => {
    const v = verdict(firstSid);
    const rec = ((F.S().readState(firstSid) || {}).plan_approvals || {}).detail || {};
    return v && v.approved !== true && rec.artifact_sha256 === firstSha ? undefined : `verdict=${show(v)} record=${show(rec)}`;
  });
}));
caseEnd();

caseBegin("downstream-without-orphan-file-still-renames-plans","hooks/lib/temporary-migrations/orphan-progress-file/index.js");
test("downstream-without-orphan-file-still-renames-plans", () => noNewFailures(failureCount, () => {
  const { firstSid, downstreamSid } = setup("m15", { downstreamPlans: { outline: "m15 outline\n" } });
  fs.rmSync(progressOf(downstreamSid));
  const r = cli(["--apply"]);
  check("M15: the session-downstream with only an own-name plan is migrated", () => (r.status === 0 && read(planOf(firstSid, "outline")) === "m15 outline\n"
    && !fs.existsSync(planOf(downstreamSid, "outline")) ? undefined : `${why(r)} first outline=${show(read(planOf(firstSid, "outline")))}`));
}));
caseEnd();

caseBegin("current-state-from-newest-progress-file", "hooks/lib/temporary-migrations/orphan-progress-file/merge.js");
test("current-state-from-newest-progress-file", () => noNewFailures(failureCount, () => {
  const older = setup("m16a", { downstreamNewer: false });
  const r1 = cli(["--apply"]);
  check("M16: a first-generation file newer than the orphan keeps its own Current state", () => {
    const cs = section(read(progressOf(older.firstSid)), "## Current state") || [];
    return r1.status === 0 && cs.includes("marker-cs-first") && !cs.includes("marker-cs-downstream") ? undefined : `${why(r1)} Current state=${show(cs)}`;
  });
  const newer = setup("m16b", { downstreamNewer: true });
  const r2 = cli(["--apply"]);
  check("M16: an orphan newer than the first-generation file supplies the Current state", () => {
    const cs = section(read(progressOf(newer.firstSid)), "## Current state") || [];
    return r2.status === 0 && cs.includes("marker-cs-downstream") && !cs.includes("marker-cs-first") ? undefined : `${why(r2)} Current state=${show(cs)}`;
  });
}));
caseEnd();

caseBegin("usage-error-exits-2", "bin/migrate-orphan-progress-files");
test("usage-error-exits-2", () => noNewFailures(failureCount, () => {
  for (const args of [["--bogus"], ["--apply", "extra"]]) {
    const r = cli(args);
    check(`M10: ${args.join(" ")} exits 2`, () => (r.status === 2 ? undefined : why(r)));
  }
}));
caseEnd();
