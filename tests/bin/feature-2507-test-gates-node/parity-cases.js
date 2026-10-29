"use strict";
// Tests: hooks/lib/test-gates/case-records.js
// Tags: TL1, bin, parity, scope:issue-specific
// D7 parity bodies (#2507 S4 step 2): each Node module answers what the bash part it ports
// answers, on the corpus files (bash-driver.sh is the bash side). Holds no case markers.
// Assumed contracts (module under hooks/lib/test-gates/; a sync value or a promise of it):
//   headers.readHeaders(content, matchPath) -> { tests, tags }, each the whole header line or "";
//   case-records.read(file, matchPath) -> the crr_read TSV; self-impl.report(file, matchPath) and
//   parts/bash-case-embed.run(op, file) -> { rc, stdout }; code-language.tokenLanguage(token,
//   { root }) -> entry id or null; frontmatter.normalizeContent(s) -> s, trailing LFs cut, one added.
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const F = require("./fixture");
const D = require("./driver");

const gate = (rel) => require(path.join(F.REPO, "hooks", "lib", "test-gates", rel));
const fwd = (p) => p.replace(/\\/g, "/");
const at = (treeId, rel) => ({ abs: fwd(path.join(F.tree(treeId), rel)), rel });
const RUNTIME = ["tests/bin/mk.Tests.ps1", "tests/bin/test_mk.py"];

const MK = ["mk-ok.sh", "mk-none.sh", "mk-single.sh", "mk-indent.sh", "mk-depth.sh", "mk-open.sh", "mk-target.sh", "mk-quote.sh",
  "mk-ok.js", "mk-none.js", "mk-dup.js", "mk-depth.js", "mk-open.js", "mk-const.js", "mk-comment.js", "mk.Tests.ps1", "test_mk.py",
  "test_mk.txt", "mk.txt"];
const RECORD_FILES = [...MK.map((n) => at("mk", `tests/bin/${n}`)), at("si", "tests/bin/si.sh"), at("si", "tests/bin/si.js")];
const SELF_FILES = [...["si.sh", "si-clean.sh", "si.js", "si.txt", "si-two.sh", "si.Tests.ps1", "test_si.py"].map((n) => at("si", `tests/bin/${n}`)),
  at("mk", "tests/bin/mk-ok.sh"), at("mk", "tests/bin/mk-ok.js")];
const EMBED_FILES = ["si.sh", "si-clean.sh", "si-two.sh"].map((n) => at("si", `tests/bin/${n}`));

// answered(answers, kind) — the bash answers; throws (never a silent pass) when the kind's PATH
// cannot be built on this host.
function answered(answers, kind) {
  if (answers === null) throw new Error(`SKIP-HOST: the ${kind} PATH cannot be built on this host`);
  return answers;
}

// The bash extract_headers went with #2507, so headers.js is pinned by a table of what that
// reader returned: the first matching line within headerMaxLines (10), whole, CR dropped, "" when
// none; the comment prefix follows the match path.
const SH = "#!/usr/bin/env bash\n";
const HEADER_ROWS = [
  ["tests/bin/a.sh", `${SH}# Tests: bin/a.sh\n# Tags: TL1, scope:common\n`, "# Tests: bin/a.sh", "# Tags: TL1, scope:common"],
  ["tests/bin/a.js", "\"use strict\";\n// Tests: bin/a.js\n// Tags: TL1\n", "// Tests: bin/a.js", "// Tags: TL1"],
  ["tests/bin/a.js", "# Tests: bin/a.js\n# Tags: TL1\n", "", ""],
  ["tests/bin/test_a.py", "# Tests: bin/a.py\n# Tags: TL1\n", "# Tests: bin/a.py", "# Tags: TL1"],
  ["tests/bin/a.sh", `${SH}# Tags: TL1\n`, "", "# Tags: TL1"],
  ["tests/bin/a.sh", `${SH}# Tests: bin/a.sh\n${"x\n".repeat(8)}# Tags: late\n`, "# Tests: bin/a.sh", ""],
  ["tests/bin/a.sh", `${SH}# Tests: bin/a.sh\r\n# Tags: TL1\r\n`, "# Tests: bin/a.sh", "# Tags: TL1"],
  ["tests/bin/a.sh", `${SH}# Tests: one\n# Tests: two\n# Tags: TL1`, "# Tests: one", "# Tags: TL1"],
  ["tests/bin/a.sh", "", "", ""],
];
async function headers() {
  const H = gate("headers.js");
  for (const [i, [rel, content, tests, tags]] of HEADER_ROWS.entries()) {
    assert.deepStrictEqual(await H.readHeaders(content, rel), { tests, tags }, `headers row ${i} ${rel}`);
  }
}

async function records(files, kind) {
  const bash = answered(D.ask(files.map((f) => ["crr", f.abs, f.rel]), kind), kind);
  const CR = gate("case-records.js");
  await D.withPath(kind, async () => {
    for (const [i, f] of files.entries()) assert.strictEqual(await CR.read(f.abs, f.rel), bash[i].out, `crr ${f.rel} (${kind})`);
  });
}
const caseRecords = () => records(RECORD_FILES, "full");
const recordsUnavailable = async () => {
  const files = RUNTIME.map((r) => at("mk", r));
  const bash = answered(D.ask(files.map((f) => ["crr", f.abs, f.rel]), "noRuntime"), "noRuntime");
  for (const a of bash) assert.match(a.out, /^FILE\tunavailable\t\t(pwsh|uv)$/m, "bash pins unavailable + the runtime name");
  await records(files, "noRuntime");
};

async function selfImpl(files, kind) {
  const bash = answered(D.ask(files.map((f) => ["tsi", f.abs, f.rel]), kind), kind);
  const S = gate("self-impl.js");
  await D.withPath(kind, async () => {
    for (const [i, f] of files.entries()) {
      const got = await S.report(f.abs, f.rel);
      assert.deepStrictEqual({ rc: got.rc, stdout: got.stdout }, { rc: bash[i].rc, stdout: bash[i].out }, `tsi ${f.rel} (${kind})`);
    }
  });
}
const selfImplWindow = () => selfImpl(SELF_FILES, "full");
const selfImplUnavailable = () => selfImpl(["tests/bin/si.Tests.ps1", "tests/bin/test_si.py"].map((r) => at("si", r)), "noRuntime");

// Tokens: by source pattern, by the shebang of an extensionless file in the root, or none.
const TOKEN_FILES = {
  "bin/tool": "#!/usr/bin/env node\n", "bin/envs": "#!/usr/bin/env -S FOO=1 bash -e\n", "bin/py3": "#!/usr/bin/python3\n",
  "bin/crlf": "#!/bin/sh\r\necho\r\n", "bin/plain": "echo\n", "bin/empty": "", "bin/pw": "#! pwsh\n",
};
const TOKENS = ["bin/a.sh", "bin/b.js", "bin/x.cjs", "bin/x.mjs", "bin/d.ps1", "bin/m.psm1", "bin/e.py", "docs/x.md", "bin/absent",
  "bin/a b.sh", "bin/A.SH", ...Object.keys(TOKEN_FILES), "bin/tool.txt", "bin/"];
async function codeLanguage() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "test-gates-2507-tok-"));
  try {
    for (const [rel, text] of Object.entries(TOKEN_FILES)) F.write(root, rel, text);
    const bash = answered(D.ask(TOKENS.map((t) => ["token", fwd(root), t])), "full");
    assert.strictEqual(bash[0].out, "bash\n", "bash pins bin/a.sh -> bash");
    const CL = gate("code-language.js");
    for (const [i, t] of TOKENS.entries()) {
      const got = await CL.tokenLanguage(t, { root });
      assert.strictEqual(`${got === null ? "-" : got}\n`, bash[i].out, `token ${t}`);
    }
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

// The bash caseEmbedRules ops pre-commit uses outside crr (deps rides in crr's CASE rows). Each
// request set runs in a fresh shell, as tsi_report does: no reader's TRP_CASE_* in scope.
async function bashEmbed() {
  const B = gate(path.join("parts", "bash-case-embed.js"));
  for (const op of ["self-impl", "case-count"]) {
    const bash = answered(D.ask(EMBED_FILES.map((f) => ["embed", op, f.abs])), "full");
    for (const [i, f] of EMBED_FILES.entries()) {
      const got = await B.run(op, f.abs);
      assert.deepStrictEqual({ rc: got.rc, stdout: got.stdout }, { rc: bash[i].rc, stdout: bash[i].out }, `embed ${op} ${f.rel}`);
    }
  }
}

// "All trailing newlines cut, one added": what $(cat) + printf '%s\n' hand the judges.
function normalizeContent() {
  const N = gate("frontmatter.js").normalizeContent;
  const rows = [["a\n", "a\n"], ["a", "a\n"], ["a\n\n\n", "a\n"], ["", "\n"], ["\n\n", "\n"], ["a\r\n\r\n", "a\r\n\r\n"],
    ["a\nb\n", "a\nb\n"], ["a\n \n", "a\n \n"]];
  for (const [input, want] of rows) assert.strictEqual(N(input), want, `normalizeContent ${JSON.stringify(input)}`);
}

// withEntry(id, edit, fn) — the cached registry entry replaced by edit(copy) for fn's duration.
async function withEntry(id, edit, fn) {
  const reg = require(path.join(F.REPO, "hooks", "lib", "test-language-registry.js")).loadRegistry();
  const i = reg.entries.findIndex((e) => e.id === id);
  assert.ok(i >= 0, `registry entry ${id}`);
  const orig = reg.entries[i];
  reg.entries[i] = edit(JSON.parse(JSON.stringify(orig)));
  try {
    return await fn();
  } finally {
    reg.entries[i] = orig;
  }
}

// CASE_EMBED_DEPS_FAILED: no bash run yields it (the real parts never fail deps on a conforming
// file), so Node alone is pinned, through a caseEmbedRules part that cannot be reached.
async function depsFailed() {
  const missing = (e) => ({ ...e, caseEmbedRules: { file: "hooks/lib/test-gates/parts/no-such-embed.js", function: "bash_case_embed" } });
  const f = at("mk", "tests/bin/mk-ok.sh");
  await withEntry("bash", missing, async () => {
    assert.match(await gate("case-records.js").read(f.abs, f.rel), /^FILE\tuncertain\t[^\t\n]*\tcase-embed$/m, "crr: uncertain/case-embed");
    const got = await F.nodeRun({ id: "deps-failed", cli: "markers", tree: "mk", path: "full", args: [f.rel] });
    assert.strictEqual(got.rc, 0, "a WARN never fails the run");
    assert.match(got.stdout, /^WARN: tests\/bin\/mk-ok\.sh: case records incomplete \(caseEmbedRules deps failed\) code=CASE_EMBED_DEPS_FAILED$/m);
  });
}

module.exports = { headers, caseRecords, recordsUnavailable, selfImplWindow, selfImplUnavailable, codeLanguage, bashEmbed, normalizeContent, depsFailed, gate };
