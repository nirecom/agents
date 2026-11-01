#!/usr/bin/env node
"use strict";
// Tests: hooks/lib/state-handoff-record/legacy-handoff-md.js, bin/lib/resume-session/upstream-view.js, bin/resume-session-detect
// Tags: TL2, session, resume, handoff, state-handoff-record, input-validation, path-traversal, security, symlink, regression-2576, regression-2302, regression-2652, scope:issue-specific, pwsh-not-required
// #2576/#2652: `--from` shows the session-upstream's state handoff records (and, during the
// migration, its pre-#2652 <sid>.control/handoff.md) through the state handoff reader, not an
// artifact. #2302: an id failing SESSION_ID_VALID_RE resolves nothing — unknown-session, exit 3.
// Dispatch only; the parts live in feature-2576-from-handoff/.

const { after, test } = require("node:test");
const { caseBegin, caseEnd } = require("../lib/harness");
const { noNewFailures } = require("../lib/case-verdict");
const C = require("./feature-2576-from-handoff/common");
const fromView = require("./feature-2576-from-handoff/from-view");
const validation = require("./feature-2576-from-handoff/validation");
const handoffFile = require("./feature-2576-from-handoff/handoff-file");
const errors = require("./feature-2576-from-handoff/errors");

const { totals } = C;
const fails = () => totals.failed;
after(() => {
  process.stdout.write(`Total: ${totals.passed} passed, ${totals.failed} failed, ${totals.skipped} skipped\n`);
  if (totals.skipped > 0) process.stderr.write(`WARNING: ${totals.skipped} case(s) skipped — see SKIP lines\n`);
  C.cleanup();
});

caseBegin("from-renders-state-handoff-record", "bin/lib/resume-session/upstream-view.js");
test("from-renders-state-handoff-record", () => noNewFailures(fails, fromView.rendersStateRecord));
caseEnd();

caseBegin("from-legacy-handoff-only-is-artifacts-only", "bin/lib/resume-session/upstream-view.js");
test("from-legacy-handoff-only-is-artifacts-only", () => noNewFailures(fails, fromView.legacyOnlyIsArtifactsOnly));
caseEnd();

caseBegin("from-state-and-legacy-in-time-order", "bin/lib/resume-session/upstream-view.js");
test("from-state-and-legacy-in-time-order", () => noNewFailures(fails, fromView.stateAndLegacyInTimeOrder));
caseEnd();

caseBegin("from-nothing-is-none", "bin/lib/resume-session/upstream-view.js");
test("from-nothing-is-none", () => noNewFailures(fails, fromView.nothingIsNone));
caseEnd();

caseBegin("from-reads-the-reader-once", "bin/lib/resume-session/upstream-view.js");
test("from-reads-the-reader-once", () => noNewFailures(fails, fromView.readsTheReaderOnce));
caseEnd();

caseBegin("from-invalid-sid-is-unknown-session", "bin/lib/resume-session/upstream-view.js");
test("from-invalid-sid-is-unknown-session", () => noNewFailures(fails, validation.invalidSidIsUnknownSession));
caseEnd();

caseBegin("upstream-view-entry-validation", "bin/lib/resume-session/upstream-view.js");
test("upstream-view-entry-validation", () => noNewFailures(fails, validation.entryValidation));
caseEnd();

caseBegin("artifacts-for-per-kind-resolution", "bin/lib/resume-session/upstream-view.js");
test("artifacts-for-per-kind-resolution", () => noNewFailures(fails, validation.artifactsPerKind));
caseEnd();

caseBegin("handoff-directory-is-not-a-handoff", "hooks/lib/state-handoff-record/legacy-handoff-md.js");
test("handoff-directory-is-not-a-handoff", () => noNewFailures(fails, handoffFile.directoryIsNotAHandoff));
caseEnd();

caseBegin("handoff-symlink-is-not-a-handoff", "hooks/lib/state-handoff-record/legacy-handoff-md.js");
test("handoff-symlink-is-not-a-handoff", async (t) => {
  let skipReason = null;
  await noNewFailures(fails, () => { skipReason = handoffFile.symlinkIsNotAHandoff(); });
  if (skipReason) t.skip(skipReason);
});
caseEnd();

caseBegin("from-corrupt-state-names-state-error", "bin/lib/resume-session/upstream-view.js");
test("from-corrupt-state-names-state-error", () => noNewFailures(fails, errors.corruptStateNamesState));
caseEnd();

caseBegin("from-reader-exception-is-reader-error", "bin/lib/resume-session/upstream-view.js");
test("from-reader-exception-is-reader-error", () => noNewFailures(fails, errors.readerExceptionIsReaderError));
caseEnd();

caseBegin("from-error-and-no-error-views", "bin/lib/resume-session/upstream-view.js");
test("from-error-and-no-error-views", () => noNewFailures(fails, errors.errorAndNoErrorViews));
caseEnd();
