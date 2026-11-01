"use strict";
// Tests: hooks/lib/sentinel-patterns.js, hooks/workflow-mark/glossary-accept-handler.js, bin/check-glossary-ledger-grant
// Tags: TL2, hooks, glossary, glossary-drift, sentinel, workflow-mark, deterministic, scope:issue-specific
// #2529 T4 (the GLOSSARY_ACCEPTED sentinel): T4-1 the regex pair and the handler's malformed
// refusals, T4-2 the grant targets (a) findings, (b) provenance blocks, (c) tagged ledger
// concerns, and the ledger-grant CLI. T4-3 (the ask rule) lives in
// tests/install/feature-2280-settings-deny-anchor.sh.
// Dispatch only; the parts live in feat-2529-glossary-accept/, the fixture is shared with
// tests/bin/feat-2529-glossary-drift.js.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { after, test } = require("node:test");
const { noNewFailures } = require("../lib/case-verdict");

const restore = isolate();
const F = require("../bin/feat-2529-glossary-drift/fixture");
const regex = require("./feat-2529-glossary-accept/regex");
const grant = require("./feat-2529-glossary-accept/grant");
const ledger = require("./feat-2529-glossary-accept/ledger");
const cross = require("./feat-2529-glossary-accept/cross-stage");
after(() => {
  F.finish();
  restore();
});
const verdict = (fn) => () => noNewFailures(F.failureCount, fn);
// The ledger-grant fixture the "(c) tagged ledger concerns" case returns; later cases reuse it.
let at;

caseBegin("T4-1 GLOSSARY_ACCEPTED regex pair and sentinel registration", "hooks/lib/sentinel-patterns.js");
test("T4-1 GLOSSARY_ACCEPTED regex pair and sentinel registration", verdict(() => regex.patterns(F)));
caseEnd();

caseBegin("T4-1 handler refuses malformed bodies and a missing session id", "hooks/workflow-mark/glossary-accept-handler.js");
test("T4-1 handler refuses malformed bodies and a missing session id", verdict(() => regex.format(F)));
caseEnd();

caseBegin("T4-2 (a) findings: normalization, duplicate, preemptive, discriminators", "hooks/workflow-mark/glossary-accept-handler.js");
test("T4-2 (a) findings: normalization, duplicate, preemptive, discriminators", verdict(() => grant.findings(F)));
caseEnd();

caseBegin("T4-2 (a) stale record: artifact, glossary, intent rows", "hooks/workflow-mark/glossary-accept-handler.js");
test("T4-2 (a) stale record: artifact, glossary, intent rows", verdict(() => grant.stale(F)));
caseEnd();

caseBegin("T4-2 (b) provenance blocks", "hooks/workflow-mark/glossary-accept-handler.js");
test("T4-2 (b) provenance blocks", verdict(() => grant.provenance(F)));
caseEnd();

caseBegin("T4-2 grant scope is one stage and one record", "hooks/workflow-mark/glossary-accept-handler.js");
test("T4-2 grant scope is one stage and one record", verdict(() => grant.scope(F)));
caseEnd();

caseBegin("T4-2 (c) tagged ledger concerns at every ledger stage", "hooks/workflow-mark/glossary-accept-handler.js");
test("T4-2 (c) tagged ledger concerns at every ledger stage", verdict(() => { at = ledger.grants(F); }));
caseEnd();

caseBegin("T4-2 (c) only pending tagged concerns of the current stage", "hooks/workflow-mark/glossary-accept-handler.js");
test("T4-2 (c) only pending tagged concerns of the current stage", verdict(() => ledger.pending(F)));
caseEnd();

caseBegin("T4-2 (c) unreadable ledger fails closed without blocking (a)/(b)", "hooks/workflow-mark/glossary-accept-handler.js");
test("T4-2 (c) unreadable ledger fails closed without blocking (a)/(b)", verdict(() => ledger.failClosed(F)));
caseEnd();

caseBegin("T4-2 (c) Windows plans-dir forms", "hooks/workflow-mark/glossary-accept-handler.js");
test("T4-2 (c) Windows plans-dir forms", verdict(() => ledger.windowsPath(F)));
caseEnd();

caseBegin("T4-2 (c) ledger_grants survive --record", "hooks/workflow-mark/glossary-accept-handler.js");
test("T4-2 (c) ledger_grants survive --record", verdict(() => ledger.carried(F, at)));
caseEnd();

caseBegin("T4-2 check-glossary-ledger-grant exit codes", "bin/check-glossary-ledger-grant");
test("T4-2 check-glossary-ledger-grant exit codes", verdict(() => ledger.cli(F, at)));
caseEnd();

caseBegin("#2828 (a) resumed session: grant recorded against the upstream-bound record", "hooks/workflow-mark/glossary-accept-handler.js");
test("#2828 (a) resumed session: grant recorded against the upstream-bound record", verdict(() => cross.resumed(F)));
caseEnd();

caseBegin("#2828 (b) finding at a stage other than the current step", "hooks/workflow-mark/glossary-accept-handler.js");
test("#2828 (b) finding at a stage other than the current step", verdict(() => cross.otherStage(F)));
caseEnd();

caseBegin("#2828 (c) a refused grant names its reason", "hooks/workflow-mark/glossary-accept-handler.js");
test("#2828 (c) a refused grant names its reason", verdict(() => cross.reasons(F)));
caseEnd();
