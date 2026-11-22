"use strict";
// tests/bin/feature-2941-pm-state-cli.js
// Tests: bin/pm-state, bin/lib/pm-state/cli.js, bin/lib/pm-state/ancestry.js, bin/lib/pm-state/sequence.js, bin/lib/pm-state/owner.js
// Tags: TL2, scope:issue-specific, pm-session, cli, forge, issue-2942, owner-batch
// #2941 bin/pm-state show / list / owner / set-sequence / set-reason against a seeded PM world; the forge is a
// fake gh on PATH (black-box: no assumption on the deps shape of cli.js). Dispatcher only.
// TL3 gap: real gh against a live GitHub sub-issue tree is not exercised.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { after } = require("node:test");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const restore = isolate();
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "pm-cli-"));
after(() => { fs.rmSync(tmp, { recursive: true, force: true }); restore(); });

const DIR = path.join(__dirname, "feature-2941-pm-state-cli");
const { makeFixture } = require(path.join(DIR, "fixture.js"));
const { seedWorld } = require(path.join(DIR, "world.js"));
const reads = require(path.join(DIR, "read-cases.js"));
const seq = require(path.join(DIR, "sequence-cases.js"));
const reason = require(path.join(DIR, "reason-cases.js"));
const dup = require(path.join(DIR, "duplicate-cases.js"));
const batch = require(path.join(DIR, "batch-cases.js"));
const F = makeFixture(tmp);
seedWorld(F);

caseBegin("pm-state-show-and-list", "bin/lib/pm-state/cli.js");
reads.show(F);
caseEnd();

caseBegin("pm-state-owner-direct-ancestor-failure", "bin/lib/pm-state/owner.js");
reads.owner(F);
caseEnd();

caseBegin("pm-state-set-sequence-range-and-fail-closed", "bin/lib/pm-state/sequence.js");
seq.sequence(F);
caseEnd();

caseBegin("pm-state-owner-ref-normalization-cross-repo", "bin/lib/pm-state/ancestry.js");
reads.refs(F);
caseEnd();

caseBegin("pm-state-set-sequence-refs-and-call-cap", "bin/lib/pm-state/ancestry.js");
seq.limits(F);
caseEnd();

caseBegin("pm-state-set-reason-caller-last-entry", "bin/lib/pm-state/cli.js");
reason.reason(F);
caseEnd();

caseBegin("pm-state-set-sequence-duplicate-issue", "bin/lib/pm-state/sequence.js");
dup.duplicates(F);
caseEnd();

caseBegin("pm-state-owner-batched-issues", "bin/lib/pm-state/cli.js");
batch.batch(F);
caseEnd();
