"use strict";
// lang-check: ignore — CJK file names are probed on purpose.
// Snapshot and context part of tests/hooks/feature-2507-precommit-node.js (#2507): the HEAD-side
// batch read, the Git Bash (/c/...) path spelling, and the repo identity of D3. No case markers.
// createSnapshot({ repoTop, env }) -> { files(), mode(p), content(p), headContent(p), hasHead(),
// invalidate() }; buildContext({ cfgDir, repoTop, env, isTTY }) -> { cfgDir, repoTop, isAgentsRepo }.
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");

const str = (b) => (b === null || b === undefined ? b : Buffer.from(b).toString("utf8"));

function headBatchRead(F) {
  test("headContent: the HEAD blob for a tracked file, null for a file HEAD lacks", async () => {
    const dir = F.repo("snap-head");
    F.write(dir, "a.txt", "old\n");
    F.stage(dir, "a.txt");
    F.git(dir, ["commit", "-q", "-m", "a"]);
    F.write(dir, "a.txt", "new\n");
    F.write(dir, "b.txt", "added\n");
    F.stage(dir, "a.txt", "b.txt");
    const snap = await F.fresh("snapshot.js").createSnapshot({ repoTop: dir, env: F.cleanEnv() });
    assert.strictEqual(await snap.hasHead(), true);
    assert.deepStrictEqual((await snap.files()).slice().sort(), ["a.txt", "b.txt"]);
    assert.strictEqual(str(await snap.content("a.txt")), "new\n");
    assert.strictEqual(str(await snap.headContent("a.txt")), "old\n");
    assert.strictEqual(await snap.headContent("b.txt"), null);
  });
  test("initial commit: hasHead() is false and every headContent is null", async () => {
    const dir = F.repo("snap-unborn", { seed: false });
    F.write(dir, "first.txt", "one\n");
    F.stage(dir, "first.txt");
    const snap = await F.fresh("snapshot.js").createSnapshot({ repoTop: dir, env: F.cleanEnv() });
    assert.strictEqual(await snap.hasHead(), false);
    assert.deepStrictEqual(await snap.files(), ["first.txt"]);
    assert.strictEqual(await snap.headContent("first.txt"), null);
    assert.strictEqual(str(await snap.content("first.txt")), "one\n");
  });
  test("invalidate() re-reads the index", async () => {
    const dir = F.repo("snap-invalidate");
    F.write(dir, "x.txt", "x\n");
    F.write(dir, "y.txt", "y\n");
    F.stage(dir, "x.txt", "y.txt");
    const snap = await F.fresh("snapshot.js").createSnapshot({ repoTop: dir, env: F.cleanEnv() });
    assert.strictEqual((await snap.files()).length, 2);
    F.git(dir, ["reset", "-q", "HEAD", "--", "y.txt"]);
    await snap.invalidate();
    assert.deepStrictEqual(await snap.files(), ["x.txt"]);
  });
  test("a /c/... spelling of repoTop reads the same snapshot (toWindowsPath)", async () => {
    const dir = F.repo("snap-posix");
    F.write(dir, "p.txt", "p\n");
    F.stage(dir, "p.txt");
    const snap = await F.fresh("snapshot.js").createSnapshot({ repoTop: F.posixDrive(dir), env: F.cleanEnv() });
    assert.deepStrictEqual(await snap.files(), ["p.txt"]);
    assert.strictEqual(str(await snap.content("p.txt")), "p\n");
  });
  test("paths git quotes (space, non-ASCII, leading '-', and tab / '\"' off Windows) come back unquoted", async () => {
    const dir = F.repo("snap-quoted");
    // Windows forbids control characters and '"' in file names; the POSIX-only names are the
    // explicit exception, not a silent skip.
    const names = ["sp ace.txt", "日本語-ファイル.txt", "-dash.txt", "dir with space/über.txt"];
    if (process.platform !== "win32") names.push("tab\there.txt", "quo\"te.txt", "back\\slash.txt");
    names.forEach((n, i) => F.write(dir, n, `old ${i}\n`));
    F.stage(dir, ...names);
    F.git(dir, ["commit", "-q", "-m", "quoted"]);
    names.forEach((n, i) => F.write(dir, n, `new ${i}\n`));
    F.stage(dir, ...names);
    const snap = await F.fresh("snapshot.js").createSnapshot({ repoTop: dir, env: F.cleanEnv() });
    assert.deepStrictEqual((await snap.files()).slice().sort(), names.slice().sort());
    for (const [i, n] of names.entries()) {
      assert.strictEqual(str(await snap.content(n)), `new ${i}\n`, n);
      assert.strictEqual(str(await snap.headContent(n)), `old ${i}\n`, n);
      assert.strictEqual(String(await snap.mode(n)), "100644", n);
    }
  });
  test("many blobs in one batch map to their own paths (shared, empty, NUL-bearing, large)", async () => {
    const dir = F.repo("snap-multi");
    const big = Buffer.alloc(200000, 0x61);
    const nul = Buffer.from([0x6e, 0x0a, 0x00, 0x0a, 0x31, 0x32, 0x0a]);
    // zero.dat, not nul.dat: NUL is a reserved device name on Windows whatever the extension.
    const head = { "same-1.txt": "twin\n", "same-2.txt": "twin\n", "empty.txt": "e\n", "zero.dat": "h\n", "big.txt": "small\n" };
    for (const [n, b] of Object.entries(head)) F.write(dir, n, b);
    F.stage(dir, ...Object.keys(head));
    F.git(dir, ["commit", "-q", "-m", "multi"]);
    const staged = { "same-1.txt": "twin-new\n", "same-2.txt": "twin-new\n", "empty.txt": "", "zero.dat": nul, "big.txt": big, "a": "short\n", "a b": "longer\n" };
    for (const [n, b] of Object.entries(staged)) F.write(dir, n, b);
    F.stage(dir, ...Object.keys(staged));
    const snap = await F.fresh("snapshot.js").createSnapshot({ repoTop: dir, env: F.cleanEnv() });
    assert.deepStrictEqual((await snap.files()).slice().sort(), Object.keys(staged).sort());
    const read = async (p) => Buffer.from(await snap.content(p));
    assert.ok((await read("big.txt")).equals(big), "big.txt staged blob");
    assert.ok((await read("zero.dat")).equals(nul), "zero.dat staged blob keeps NUL and newlines");
    assert.strictEqual((await read("empty.txt")).length, 0, "an empty staged blob");
    assert.strictEqual(str(await snap.content("a")), "short\n");
    assert.strictEqual(str(await snap.content("a b")), "longer\n");
    // same-1 and same-2 share one blob on each side; each path still gets it.
    for (const n of ["same-1.txt", "same-2.txt"]) {
      assert.strictEqual(str(await snap.content(n)), "twin-new\n", n);
      assert.strictEqual(str(await snap.headContent(n)), "twin\n", n);
    }
    assert.strictEqual(str(await snap.headContent("empty.txt")), "e\n");
    assert.strictEqual(str(await snap.headContent("big.txt")), "small\n");
    assert.strictEqual(str(await snap.headContent("zero.dat")), "h\n");
    assert.strictEqual(await snap.headContent("a"), null);
    assert.strictEqual(await snap.headContent("a b"), null);
  });
}

// dropObject(dir, oid) — deletes the loose object, so cat-file answers "<oid> missing".
function dropObject(dir, oid) {
  const file = path.join(dir, ".git", "objects", oid.slice(0, 2), oid.slice(2));
  fs.chmodSync(file, 0o644);
  fs.unlinkSync(file);
}

// withCatFile(edit, fn) — runs fn with every `git cat-file` stdout passed through edit(buf, r);
// edit may also set r.status. limited-child-process calls child_process through the module
// object, so this patch reaches it.
async function withCatFile(edit, fn) {
  const cp = require("node:child_process");
  const real = cp.spawnSync;
  cp.spawnSync = function patched(command, args, ...rest) {
    const r = real.call(this, command, args, ...rest);
    if (Array.isArray(args) && args[0] === "cat-file" && r.stdout) r.stdout = edit(Buffer.from(r.stdout), r);
    return r;
  };
  try {
    return await fn();
  } finally {
    cp.spawnSync = real;
  }
}

function blobReadFailsClosed(F) {
  const staged = (name, files) => {
    const dir = F.repo(name);
    for (const [n, b] of Object.entries(files)) F.write(dir, n, b);
    F.stage(dir, ...Object.keys(files));
    return dir;
  };
  const oidOf = (dir, rel) => F.git(dir, ["rev-parse", `:${rel}`]);
  test("a staged blob absent from the object store makes content() throw, not return null", async () => {
    const dir = staged("snap-missing", { "gone.txt": "alpha beta\n" });
    dropObject(dir, oidOf(dir, "gone.txt"));
    const snap = await F.fresh("snapshot.js").createSnapshot({ repoTop: dir, env: F.cleanEnv() });
    await assert.rejects(async () => snap.content("gone.txt"), "content() of a missing object must fail closed");
  });
  test("a body shorter than the declared size makes content() throw", async () => {
    const dir = staged("snap-short-body", { "body.txt": "0123456789\n" });
    const snap = await F.fresh("snapshot.js").createSnapshot({ repoTop: dir, env: F.cleanEnv() });
    const cut = (buf) => buf.subarray(0, buf.indexOf(0x0a) + 5);
    await withCatFile(cut, () => assert.rejects(async () => snap.content("body.txt"), "a short body must fail closed"));
  });
  test("fewer headers than requested oids makes content() throw", async () => {
    const dir = staged("snap-short-batch", { "a1.txt": "first\n", "b2.txt": "second\n" });
    const snap = await F.fresh("snapshot.js").createSnapshot({ repoTop: dir, env: F.cleanEnv() });
    const firstOnly = (buf) => {
      const nl = buf.indexOf(0x0a);
      const size = Number(buf.subarray(0, nl).toString("utf8").split(" ")[2]);
      return buf.subarray(0, nl + 1 + size + 1);
    };
    await withCatFile(firstOnly, async () => {
      await assert.rejects(async () => snap.content("a1.txt"), "a batch cut after the first object must fail closed");
      await assert.rejects(async () => snap.content("b2.txt"), "an oid with no header must fail closed");
    });
  });
  test("a header with fewer than 3 fields makes content() throw", async () => {
    const dir = staged("snap-short-header", { "h.txt": "header\n" });
    const snap = await F.fresh("snapshot.js").createSnapshot({ repoTop: dir, env: F.cleanEnv() });
    const twoFields = (buf) => {
      const nl = buf.indexOf(0x0a);
      const [oid, type] = buf.subarray(0, nl).toString("utf8").split(" ");
      return Buffer.concat([Buffer.from(`${oid} ${type}`), buf.subarray(nl)]);
    };
    await withCatFile(twoFields, () => assert.rejects(async () => snap.content("h.txt"), "a malformed header must fail closed"));
  });
  // headContent() reads the HEAD side through the same loadBlobs()/readBlobs() path (CPR-ORTH).
  const modified = (name, rel, oldBody, newBody) => {
    const dir = F.repo(name);
    F.write(dir, rel, oldBody);
    F.stage(dir, rel);
    F.git(dir, ["commit", "-q", "-m", "head side"]);
    F.write(dir, rel, newBody);
    F.stage(dir, rel);
    return { dir, headOid: F.git(dir, ["rev-parse", `HEAD:${rel}`]) };
  };
  test("a HEAD-side blob absent from the object store makes headContent() throw, not return null", async () => {
    const { dir, headOid } = modified("snap-head-missing", "old.txt", "head alpha\n", "staged alpha\n");
    dropObject(dir, headOid);
    const snap = await F.fresh("snapshot.js").createSnapshot({ repoTop: dir, env: F.cleanEnv() });
    await assert.rejects(async () => snap.headContent("old.txt"), "headContent() of a missing object must fail closed");
  });
  test("a HEAD-side body shorter than the declared size makes headContent() throw", async () => {
    const { dir, headOid } = modified("snap-head-short", "old.txt", "0123456789\n", "staged\n");
    const snap = await F.fresh("snapshot.js").createSnapshot({ repoTop: dir, env: F.cleanEnv() });
    // Cut only the HEAD-side object's body; the staged-side object stays intact.
    const cutHead = (buf) => {
      const at = buf.indexOf(Buffer.from(`${headOid} blob `));
      if (at < 0) return buf;
      const nl = buf.indexOf(0x0a, at);
      const size = Number(buf.subarray(at, nl).toString("utf8").split(" ")[2]);
      return Buffer.concat([buf.subarray(0, nl + 5), buf.subarray(nl + 1 + size + 1)]);
    };
    await withCatFile(cutHead, () => assert.rejects(async () => snap.headContent("old.txt"), "a short HEAD-side body must fail closed"));
  });
  // The batch lists the staged oid first and the HEAD oid second (loadBlobs() insertion order).
  const firstObjectEnd = (buf) => {
    const nl = buf.indexOf(0x0a);
    return nl + 1 + Number(buf.subarray(0, nl).toString("utf8").split(" ")[2]) + 1;
  };
  test("a HEAD-side header with fewer than 3 fields makes headContent() throw", async () => {
    const { dir, headOid } = modified("snap-head-short-header", "old.txt", "head header\n", "staged header\n");
    const snap = await F.fresh("snapshot.js").createSnapshot({ repoTop: dir, env: F.cleanEnv() });
    const twoFieldsHead = (buf) => {
      const at = buf.indexOf(Buffer.from(`${headOid} blob `));
      if (at < 0) return buf;
      return Buffer.concat([buf.subarray(0, at), Buffer.from(`${headOid} blob`), buf.subarray(buf.indexOf(0x0a, at))]);
    };
    await withCatFile(twoFieldsHead, () => assert.rejects(async () => snap.headContent("old.txt"), "a malformed HEAD-side header must fail closed"));
  });
  test("a batch cut before the HEAD-side header makes headContent() throw", async () => {
    const { dir } = modified("snap-head-short-batch", "old.txt", "head batch\n", "staged batch\n");
    const snap = await F.fresh("snapshot.js").createSnapshot({ repoTop: dir, env: F.cleanEnv() });
    const stagedOnly = (buf) => buf.subarray(0, firstObjectEnd(buf));
    await withCatFile(stagedOnly, () => assert.rejects(async () => snap.headContent("old.txt"), "a HEAD oid with no header must fail closed"));
  });
  test("cat-file --batch exiting non-zero with partial stdout makes content() and headContent() throw", async () => {
    const { dir } = modified("snap-batch-nonzero", "old.txt", "head rc\n", "staged rc\n");
    const failed = (buf, r) => {
      r.status = 128;
      return buf.subarray(0, firstObjectEnd(buf));
    };
    for (const side of ["content", "headContent"]) {
      const snap = await F.fresh("snapshot.js").createSnapshot({ repoTop: dir, env: F.cleanEnv() });
      await withCatFile(failed, () => assert.rejects(async () => snap[side]("old.txt"), `${side}() after a non-zero cat-file must fail closed`));
    }
  });
  // One object per batch: the body has no trailing LF, so a size off by one lands on a body byte.
  test("malformed batch replies (size, type, oid, terminator) make content() throw", async () => {
    const dir = staged("snap-malformed", { "t.txt": "0123456789" });
    const parse = (buf) => {
      const nl = buf.indexOf(0x0a);
      const [oid, , size] = buf.subarray(0, nl).toString("utf8").split(" ");
      const n = Number(size);
      return { oid, n, body: buf.subarray(nl + 1, nl + 1 + n) };
    };
    const make = (header, body, end = "\n") => Buffer.concat([Buffer.from(`${header}\n`), body, Buffer.from(end)]);
    const rows = [
      ["negative size", (o) => make(`${o.oid} blob -1`, o.body)],
      ["non-numeric size", (o) => make(`${o.oid} blob ten`, o.body)],
      ["size one too large", (o) => make(`${o.oid} blob ${o.n + 1}`, o.body)],
      ["size one too small", (o) => make(`${o.oid} blob ${o.n - 1}`, o.body)],
      ["non-blob type", (o) => make(`${o.oid} tree ${o.n}`, o.body)],
      ["oid mismatch", (o) => make(`${"f".repeat(o.oid.length)} blob ${o.n}`, o.body)],
      ["no LF after the body", (o) => make(`${o.oid} blob ${o.n}`, o.body, "")],
    ];
    // Control: the same rebuild with nothing changed still reads the blob, so a RED row is the row.
    const control = await F.fresh("snapshot.js").createSnapshot({ repoTop: dir, env: F.cleanEnv() });
    const same = (buf) => { const o = parse(buf); return make(`${o.oid} blob ${o.n}`, o.body); };
    await withCatFile(same, async () => assert.strictEqual(str(await control.content("t.txt")), "0123456789"));
    const failures = [];
    for (const [label, edit] of rows) {
      const snap = await F.fresh("snapshot.js").createSnapshot({ repoTop: dir, env: F.cleanEnv() });
      await withCatFile((buf) => edit(parse(buf)), async () => {
        try {
          const got = await snap.content("t.txt");
          failures.push(`${label}: returned ${JSON.stringify(str(got))}`);
        } catch {
          // fail closed, as required
        }
      });
    }
    assert.deepStrictEqual(failures, [], "every malformed reply must fail closed");
  });
}

function missingBlobBlocksOutboundScan(F) {
  test("outbound-scan blocks the commit when a staged blob is missing (closed fail mode)", async () => {
    const dir = F.repo("scan-missing");
    F.write(dir, "plain.txt", "alpha beta gamma\n");
    F.stage(dir, "plain.txt");
    const opts = { repoTop: dir, cfgDir: F.REPO, env: F.cleanEnv() };
    const control = await F.runEntry("outbound-scan", opts);
    assert.strictEqual(control.value, 0, "control: the intact blob passes, so the lists load");
    dropObject(dir, F.git(dir, ["rev-parse", ":plain.txt"]));
    const got = await F.runEntry("outbound-scan", opts);
    const stderr = got.log.filter((l) => l.fd === 2).map((l) => l.text).join("");
    assert.strictEqual(got.value, 1, `a missing blob must block, got rc ${got.value}`);
    assert.ok(stderr.includes("outbound-scan failed"), `closed-mode diagnostic: ${JSON.stringify(stderr)}`);
  });
}

function repoIdentity(F) {
  const setup = () => {
    const cfg = F.repo("ident-cfg");
    const linked = path.join(F.tmp("ident-linked"), "wt");
    F.git(cfg, ["worktree", "add", "-q", "-b", "feature/ident", linked]);
    const foreign = F.repo("ident-foreign");
    return { cfg, linked, foreign };
  };
  const build = (opts) => F.fresh("context.js").buildContext({ isTTY: false, ...opts });
  test("the cfg repo and its linked worktree are the agents repo; a foreign repo is not", async () => {
    const { cfg, linked, foreign } = setup();
    const env = F.cleanEnv({ ENFORCE_WORKTREE: "off" });
    assert.strictEqual((await build({ cfgDir: cfg, repoTop: cfg, env })).isAgentsRepo, true);
    assert.strictEqual((await build({ cfgDir: cfg, repoTop: linked, env })).isAgentsRepo, true);
    assert.strictEqual((await build({ cfgDir: cfg, repoTop: foreign, env })).isAgentsRepo, false);
  });
  test("AGENTS_MAIN_ROOT, GIT_DIR, GIT_WORK_TREE and GIT_PREFIX do not change the identity", async () => {
    const { cfg, foreign } = setup();
    const toForeign = F.cleanEnv({ AGENTS_MAIN_ROOT: foreign, GIT_DIR: path.join(foreign, ".git"), GIT_WORK_TREE: foreign, GIT_PREFIX: "sub/" });
    assert.strictEqual((await build({ cfgDir: cfg, repoTop: cfg, env: toForeign })).isAgentsRepo, true);
    const toCfg = F.cleanEnv({ AGENTS_MAIN_ROOT: cfg, GIT_DIR: path.join(cfg, ".git"), GIT_WORK_TREE: cfg });
    assert.strictEqual((await build({ cfgDir: cfg, repoTop: foreign, env: toCfg })).isAgentsRepo, false);
  });
  test("a /c/... spelling of cfgDir and repoTop gives the same identity", async () => {
    const { cfg, foreign } = setup();
    const env = F.cleanEnv();
    assert.strictEqual((await build({ cfgDir: F.posixDrive(cfg), repoTop: F.posixDrive(cfg), env })).isAgentsRepo, true);
    assert.strictEqual((await build({ cfgDir: F.posixDrive(cfg), repoTop: foreign, env })).isAgentsRepo, false);
    assert.ok(fs.existsSync((await build({ cfgDir: F.posixDrive(cfg), repoTop: cfg, env })).cfgDir), "cfgDir is usable by fs");
  });
}

module.exports = { headBatchRead, blobReadFailsClosed, missingBlobBlocksOutboundScan, repoIdentity };
