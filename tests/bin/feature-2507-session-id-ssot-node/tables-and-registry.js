"use strict";
// Tests: bin/check-session-id-ssot.sh
// Tags: TL1, bin, session-id, fixture, test-lang-exception:symmetry, scope:issue-specific
// Path-table, whole-tree and registry-scope checks of tests/bin/feature-2507-session-id-ssot-node.js
// (#2507). Holds no case markers: the entrypoint calls each export inside its own case, with
// run = async (cwd, argv) -> { rc, stdout, stderr } for either the bash guard or the Node run().
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const F = require("./fixture");

const REAL_TABLES = () => fs.readFileSync(path.join(F.REPO, F.TABLE_REL), "utf8");
const READ = "const sid = process.env.SESSION_ID;";
const UNSET = "unset @S@ @E@";
const PREFIX = `check-session-id-ssot: ${F.TABLE_REL}: `;

// Rows added to each section are honoured; CRLF, comments, blank lines and padding are tolerated.
async function tablesAddRows(run) {
  const rows = [
    { path: "hooks/extra.js", lines: [READ], want: [] },
    { path: "lib/exempt.js", lines: ["const x = process.env.@S@;"], want: [] },
    { path: "bin/iso.sh", lines: [UNSET], want: [] },
    { path: "bin/iso-comment.sh", lines: ["# @S@"], want: [1] },
  ];
  const add = REAL_TABLES()
    .replace("[ALLOWLIST]", "[ALLOWLIST]\nhooks/extra.js")
    .replace("[TOMBSTONE_EXEMPT]", "[TOMBSTONE_EXEMPT]\nlib/exempt.js")
    .replace("[TOMBSTONE_ISOLATION_FILES_OUTSIDE_TESTS]", "[TOMBSTONE_ISOLATION_FILES_OUTSIDE_TESTS]\nbin/iso.sh\nbin/iso-comment.sh");
  const argv = ["--", ...rows.map((r) => r.path)];
  F.assertRun(await run(F.makeTree("add", rows, { tables: add }), argv), F.verdict(rows, "tomb"), "rows added (LF)");
  const crlf = `# padded and commented\r\n\r\n${add.split(/\r?\n/).map((l) => (l.startsWith("[") || l.startsWith("#") || l === "" ? l : `  ${l}\t`)).join("\r\n")}`;
  F.assertRun(await run(F.makeTree("crlf", rows, { tables: crlf }), argv), F.verdict(rows, "tomb"), "rows added (CRLF, padded)");
  // A row removed from ALLOWLIST is judged again.
  const bare = REAL_TABLES().replace(/^hooks\/workflow-state\/session-id\.js\s*$/m, "");
  const sid = [{ path: "hooks/workflow-state/session-id.js", lines: [READ], want: [1] }];
  F.assertRun(await run(F.makeTree("rm", sid, { tables: bare }), ["--", sid[0].path]), F.verdict(sid, "read"), "allowlist row removed");
}

// Broken table shapes exit 2 with the reason on stderr and judge nothing.
async function tablesBroken(run) {
  const real = REAL_TABLES();
  const shapes = [
    ["unknown section", `${real}\n[NOPE]\n`, `${PREFIX}unknown section [NOPE]`],
    ["entry before any section", `stray/entry.js\n${real}`, `${PREFIX}entry before any section: stray/entry.js`],
    ["section missing", real.replace("[TOMBSTONE_EXEMPT]", "# gone"), `${PREFIX}section [TOMBSTONE_EXEMPT] missing`],
  ];
  const rows = [{ path: "hooks/g.js", lines: [READ], want: [1] }];
  for (const [label, tables, line] of shapes) {
    const got = await run(F.makeTree("broken", rows, { tables }), ["--", "hooks/g.js"]);
    assert.strictEqual(got.rc, 2, `${label}: rc`);
    assert.ok(got.stderr.split(/\r?\n/).includes(line), `${label}: stderr ${JSON.stringify(got.stderr)}`);
    assert.strictEqual(got.stdout, "", `${label}: stdout`);
  }
  const dir = F.makeTree("dir", rows, { tables: null });
  fs.mkdirSync(path.join(dir, F.TABLE_REL), { recursive: true });
  const got = await run(dir, ["--", "hooks/g.js"]);
  assert.strictEqual(got.rc, 2, "tables path is a directory: rc");
  assert.ok(got.stderr.includes(`${PREFIX}not a regular file`), `directory: stderr ${JSON.stringify(got.stderr)}`);
}

// A tree without the tables is judged with the guard's own copy, and says so on stderr.
async function tablesFallback(run) {
  const rows = [
    { path: "hooks/workflow-state/session-id.js", lines: [READ], want: [] },
    { path: "hooks/g.js", lines: [READ], want: [1] },
  ];
  const got = await run(F.makeTree("fallback", rows, { tables: null }), ["--", ...rows.map((r) => r.path)]);
  F.assertRun(got, F.verdict(rows, "read"), "fallback tables");
  assert.ok(got.stderr.split(/\r?\n/).includes(`check-session-id-ssot: no ${F.TABLE_REL} under the current directory; judging with the guard's own tables`),
    `fallback notice: ${JSON.stringify(got.stderr)}`);
}

// No paths: the tracked tree (git ls-files); --staged narrows nothing; positional paths limit;
// -- ends the flags; an unknown flag exits 2.
async function wholeTree(run) {
  const clean = [{ path: "hooks/ok.js", lines: ["module.exports = 1;"], want: [] }];
  const root = F.makeTree("git", clean);
  require("../../lib/harness").gitInit(root);
  F.git(root, "add", "-A");
  F.assertRun(await run(root, []), { rc: 0, stdout: "" }, "clean tracked tree");
  const tracked = [
    { path: "hooks/bad.js", lines: [READ], want: [1] },
    { path: "lib/tomb.js", lines: ["const x = process.env.@S@;"], want: [1] },
  ];
  for (const r of tracked) F.writeFile(root, r.path, F.expand(r.lines[0]) + "\n");
  F.git(root, "add", "--", "hooks/bad.js", "lib/tomb.js");
  F.writeFile(root, "hooks/untracked.js", `${READ}\n`);
  const both = F.expected([tracked[1]], "tomb") + F.expected([tracked[0]], "read");
  F.assertRun(await run(root, []), { rc: 1, stdout: both }, "tracked files only");
  F.assertRun(await run(root, ["--staged"]), { rc: 1, stdout: both }, "--staged is the whole tracked tree");
  F.assertRun(await run(root, ["hooks/ok.js"]), { rc: 0, stdout: "" }, "positional path limits the scan");
  F.writeFile(root, "hooks/-dash.js", `${READ}\n`);
  const dash = [{ path: "hooks/-dash.js", lines: [READ], want: [1] }];
  F.assertRun(await run(root, ["--", "hooks/-dash.js"]), F.verdict(dash, "read"), "-- then a path");
  const bad = await run(root, ["--bogus"]);
  assert.strictEqual(bad.rc, 2, "unknown flag: rc");
  assert.ok(bad.stderr.includes("check-session-id-ssot: unknown flag: --bogus"), `unknown flag: ${JSON.stringify(bad.stderr)}`);
  assert.strictEqual(bad.stdout, "", "unknown flag: stdout");
}

// withEntry(id, edit, fn) — replaces the cached registry entry (the matcher WeakMap is keyed by the
// object) with edit(copy) for fn's duration. Node only: the bash guard reads the JSON on disk.
async function withEntry(id, edit, fn) {
  const reg = require(path.join(F.REPO, "hooks", "lib", "test-language-registry.js")).loadRegistry();
  const i = reg.entries.findIndex((e) => e.id === id);
  assert.ok(i >= 0, `registry entry ${id}`);
  const orig = reg.entries[i];
  reg.entries[i] = edit(JSON.parse(JSON.stringify(orig)));
  try {
    await fn();
  } finally {
    reg.entries[i] = orig;
  }
}

const ONE = (rel, line, want) => [{ path: rel, lines: [line], want }];
async function judge(run, rows, label) {
  F.assertRun(await run(F.makeTree("rs", rows), ["--", ...rows.map((r) => r.path)]), F.verdict(rows, "tomb"), label);
}

// RS3 / RS4: a clear-line part that cannot be reached fails closed (the line is reported).
async function partUnreachable(run) {
  await withEntry("bash", (e) => ({ ...e, envClearLine: { ...e.envClearLine, function: "env_clear_line_absent" } }),
    () => judge(run, ONE("tests/hooks/rs-unset.sh", UNSET, [1]), "RS3 function absent"));
  await withEntry("js", (e) => ({ ...e, envClearLine: { file: "hooks/lib/test-gates/parts/env-clear/no-such-part.js", function: "envClearLine" } }),
    () => judge(run, ONE("tests/hooks/rs-delete.js", "delete process.env.@S@;", [1]), "RS4 part file missing"));
  await judge(run, ONE("tests/hooks/rs-control.sh", UNSET, []), "control after restore");
}

// RS5 / RS6: the isolation file set follows the registry's patterns and helperLibrary.path.
async function registryScope(run) {
  const pop = 'os.environ.pop("@S@", None)';
  await withEntry("pytest", (e) => ({ ...e, patterns: ["check_*.py"] }), () => judge(run, [
    ...ONE("tests/hooks/check_rs.py", pop, []), ...ONE("tests/hooks/test_rs.py", pop, [1])], "RS5 pytest patterns"));
  const rm = "Remove-Item -Path Env:@S@ -ErrorAction SilentlyContinue";
  await withEntry("pester", (e) => ({ ...e, helperLibrary: { ...e.helperLibrary, path: "tests/lib/helper2.ps1" } }), () => judge(run, [
    ...ONE("tests/lib/helper2.ps1", rm, []), ...ONE("tests/lib/harness.ps1", rm, [1])], "RS6 pester helperLibrary.path"));
}

module.exports = { tablesAddRows, tablesBroken, tablesFallback, wholeTree, partUnreachable, registryScope };
