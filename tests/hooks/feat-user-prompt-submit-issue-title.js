"use strict";
// tests/hooks/feat-user-prompt-submit-issue-title.js
// Tests: hooks/user-prompt-submit-issue-title.js, hooks/user-prompt-submit-issue-title/target.js, hooks/user-prompt-submit-issue-title/title.js, hooks/user-prompt-submit-issue-title/record.js
// Tags: TL1, TL2, scope:common, user-prompt-submit, session-title, issue-title
// #299: a wf-init session gets "#N <issue title>" via hookSpecificOutput.sessionTitle. Assumed API:
// run(input, deps) from the entry; deps = {fetchTitle(ref) -> string|null, now() -> ms, spawnSync};
// without fetchTitle the hook runs originUrl + tracker.issueTitle with deps.spawnSync. Constants
// ORIGIN_TIMEOUT_MS / TRACKER_TIMEOUT_MS / MAX_ATTEMPTS / COOLDOWN_MS: entry first, else title.js.
// Dispatcher only (Pattern A): fixtures and cases live in ./feat-user-prompt-submit-issue-title/.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { after } = require("node:test");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

// TL3 gap: the real VS Code / Claude app rendering of sessionTitle is not observed (the output
// shape rests on the user's own client check), nor real gh / glab against a live forge.
// Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
// bin/check-verification-gate.sh category: hook-registration.

const restore = isolate();
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "issue-title-"));
const DIR = path.join(__dirname, "feat-user-prompt-submit-issue-title");
const { makeFixtures } = require(path.join(DIR, "fixtures.js"));
const target = require(path.join(DIR, "target-cases.js"));
const budget = require(path.join(DIR, "budget-cases.js"));
const record = require(path.join(DIR, "record-cases.js"));
const output = require(path.join(DIR, "output-cases.js"));
const forge = require(path.join(DIR, "forge-cases.js"));
const F = makeFixtures(tmp);
after(() => { F.restoreEnv(); fs.rmSync(tmp, { recursive: true, force: true }); restore(); });

caseBegin("H1 wf-init prompt forms decide the target and the refs", "hooks/user-prompt-submit-issue-title/target.js");
target.promptForms(F);
caseEnd();

caseBegin("H2-H3 later prompts follow the begun mark; cache and non-targets spawn nothing", "hooks/user-prompt-submit-issue-title/target.js");
target.begunMark(F);
target.cacheAndNonTarget(F);
caseEnd();

caseBegin("H4 the real spawn path stays inside the 5 s hook budget", "hooks/user-prompt-submit-issue-title/title.js");
budget.budget(F);
caseEnd();

caseBegin("H5 failed fetches cool down and give up after MAX_ATTEMPTS", "hooks/user-prompt-submit-issue-title/title.js");
budget.cooldown(F);
caseEnd();

caseBegin("H6-H8 chain record, unconfirmed roots and the last-emitted comparison", "hooks/user-prompt-submit-issue-title/record.js");
record.chainRecord(F);
record.unconfirmedRoots(F);
record.lastEmitted(F);
caseEnd();

caseBegin("H9 fail-open in run and in the hook process", "hooks/user-prompt-submit-issue-title.js");
output.failOpen(F);
caseEnd();

caseBegin("H10 title formatting", "hooks/user-prompt-submit-issue-title/title.js");
output.formatting(F);
caseEnd();

caseBegin("H11 the hook routes through the forge of the origin, never a silent GitHub fallback", "hooks/user-prompt-submit-issue-title/title.js");
forge.forgeRouting(F);
caseEnd();

caseBegin("H12 a traversal session_id or first_session_id writes nothing and emits nothing", "hooks/user-prompt-submit-issue-title/record.js");
record.traversal(F);
caseEnd();

caseBegin("H13 a POSIX drive-letter stdin cwd is normalized before git runs", "hooks/user-prompt-submit-issue-title/title.js");
output.posixCwd(F);
caseEnd();

caseBegin("H14 the record keeps 20 titles / failures and a success clears the failure", "hooks/user-prompt-submit-issue-title/title.js");
output.recordCaps(F);
caseEnd();

caseBegin("H15 a project-local GITLAB_HOSTNAME routes a self-hosted origin to glab --hostname", "hooks/user-prompt-submit-issue-title/title.js");
forge.selfHosted(F);
caseEnd();

caseBegin("H16 a project-local FORGE_TRACKER picks the tracker over the codehost", "hooks/user-prompt-submit-issue-title/title.js");
forge.trackerPin(F);
caseEnd();
