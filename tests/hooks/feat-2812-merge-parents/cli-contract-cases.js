"use strict";
// Tests: bin/merge-parents
// Tags: TL2, hooks, merge, merge-parents, merge-incoming, scope:issue-specific
// Private cases of tests/hooks/feat-2812-merge-parents.js: the bin/merge-parents record stream
// (header, two NUL records per path, "-" placeholders, tab / newline paths, exit 2), readMergeState,
// and the #2761 detectMergeIncoming contract that must survive the move to merge-state.js.
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const X = require("./fixture");

const { check, oid, show } = X;
const INCOMING = "hooks/lib/merge-incoming.js";
const STATE = "hooks/lib/merge-state.js";

// A blob stored with `name` in the index only (no worktree file), so tab / newline names work on
// every filesystem.
function stageName(repo, name, body) {
  const tmp = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "mp2812-blob-")), "b");
  fs.writeFileSync(tmp, body);
  const blob = X.git(repo, ["hash-object", "-w", "--", X.slash(tmp)]).stdout.trim();
  X.git(repo, ["update-index", "--add", "--cacheinfo", `100644,${blob},${name}`]);
  return blob;
}

function fieldsOf(parsed, rel) {
  const hit = parsed && parsed.records.find((r) => r.path === rel);
  return hit ? hit.fields.join("|") : "(no record)";
}

function detect(label, repo, paths) {
  const m = X.mod(label, INCOMING);
  return m ? m.detectMergeIncoming(repo, paths) : null;
}
const showSet = (r) => JSON.stringify(r, (k, v) => (v instanceof Set ? [...v].sort() : v));

// A merge whose MERGE_HEAD file is then replaced by `body` (a string) or by a directory (null).
function brokenMergeHead(tag, body) {
  const repo = X.mkRepo(tag, { "a.txt": "a\n" });
  X.M.startMerge(repo, { upstream: { "in.txt": "in\n" }, branch: { "a.txt": "a2\n" } });
  const file = X.M.mergeHeadPathOf(repo);
  if (body === null) {
    fs.rmSync(file);
    fs.mkdirSync(file);
  } else {
    fs.writeFileSync(file, body);
  }
  return repo;
}

// Case bodies by label; the entrypoint wraps each in its caseBegin/caseEnd markers.
const C = {};
C.cliFormat = () => {
  const repo = X.mkRepo("cli", { "f.txt": "f\n" });
  // Git for Windows refuses tab / newline index names under core.protectNTFS; no worktree file is made.
  X.git(repo, ["config", "core.protectNTFS", "false"]);
  const tabbed = "dir/a\tb.txt";
  const lined = "dir/n\nl.txt";
  const tabBlob = stageName(repo, tabbed, "tab\n");
  X.git(repo, X.M.IDENT.concat(["commit", "-q", "-m", "fixture: tab path"]));
  stageName(repo, lined, "newline\n");
  X.M.apply(repo, { "f.txt": "f edited\n" });
  const r = X.cli(["--repo", repo], [lined, tabbed, "f.txt"]);
  check("cli-format: exit 0", r.code === 0, `exit=${r.code} ${r.err}`);
  const p = X.parseCli(r.out);
  check("cli-format: stdout is a header plus two NUL records per path", !!p && p.records.length === 3, JSON.stringify(r.out));
  if (!p) return;
  check("cli-format: header is state<TAB>not-merging<TAB>-", p.header.join("|") === "state|not-merging|-", p.header.join("|"));
  check("cli-format: records follow the request order", p.records.map((x) => x.path).join("\0") === [lined, tabbed, "f.txt"].join("\0"), show(p.records.map((x) => x.path)));
  check("cli-format: newline path new -> 0 0 - - -", fieldsOf(p, lined) === "0|0|-|-|-", fieldsOf(p, lined));
  check("cli-format: tab path equal to HEAD -> 1 1 <H> - -", fieldsOf(p, tabbed) === `1|1|${tabBlob}|-|-`, fieldsOf(p, tabbed));
  check("cli-format: edited path -> 1 0 <H> - -", fieldsOf(p, "f.txt") === `1|0|${oid(repo, "HEAD:f.txt")}|-|-`, fieldsOf(p, "f.txt"));
};

C.cliMerge = () => {
  const fx = X.allRules("cli-merge");
  const r = X.cli(["--repo", fx.repo], ["r6.txt", "r4.txt"]);
  const p = X.parseCli(r.out);
  check("cli-merge: exit 0", r.code === 0, `exit=${r.code} ${r.err}`);
  check("cli-merge: header is state<TAB>merging<TAB>-", !!p && p.header.join("|") === "state|merging|-", JSON.stringify(r.out.slice(0, 80)));
  const mb = X.mergeBase(fx.repo)[0];
  check("cli-merge: r6.txt -> 1 0 <H> <M> <B>", fieldsOf(p, "r6.txt") === `1|0|${oid(fx.repo, "HEAD:r6.txt")}|${oid(fx.repo, "MERGE_HEAD:r6.txt")}|${oid(fx.repo, `${mb}:r6.txt`)}`, fieldsOf(p, "r6.txt"));
  check("cli-merge: r4.txt -> 1 0 <M> - -", fieldsOf(p, "r4.txt") === `1|0|${oid(fx.repo, "MERGE_HEAD:r4.txt")}|-|-`, fieldsOf(p, "r4.txt"));
  const oct = X.mkRepo("cli-oct");
  X.M.octopusMerge(oct, "word");
  const o = X.cli(["--repo", oct], ["docs/main-only.md"]);
  const op = X.parseCli(o.out);
  check("cli-merge octopus: exit 0 (undecidable still resolves)", o.code === 0, `exit=${o.code} ${o.err}`);
  check("cli-merge octopus: header is state<TAB>undecidable<TAB>octopus", !!op && op.header.join("|") === "state|undecidable|octopus", JSON.stringify(o.out.slice(0, 80)));
  check("cli-merge octopus: incoming path -> 0 0 - - -", fieldsOf(op, "docs/main-only.md") === "0|0|-|-|-", fieldsOf(op, "docs/main-only.md"));
  const idx = X.mkRepo("cli-idx", { "f.txt": "f\n" });
  const alt = X.slash(path.join(fs.mkdtempSync(path.join(os.tmpdir(), "mp2812-cidx-")), "alt"));
  fs.copyFileSync(path.join(idx, ".git", "index"), alt);
  X.M.apply(idx, { "f.txt": "f edited\n" });
  const a = X.parseCli(X.cli(["--repo", idx], ["f.txt"], { GIT_INDEX_FILE: alt }).out);
  check("cli-merge: GIT_INDEX_FILE inherited by the CLI (alternate index equals HEAD)", fieldsOf(a, "f.txt") === `1|1|${oid(idx, "HEAD:f.txt")}|-|-`, fieldsOf(a, "f.txt"));
};

C.cliExit2 = () => {
  const repo = X.mkRepo("cli-x");
  const u = X.cli(["--repo", repo, "--bogus"], ["README.md"]);
  check("cli-exit2: unknown option exits 2", u.code === 2, `exit=${u.code} ${u.err}`);
  const m = X.cli(["--repo"], ["README.md"]);
  check("cli-exit2: --repo without a value exits 2", m.code === 2, `exit=${m.code} ${m.err}`);
  const notRepo = X.slash(fs.mkdtempSync(path.join(os.tmpdir(), "mp2812-cli-norepo-")));
  const n = X.cli(["--repo", notRepo], ["a.txt"]);
  check("cli-exit2: a directory outside any repo exits 2", n.code === 2, `exit=${n.code} ${n.err}`);
  const ok = X.cli(["--repo", repo], ["README.md"]);
  check("cli-exit2 control: the same CLI exits 0 on a real repo", ok.code === 0, `exit=${ok.code} ${ok.err}`);
};

C.mergeState = () => {
  const m = X.mod("merge-state", STATE);
  if (!m) return;
  const s = m.MERGE_STATE;
  check("merge-state: MERGE_STATE holds the three states, frozen",
    !!s && s.NOT_MERGING === "not-merging" && s.MERGING === "merging" && s.UNDECIDABLE === "undecidable" && Object.isFrozen(s), show(s));
  check("merge-state: runGit is exported", typeof m.runGit === "function", typeof m.runGit);
  const plain = X.mkRepo("ms-plain");
  check("merge-state: plain repo is not-merging", show(m.readMergeState(plain)) === '{"state":"not-merging"}', show(m.readMergeState(plain)));
  const fx = X.allRules("ms-merge");
  const r = m.readMergeState(fx.repo);
  check("merge-state: merge gives merging with the MERGE_HEAD oid", !!r && r.state === "merging" && r.mergeHead === fx.mergeHead, show(r));
  const oct = X.mkRepo("ms-oct");
  X.M.octopusMerge(oct, "word");
  const o = m.readMergeState(oct);
  check("merge-state: real octopus merge -> undecidable / octopus", !!o && o.state === "undecidable" && o.reason === "octopus", show(o));
  // MERGE_HEAD file body -> readMergeState (OID_RE plus line splitting). `input` null makes the
  // MERGE_HEAD path a directory; `want` is "merging:<mergeHead>" or "undecidable:<reason>".
  const h40 = "0123456789abcdef0123456789abcdef01234567";
  const h64 = `${h40}0123456789abcdef01234567`;
  const cases = [
    { name: "40-hex lowercase", input: `${h40}\n`, want: `merging:${h40}` },
    { name: "64-hex (sha256)", input: `${h64}\n`, want: `merging:${h64}` },
    { name: "40-hex uppercase (case-insensitive)", input: `${h40.toUpperCase()}\n`, want: `merging:${h40.toUpperCase()}` },
    { name: "40-hex with CRLF", input: `${h40}\r\n`, want: `merging:${h40}` },
    { name: "40-hex with surrounding blanks", input: `  ${h40}  \n`, want: `merging:${h40}` },
    { name: "40-hex without a newline", input: h40, want: `merging:${h40}` },
    { name: "39-hex", input: `${h40.slice(1)}\n`, want: "undecidable:merge-head-malformed" },
    { name: "41-hex", input: `${h40}a\n`, want: "undecidable:merge-head-malformed" },
    { name: "63-hex", input: `${h64.slice(1)}\n`, want: "undecidable:merge-head-malformed" },
    { name: "65-hex", input: `${h64}a\n`, want: "undecidable:merge-head-malformed" },
    { name: "40 chars with a non-hex g", input: `${h40.slice(1)}g\n`, want: "undecidable:merge-head-malformed" },
    { name: "40-hex with an inner blank", input: `${h40.slice(0, 20)} ${h40.slice(21)}\n`, want: "undecidable:merge-head-malformed" },
    { name: "not an oid", input: "not-an-oid\n", want: "undecidable:merge-head-malformed" },
    { name: "empty line", input: "\n", want: "undecidable:merge-head-malformed" },
    { name: "empty file", input: "", want: "undecidable:merge-head-malformed" },
    { name: "two oids (octopus)", input: `${h40}\n${h64}\n`, want: "undecidable:octopus" },
    { name: "oid plus a blank line", input: `${h40}\n\n`, want: `merging:${h40}` },
    { name: "directory (unreadable)", input: null, want: "undecidable:merge-head-unreadable" },
  ];
  const tableRepo = brokenMergeHead("ms-table", `${h40}\n`);
  const mhFile = X.M.mergeHeadPathOf(tableRepo);
  for (const { name, input, want } of cases) {
    fs.rmSync(mhFile, { recursive: true, force: true });
    if (input === null) fs.mkdirSync(mhFile);
    else fs.writeFileSync(mhFile, input);
    const got = m.readMergeState(tableRepo);
    const gotKey = !got ? "(null)" : got.state === "merging" ? `merging:${got.mergeHead}` : `${got.state}:${got.reason}`;
    check(`merge-state table: ${name} -> ${want}`, gotKey === want, `got ${show(got)}`);
  }
  const notRepo = X.slash(fs.mkdtempSync(path.join(os.tmpdir(), "mp2812-ms-norepo-")));
  const g = m.readMergeState(notRepo);
  check("merge-state: outside a repo -> undecidable / git-path-failed", !!g && g.state === "undecidable" && g.reason === "git-path-failed", show(g));
};

C.contractReasons = () => {
  const oct = X.mkRepo("c-oct");
  X.M.octopusMerge(oct, "word");
  const inv = detect("contract-reasons", oct, "not-an-array");
  check("contract-reasons: invalid-argument is checked before MERGE_HEAD (octopus repo)", !!inv && inv.state === "undecidable" && inv.reason === "invalid-argument", showSet(inv));
  const empty = detect("contract-reasons", "", []);
  check("contract-reasons: empty repoDir -> invalid-argument", !!empty && empty.reason === "invalid-argument", showSet(empty));
  const notRepo = X.slash(fs.mkdtempSync(path.join(os.tmpdir(), "mp2812-c-norepo-")));
  for (const [label, repo, reason] of [["octopus", oct, "octopus"], ["malformed", brokenMergeHead("c-mal", "not-an-oid\n"), "merge-head-malformed"],
    ["unreadable", brokenMergeHead("c-dir", null), "merge-head-unreadable"], ["outside a repo", notRepo, "git-path-failed"]]) {
    const got = detect("contract-reasons", repo, []);
    check(`contract-reasons: ${label} -> undecidable / ${reason}`, !!got && got.state === "undecidable" && got.reason === reason, showSet(got));
  }
  const plain = X.mkRepo("c-plain");
  const np = detect("contract-reasons", plain, ["README.md"]);
  check("contract-reasons: plain repo -> not-merging", !!np && showSet(np) === '{"state":"not-merging"}', showSet(np));
};

C.contractPaths = () => {
  const repo = X.mkRepo("c-paths", { "a.txt": "a\n" });
  const fx = X.M.startMerge(repo, { upstream: { "in.txt": "in\n", "mode.sh": "#!/bin/sh\n", "ed.txt": "ed\n" }, branch: { "a.txt": "a2\n" } });
  X.git(repo, ["update-index", "--chmod=+x", "--", "mode.sh"]);
  X.M.apply(repo, { "ed.txt": "ed edited\n" });
  const r = detect("contract-paths", repo, ["in.txt", "mode.sh", "ed.txt", "a.txt"]);
  check("contract-paths: merging with the MERGE_HEAD oid", !!r && r.state === "merging" && r.mergeHead === fx.mergeHead, showSet(r));
  check("contract-paths: only the blob-and-mode match in.txt is incoming", !!r && r.paths instanceof Set && [...r.paths].sort().join(",") === "in.txt", showSet(r));
};

C.contractIdentity = () => {
  const inc = X.mod("contract-identity", INCOMING);
  const st = X.mod("contract-identity", STATE);
  if (inc && st) check("contract-identity: same object re-exported", inc.MERGE_INCOMING_STATE === st.MERGE_STATE, "different objects");
};

module.exports = C;
