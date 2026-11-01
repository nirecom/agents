"use strict";
// Fixtures shared by the feature-2863-*.js entrypoints (#2863): JavaScript test bodies with and
// without node:test, and the expected wording of the required-runner gate. Holds no case markers.

const lines = (...l) => l.join("\n") + "\n";
const HEAD_LINES = (tests) => ["\"use strict\";", `// Tests: ${tests}`, "// Tags: TL1, fixture, scope:issue-specific"];
const HARNESS = "const { isolate } = require(\"../lib/harness\");";

// plain(tests, ...extra) — a test that requires only the harness: a plain script.
const plain = (tests = "bin/a.js", ...extra) => lines(...HEAD_LINES(tests), HARNESS, ...extra, "isolate();");
const BODY = {
  plain: plain(),
  nodeTest: lines(...HEAD_LINES("bin/a.js"), HARNESS, "const { test } = require(\"node:test\");",
    "isolate();", "test(\"fixture case\", () => {});"),
  importTest: lines(...HEAD_LINES("bin/a.js"), "import { test } from \"node:test\";", HARNESS,
    "isolate();", "test(\"fixture case\", () => {});"),
  dynamicImport: lines(...HEAD_LINES("bin/a.js"), HARNESS, "isolate();",
    "import(\"node:test\").then(({ test }) => test(\"fixture case\", () => {}));"),
  // node:test appears only where the analyzer blanks the text: comments and string literals.
  lineComment: plain("bin/a.js", "// const { test } = require(\"node:test\");"),
  blockComment: plain("bin/a.js", "/* const { test } = require(\"node:test\"); */"),
  string: plain("bin/a.js", "const note = 'require(\"node:test\")';"),
  template: plain("bin/a.js", "const note = `require(\"node:test\")`;"),
  // two targets and no case markers: the case-marker gate blocks it as well.
  twoPathsPlain: plain("bin/a.js, bin/b.js"),
};

const CODE = "MISSING_TEST_RUNNER";
const WARN_CODE = "TEST_RUNNER_CHECK_RUNTIME_UNAVAILABLE";
const DOC = "skills/_shared/test-design/case-markers/js.md";
const HINT_TEXT = "Require node:test and write each case as test(...): const { test } = require(\"node:test\"); "
  + "keep the shared helpers from require(\"../lib/harness\")";
const HINT = `${HINT_TEXT} — see ${DOC}.`;
const COMMIT_HEADLINE = "Commit blocked: new test file(s) do not run under their language's required runner.";
const highLine = (name) => `HIGH: ${name}: new test entrypoint does not run under its required runner (skip-reason custom-runner) code=${CODE}`;
const SKIP_LINE = "pre-commit: test language registry not readable — test-runner check skipped (commit continues)";

module.exports = { lines, plain, BODY, CODE, WARN_CODE, DOC, HINT_TEXT, HINT, COMMIT_HEADLINE, highLine, SKIP_LINE };
