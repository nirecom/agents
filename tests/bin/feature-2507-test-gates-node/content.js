"use strict";
// Tests: bin/check-test-frontmatter.sh
// Tags: TL1, bin, golden, fixture, test-lang-exception:symmetry, scope:issue-specific
// Content builders of the test-gates corpus (#2507 S4). Holds no case markers: the marker and
// harness lines below are fixture text written into throwaway repos, never run here.
const SRC_SH = 'source "$ROOT/tests/lib/harness.sh"';
const REQ_JS = 'const { caseBegin, caseEnd } = require("../lib/harness");';
const TAGS = "TL1, scope:issue-specific";

// head(prefix, o) — the Tests: / Tags: lines; null leaves a line out, "" writes it empty.
function head(prefix, o, tests) {
  const l = [];
  if (o.tests !== null) l.push(`${prefix} Tests: ${o.tests === undefined ? tests : o.tests}`);
  if (o.tags !== null) l.push(`${prefix} Tags: ${o.tags === undefined ? TAGS : o.tags}`);
  return l;
}
const join = (lines) => `${lines.join("\n")}\n`;

function sh(o = {}) {
  return join(["#!/usr/bin/env bash", ...head("#", o, "bin/a.sh"), ...(o.src === false ? [] : [SRC_SH]), ...(o.body || [])]);
}
function js(o = {}) {
  return join(['"use strict";', ...head("//", o, "bin/b.js"), ...(o.src === false ? [] : [REQ_JS]), ...(o.body || [])]);
}
function pester(o = {}) {
  return join([...head("#", o, "bin/d.ps1, bin/e.ps1"), 'Describe "x" {', '  It "y" { 1 | Should -Be 1 }', "}", ...(o.body || [])]);
}
function pytest(o = {}) {
  return join([...head("#", o, "bin/e.py, bin/f.py"), "def test_x():", "    assert True", ...(o.body || [])]);
}

// Bash and js marker pairs, as fixture lines.
const shCase = (name, target, inner = []) => [`case_begin "${name}" "${target}"`, ...inner, "case_end"];
const jsCase = (name, target, inner = []) => [`caseBegin("${name}", "${target}");`, ...inner, "caseEnd();"];

// The files every fixture repo carries: helper libraries (so the helper checks are live) and
// code files the Tests: tokens name, one extensionless with a node shebang.
const BASE = {
  "tests/lib/harness.sh": "# fixture helper library\n",
  "tests/lib/harness.js": "module.exports = {};\n",
  "bin/a.sh": "#!/usr/bin/env bash\necho a\n",
  "bin/b.sh": "#!/usr/bin/env bash\necho b\n",
  "bin/b.js": "module.exports = 1;\n",
  "bin/c.js": "module.exports = 2;\n",
  "bin/tool": "#!/usr/bin/env node\nconsole.log(1);\n",
  "bin/d.ps1": "Write-Output d\n",
  "bin/e.py": "print(1)\n",
  "docs/x.md": "# x\n",
};

module.exports = { sh, js, pester, pytest, shCase, jsCase, BASE, TAGS };
