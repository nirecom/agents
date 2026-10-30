"use strict";
// Tests: bin/check-case-markers.sh
// Tags: TL1, bin, golden, fixture, test-lang-exception:symmetry, scope:issue-specific
// The check-case-markers / check-test-language-match / check-self-impl part of the D7 corpus
// (#2507 S4). Same tree and run shapes as corpus-frontmatter.js; these CLIs read the working
// tree, so every file sits in `work` (or `head` when HEAD matters).
const C = require("./content");

const AB = "bin/a.sh, bin/b.sh";
const BC = "bin/b.js, bin/c.js";
const EXC = (v) => `TL1, scope:issue-specific, test-lang-exception:${v}`;
const lmAddHead = C.sh({ tests: AB, body: ["pass one"] });
const siTwoHead = C.sh({ body: ["PASS=0"] });

const trees = {
  mk: {
    head: null,
    index: {},
    work: {
      "tests/bin/mk-ok.sh": C.sh({ tests: AB, body: [...C.shCase("one", "bin/a.sh", ["pass ok"]), ...C.shCase("two", "bin/b.sh")] }),
      "tests/bin/mk-none.sh": C.sh({ tests: AB, body: ["pass ok"] }),
      "tests/bin/mk-single.sh": C.sh({ body: ["pass ok"] }),
      "tests/bin/mk-noheader.sh": C.sh({ tests: null, body: ["pass ok"] }),
      "tests/bin/mk-indent.sh": C.sh({ tests: AB, body: ['  case_begin "one" "bin/a.sh"', "  case_end"] }),
      "tests/bin/mk-depth.sh": C.sh({ tests: AB, body: ["if true; then", ...C.shCase("one", "bin/a.sh"), "fi"] }),
      "tests/bin/mk-open.sh": C.sh({ tests: AB, body: ['case_begin "one" "bin/a.sh"', "pass ok"] }),
      "tests/bin/mk-target.sh": C.sh({ tests: AB, body: C.shCase("one", "bin/a b.sh") }),
      "tests/bin/mk-quote.sh": C.sh({ tests: AB, body: ['X="first', 'second"', "if true; then", ...C.shCase("one", "bin/a.sh"), "fi"] }),
      "tests/bin/mk-ok.js": C.js({ tests: BC, body: [...C.jsCase("one", "bin/b.js"), ...C.jsCase("two", "bin/c.js")] }),
      "tests/bin/mk-none.js": C.js({ tests: BC, body: ["const x = 1;"] }),
      "tests/bin/mk-dup.js": C.js({ tests: BC, body: [...C.jsCase("one", "bin/b.js"), ...C.jsCase("one", "bin/b.js")] }),
      "tests/bin/mk-depth.js": C.js({ tests: BC, body: ["function f() {", ...C.jsCase("one", "bin/b.js"), "}"] }),
      "tests/bin/mk-open.js": C.js({ tests: BC, body: ['caseBegin("one", "bin/b.js");'] }),
      "tests/bin/mk-const.js": C.js({ tests: BC, body: ['caseBegin(NAME, "bin/b.js");', "caseEnd();"] }),
      "tests/bin/mk-comment.js": C.js({ tests: BC, body: ["/*", 'caseBegin("one", "bin/b.js");', "*/", ...C.jsCase("one", "bin/b.js")] }),
      "tests/bin/mk.Tests.ps1": C.pester(),
      "tests/bin/test_mk.py": C.pytest(),
      "tests/bin/test_mk.txt": `# Tests: ${AB}\n`,
      "tests/bin/mk.txt": `# Tests: ${AB}\n`,
    },
  },
  // Conforming pester / pytest files the real reader children read (runtime-readers-cases.js);
  // no golden run uses this tree, the bash CLI is run live beside the Node one.
  rt: {
    head: null,
    index: {},
    work: {
      "bin/g.ps1": "Write-Output g\n",
      "bin/f.py": "print(2)\n",
      "tests/bin/rt.Tests.ps1": [`# Tests: bin/d.ps1, bin/g.ps1`, `# Tags: ${C.TAGS}`, "",
        "Describe 'alpha' -Tag 'target:bin/d.ps1' {", "    It 'one' { 1 | Should -Be 1 }", "}", "",
        "Describe 'beta' -Tag 'target:bin/g.ps1' {", "    It 'two' {", "        2 | Should -Be 2", "    }", "}", ""].join("\n"),
      "tests/bin/test_rt.py": [`# Tests: bin/e.py, bin/f.py`, `# Tags: ${C.TAGS}`, "import pytest", "", "",
        '@pytest.mark.target("bin/e.py")', "def test_alpha():", "    assert True", "", "",
        '@pytest.mark.target("bin/f.py")', "class TestBeta:", "    def test_one(self):", "        assert True", ""].join("\n"),
    },
  },
  lm: {
    head: { "tests/bin/lm-add.sh": lmAddHead },
    index: {},
    work: {
      ".head/lm-add.sh": lmAddHead,
      "tests/bin/lm-add.sh": C.sh({ tests: AB, body: ["pass one", "pass two", "pass three"] }),
      "tests/bin/lm-new-add.sh": C.sh({ tests: AB, body: ["pass one", "pass two"] }),
      "tests/bin/lm-ok.sh": C.sh({ tests: "bin/a.sh" }),
      "tests/bin/lm-mis.sh": C.sh({ tests: "bin/b.js" }),
      "tests/bin/lm-mis-line.sh": C.sh({ tests: "bin/a.sh, bin/b.js", body: [...C.shCase("one", "bin/a.sh"), ...C.shCase("two", "bin/b.js")] }),
      "tests/bin/lm-shebang.sh": C.sh({ tests: "bin/tool" }),
      "tests/bin/lm-mis.js": C.js({ tests: "bin/a.sh" }),
      "tests/bin/lm-bad-exc.sh": C.sh({ tests: "bin/b.js", tags: EXC("bogus") }),
      "tests/bin/lm-two-exc.sh": C.sh({ tests: "bin/b.js", tags: `${EXC("symmetry")}, test-lang-exception:e2e` }),
      "tests/bin/lm-exc.sh": C.sh({ tests: "bin/b.js", tags: EXC("symmetry") }),
      "tests/bin/lm-x.txt": "# Tests: bin/a.sh\n",
      "tests/bin/test_lm.txt": "# Tests: bin/a.sh\n",
    },
  },
  si: {
    head: null,
    index: {},
    work: {
      "tests/bin/si.sh": C.sh({ body: ["PASS=0", "FAIL=0 # c", "pass() {", "  :", "}", ...C.shCase("one", "bin/a.sh", ["skip() {", "  :", "}"])] }),
      "tests/bin/si-clean.sh": C.sh(),
      "tests/bin/si.js": C.js({ body: ["let passed = 0;", "var FAIL = 0", "function caseBegin() {}", "const isolate = 1;"] }),
      "tests/bin/si-two.sh": C.sh({ body: ["PASS=0", "PASS=0"] }),
      ".head/si-two.sh": siTwoHead,
      ".head/si-same.sh": C.sh({ body: ["PASS=0", "PASS=0"] }),
      "tests/bin/si.txt": "PASS=0\n",
      "tests/bin/si.Tests.ps1": C.pester(),
      "tests/bin/test_si.py": C.pytest(),
      ".manifest.tsv": "tests/bin/renamed.sh\ttests/bin/si-two.sh\t.head/si-two.sh\ntests/bin/si.js\ttests/bin/si.js\t\ntests/bin/clean.sh\ttests/bin/si-clean.sh\t\n",
      ".manifest-bad.tsv": "tests/bin/x.sh\n",
    },
  },
};

const mk = "markers";
const lm = "langmatch";
const si = "selfimpl";
const runs = [
  { id: "mk-bash", cli: mk, tree: "mk", args: ["tests/bin/mk-ok.sh", "tests/bin/mk-none.sh", "tests/bin/mk-single.sh", "tests/bin/mk-noheader.sh", "tests/bin/mk-indent.sh", "tests/bin/mk-depth.sh", "tests/bin/mk-open.sh", "tests/bin/mk-target.sh"], codes: ["MISSING_CASE_MARKERS", "MALFORMED_CASE_MARKER"] },
  { id: "mk-bash-quote", cli: mk, tree: "mk", args: ["tests/bin/mk-quote.sh"], codes: ["UNCERTAIN_CASE_MARKER"] },
  { id: "mk-js", cli: mk, tree: "mk", args: ["tests/bin/mk-ok.js", "tests/bin/mk-none.js", "tests/bin/mk-dup.js", "tests/bin/mk-depth.js", "tests/bin/mk-open.js", "tests/bin/mk-const.js", "tests/bin/mk-comment.js"], codes: ["MISSING_CASE_MARKERS", "MALFORMED_CASE_MARKER", "UNCERTAIN_CASE_MARKER"] },
  { id: "mk-runtime-unavailable", cli: mk, tree: "mk", path: "noRuntime", args: ["tests/bin/mk.Tests.ps1", "tests/bin/test_mk.py"], codes: ["CASE_MARKER_RUNTIME_UNAVAILABLE"] },
  { id: "mk-reader-unsupported", cli: mk, tree: "mk", args: ["tests/bin/test_mk.txt", "tests/bin/mk.txt"], codes: ["CASE_MARKER_READER_UNSUPPORTED"] },
  { id: "mk-rel", cli: mk, tree: "mk", args: ["--rel", "tests/bin/renamed.sh", "tests/bin/mk-none.sh"], codes: ["MISSING_CASE_MARKERS"] },
  { id: "mk-usage-none", cli: mk, tree: "mk", args: [], codes: [] },
  { id: "mk-usage-missing", cli: mk, tree: "mk", args: ["tests/bin/absent.sh"], codes: [] },
  { id: "mk-usage-rel-value", cli: mk, tree: "mk", args: ["--rel"], codes: [] },
  { id: "mk-usage-rel-two", cli: mk, tree: "mk", args: ["--rel", "x.sh", "tests/bin/mk-ok.sh", "tests/bin/mk-none.sh"], codes: [] },
  { id: "mk-no-node", cli: mk, tree: "mk", path: "noNode", args: ["tests/bin/mk-ok.sh"], codes: [] },
  { id: "lm-main", cli: lm, tree: "lm", args: ["tests/bin/lm-ok.sh", "tests/bin/lm-mis.sh", "tests/bin/lm-mis-line.sh", "tests/bin/lm-shebang.sh", "tests/bin/lm-mis.js"], codes: ["TEST_LANGUAGE_MISMATCH"] },
  { id: "lm-exception", cli: lm, tree: "lm", args: ["tests/bin/lm-bad-exc.sh", "tests/bin/lm-two-exc.sh", "tests/bin/lm-exc.sh"], codes: ["INVALID_TEST_LANG_EXCEPTION", "TEST_LANGUAGE_MISMATCH"] },
  { id: "lm-unsupported", cli: lm, tree: "lm", args: ["tests/bin/lm-x.txt", "tests/bin/test_lm.txt"], codes: ["TEST_LANGUAGE_UNSUPPORTED"] },
  { id: "lm-case-added-head", cli: lm, tree: "lm", args: ["--rel", "tests/bin/lm-add.sh", "--head", ".head/lm-add.sh", "tests/bin/lm-add.sh"], codes: ["CASE_ADDED_WITHOUT_MARKERS"] },
  { id: "lm-case-added-new", cli: lm, tree: "lm", args: ["tests/bin/lm-new-add.sh"], codes: ["CASE_ADDED_WITHOUT_MARKERS"] },
  { id: "lm-usage-none", cli: lm, tree: "lm", args: [], codes: [] },
  { id: "lm-usage-option", cli: lm, tree: "lm", args: ["--bogus", "tests/bin/lm-ok.sh"], codes: [] },
  { id: "lm-usage-rel-two", cli: lm, tree: "lm", args: ["--rel", "x.sh", "tests/bin/lm-ok.sh", "tests/bin/lm-mis.sh"], codes: [] },
  { id: "lm-usage-head-missing", cli: lm, tree: "lm", args: ["--head", ".head/absent.sh", "tests/bin/lm-ok.sh"], codes: [] },
  { id: "lm-usage-file-missing", cli: lm, tree: "lm", args: ["tests/bin/absent.sh"], codes: [] },
  { id: "lm-no-node", cli: lm, tree: "lm", path: "noNode", args: ["tests/bin/lm-ok.sh"], codes: [] },
  { id: "si-main", cli: si, tree: "si", args: ["tests/bin/si.sh", "tests/bin/si-clean.sh", "tests/bin/si.js", "tests/bin/si.txt"], codes: ["SELF_IMPLEMENTED_HARNESS", "SELF_IMPL_CHECK_UNSUPPORTED"] },
  { id: "si-head", cli: si, tree: "si", args: ["--rel", "tests/bin/si-two.sh", "--head", ".head/si-two.sh", "tests/bin/si-two.sh"], codes: ["SELF_IMPLEMENTED_HARNESS"] },
  { id: "si-head-same", cli: si, tree: "si", args: ["--head", ".head/si-same.sh", "tests/bin/si-two.sh"], codes: [] },
  { id: "si-runtime-unavailable", cli: si, tree: "si", path: "noRuntime", args: ["tests/bin/si.Tests.ps1", "tests/bin/test_si.py"], codes: ["SELF_IMPL_CHECK_RUNTIME_UNAVAILABLE"] },
  { id: "si-manifest", cli: si, tree: "si", args: ["--manifest", ".manifest.tsv"], codes: ["SELF_IMPLEMENTED_HARNESS"] },
  { id: "si-manifest-bad", cli: si, tree: "si", args: ["--manifest", ".manifest-bad.tsv"], codes: [] },
  { id: "si-usage-none", cli: si, tree: "si", args: [], codes: [] },
  { id: "si-usage-option", cli: si, tree: "si", args: ["--bogus"], codes: [] },
  { id: "si-usage-manifest-file", cli: si, tree: "si", args: ["--manifest", ".manifest.tsv", "tests/bin/si.sh"], codes: [] },
  { id: "si-usage-manifest-missing", cli: si, tree: "si", args: ["--manifest", ".absent.tsv"], codes: [] },
  { id: "si-usage-file-missing", cli: si, tree: "si", args: ["tests/bin/absent.sh"], codes: [] },
  { id: "si-no-node", cli: si, tree: "si", path: "noNode", args: ["tests/bin/si-clean.sh"], codes: [] },
];

module.exports = { trees, runs: runs.map((r) => ({ path: "full", ...r })) };
