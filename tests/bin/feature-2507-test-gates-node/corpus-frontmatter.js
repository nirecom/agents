"use strict";
// Tests: bin/check-test-frontmatter.sh
// Tags: TL1, bin, golden, fixture, test-lang-exception:symmetry, scope:issue-specific
// The check-test-frontmatter.sh --staged / --all part of the D7 corpus (#2507 S4). A tree is
// { head: committed files or null for no commit, index: staged files, work: unstaged files };
// a run is one CLI call in a tree. `codes` names what the run is there to pin.
const C = require("./content");

const PASS2 = ["PASS=0", "PASS=0"];
const SELF = ["PASS=0", "FAIL=0", "pass() {", "  :", "}"];

const fmHead = {
  "tests/fm-old.sh": C.sh(),
  "tests/bin/fm-existing-nosrc.sh": C.sh({ src: false }),
  "tests/bin/fm-si-old.sh": C.sh({ body: ["PASS=0"] }),
  "tests/bin/fm-same.sh": C.sh({ body: ["PASS=0"] }),
  "tests/bin/fm-trail.sh": C.sh({ body: ["PASS=0"] }),
};

const trees = {
  fm: {
    head: fmHead,
    index: {
      "tests/bin/fm-ok.sh": C.sh(),
      "tests/bin/fm-ok.js": C.js(),
      "tests/bin/fm-no-tests.sh": C.sh({ tests: null }),
      "tests/bin/fm-empty-tests.sh": C.sh({ tests: "" }),
      "tests/bin/fm-bad-token.sh": C.sh({ tests: "bin/a.sh, bin/a b.sh, bin/x;y.sh, , bin/c.js" }),
      "tests/bin/fm-no-tags.sh": C.sh({ tags: null }),
      "tests/bin/fm-no-scope.sh": C.sh({ tags: "TL1, scope:other" }),
      "tests/bin/fm-scope-space.js": C.js({ tags: "TL1, scope: common" }),
      "tests/bin/fm-tags-late.sh": C.sh({ tags: null, body: ["", "", "", "", "", "", "", "# Tags: scope:common"] }),
      "tests/fm-flat.sh": C.sh(),
      "tests/fm-flat.js": C.js(),
      "tests/fm-old.sh": C.sh({ tests: null }),
      "tests/run-all.sh": C.sh({ tags: null }),
      "tests/bin/fm-nosrc.sh": C.sh({ src: false }),
      "tests/bin/fm-nosrc.js": C.js({ src: false }),
      "tests/bin/fm-src-comment.sh": C.sh({ src: false, body: ['# source "$ROOT/tests/lib/harness.sh"'] }),
      "tests/bin/fm-existing-nosrc.sh": C.sh({ src: false, body: ["# edited"] }),
      "tests/hooks/fm-suite/sub.sh": C.sh({ src: false, tests: null }),
      "tests/bin/fm-si-new.sh": C.sh({ body: SELF }),
      "tests/bin/fm-si-old.sh": C.sh({ body: PASS2 }),
      "tests/bin/fm-same.sh": C.sh({ body: ["PASS=0"] }),
      "tests/bin/fm-trail.sh": `${C.sh({ body: ["PASS=0"] })}\n\n\n`,
      "tests/bin/fm-si.js": C.js({ body: ["let passed = 0;", "function caseBegin() {}"] }),
      "tests/bin/fm-crlf.sh": C.sh({ tags: "TL1, scope:common" }).replace(/\n/g, "\r\n"),
      "tests/bin/fm-crlf-bad.sh": C.sh({ tests: "bin/a.sh, bin/b.sh", tags: "TL1" }).replace(/\n/g, "\r\n"),
      "tests/bin/fm-nonl.sh": C.sh().replace(/\n$/, ""),
      "tests/_archive/fm-arch.sh": C.sh({ tests: null }),
      "tests/lib/fm-helper.sh": "# helper\n",
      "tests/bin/fm-readme.md": "# readme\n",
      "tests/bin/test_fm.txt": "# Tests:\n",
      "bin/fm-notatest.sh": "# no headers\n",
    },
    work: { "tests/bin/fm-work.sh": C.sh({ tags: null }) },
  },
  fmNew: {
    head: null,
    index: { "tests/bin/fm-first.sh": C.sh({ body: ["PASS=0"] }), "tests/fm-first-flat.sh": C.sh() },
    work: {},
  },
  fmRt: {
    head: null,
    index: { "tests/bin/fm.Tests.ps1": C.pester(), "tests/bin/test_fm.py": C.pytest() },
    work: {},
  },
};

const staged = (files) => ["--staged", ...files];
const runs = [
  { id: "fm-ok", tree: "fm", args: staged(["tests/bin/fm-ok.sh", "tests/bin/fm-ok.js", "tests/bin/fm-scope-space.js", "tests/bin/fm-crlf.sh"]), codes: [] },
  { id: "fm-tests-header", tree: "fm", args: staged(["tests/bin/fm-no-tests.sh", "tests/bin/fm-empty-tests.sh", "tests/bin/fm-bad-token.sh"]), codes: ["MISSING_TESTS_HEADER", "INVALID_TESTS_TOKEN"] },
  { id: "fm-scope-tag", tree: "fm", args: staged(["tests/bin/fm-no-tags.sh", "tests/bin/fm-no-scope.sh", "tests/bin/fm-tags-late.sh", "tests/bin/fm-crlf-bad.sh"]), codes: ["MISSING_SCOPE_TAG"] },
  { id: "fm-flat", tree: "fm", args: staged(["tests/fm-flat.sh", "tests/fm-flat.js", "tests/fm-old.sh", "tests/run-all.sh"]), codes: ["FLAT_TEST_SH_REJECTED", "FLAT_TEST_REJECTED"] },
  { id: "fm-harness-source", tree: "fm", args: staged(["tests/bin/fm-nosrc.sh", "tests/bin/fm-nosrc.js", "tests/bin/fm-src-comment.sh", "tests/bin/fm-existing-nosrc.sh", "tests/hooks/fm-suite/sub.sh"]), codes: ["MISSING_HARNESS_SOURCE"] },
  { id: "fm-self-impl", tree: "fm", args: staged(["tests/bin/fm-si-new.sh", "tests/bin/fm-si-old.sh", "tests/bin/fm-same.sh", "tests/bin/fm-trail.sh", "tests/bin/fm-si.js"]), codes: ["SELF_IMPLEMENTED_HARNESS"] },
  { id: "fm-filter", tree: "fm", args: staged(["tests/_archive/fm-arch.sh", "tests/lib/fm-helper.sh", "tests/bin/fm-readme.md", "tests/bin/test_fm.txt", "bin/fm-notatest.sh"]), codes: [] },
  { id: "fm-content-forms", tree: "fm", args: staged(["tests/bin/fm-nonl.sh", "tests/bin/fm-work.sh", "tests/bin/fm-absent.sh"]), codes: ["MISSING_SCOPE_TAG"] },
  { id: "fm-no-head", tree: "fmNew", args: staged(["tests/bin/fm-first.sh", "tests/fm-first-flat.sh"]), codes: ["FLAT_TEST_SH_REJECTED", "SELF_IMPLEMENTED_HARNESS"] },
  { id: "fm-runtime-unavailable", tree: "fmRt", path: "noRuntime", args: staged(["tests/bin/fm.Tests.ps1", "tests/bin/test_fm.py"]), codes: ["SELF_IMPL_CHECK_RUNTIME_UNAVAILABLE"] },
  { id: "fm-all", tree: "fm", args: ["--all"], codes: ["MISSING_TESTS_HEADER", "MISSING_SCOPE_TAG"] },
  { id: "fm-usage-none", tree: "fmNew", args: [], codes: [] },
  { id: "fm-usage-mode", tree: "fmNew", args: ["--bogus"], codes: [] },
  { id: "fm-no-node", tree: "fm", path: "noNode", args: staged(["tests/bin/fm-ok.sh"]), codes: [] },
];

module.exports = { trees, runs: runs.map((r) => ({ cli: "frontmatter", path: "full", ...r })) };
