"use strict";
// Test-only scaffolding for the #2761 entrypoints (tests/hooks/feat-2761-*.js). Holds no cases.
// Puts a caller-made fixture repo (core.hooksPath already /dev/null) into an uncommitted merge
// state, locates MERGE_HEAD through `git rev-parse --git-path`, and computes the unsubtracted
// R-S digest independently of artifact.js (sha256(JSON.stringify(pairs))) as the expected value.

const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const { spawnSync } = require("node:child_process");

const IDENT = ["-c", "user.email=fixture@example.invalid", "-c", "user.name=fixture"];

function git(repo, args, allowFail) {
  const r = spawnSync("git", ["-C", repo].concat(args), { encoding: "utf8", timeout: 60000 });
  if (!allowFail && (r.error || r.status !== 0)) throw new Error(`git ${args.join(" ")} failed: ${r.stderr || r.error}`);
  return r;
}

function writeFile(repo, rel, body) {
  const abs = path.join(repo, ...rel.split("/"));
  fs.mkdirSync(path.dirname(abs), { recursive: true });
  fs.writeFileSync(abs, body);
}

// files: { rel: body | null } — null removes the path; every entry is staged.
function apply(repo, files) {
  for (const [rel, body] of Object.entries(files || {})) {
    if (body === null) {
      git(repo, ["rm", "-q", "-f", "--", rel]);
    } else {
      writeFile(repo, rel, body);
      git(repo, ["add", "--", rel]);
    }
  }
}

function commitAll(repo, files, message) {
  apply(repo, files);
  git(repo, IDENT.concat(["commit", "-q", "-m", message]));
}

function mergeHeadPathOf(repo) {
  const out = git(repo, ["rev-parse", "--git-path", "MERGE_HEAD"]).stdout.trim();
  return path.resolve(repo, out);
}

let counter = 0;
// spec = { upstream, upstream2?, branch?, resolve? }, each { rel: body | null }.
// → { mergeHead, mergeHeadPath, lines } with MERGE_HEAD present (else throws).
function startMerge(repo, spec) {
  const base = git(repo, ["rev-parse", "--abbrev-ref", "HEAD"]).stdout.trim();
  const ups = [];
  for (const side of [spec.upstream, spec.upstream2]) {
    if (!side) continue;
    counter += 1;
    const name = `fx-up-${process.pid}-${counter}`;
    git(repo, ["checkout", "-q", "-b", name]);
    commitAll(repo, side, `fixture: ${name}`);
    git(repo, ["checkout", "-q", base]);
    ups.push(name);
  }
  if (spec.branch) commitAll(repo, spec.branch, "fixture: branch side");
  const m = git(repo, IDENT.concat(["merge", "--no-commit", "--no-ff"], ups), true);
  if (m.error || (m.status !== 0 && m.status !== 1)) throw new Error(`git merge failed: ${m.stderr || m.error}`);
  apply(repo, spec.resolve);
  const mergeHeadPath = mergeHeadPathOf(repo);
  if (!fs.existsSync(mergeHeadPath)) throw new Error(`startMerge: no MERGE_HEAD after git merge (${m.stdout} ${m.stderr})`);
  const lines = fs.readFileSync(mergeHeadPath, "utf8").split(/\r?\n/).filter((l) => l.trim() !== "");
  return { mergeHead: lines[0], mergeHeadPath, lines };
}

const bodies = (word) => ({
  md: (title) => `# ${title}\n\nEach ${word} is checked.\n`,
  js: `"use strict";\n// each ${word} is checked\nmodule.exports = 1;\n`,
  sh: `#!/usr/bin/env bash\n# each ${word} is checked\nexit 0\n`,
});

// The standard scenario of the detail plan (Steps 1), with `word` as the drift word.
function standardSpec(word) {
  const b = bodies(word);
  return {
    upstream: {
      "docs/main-only.md": b.md("Main only"), "src/main-only.js": b.js, "tests/main-only.sh": b.sh,
      "docs/shared.md": "# Shared (main)\n\nPlain text.\n", "docs/old.md": null,
    },
    branch: { "docs/shared.md": "# Shared (branch)\n\nPlain text.\n" },
    resolve: { "docs/shared.md": `# Shared (resolved)\n\nPlain text.\n\nEach ${word} is checked.\n` },
  };
}

// The base commit (docs/shared.md without the word, docs/old.md, src/shared.js) and the merge.
// overrides replace whole sides of standardSpec. → startMerge's result
function standardMerge(repo, word, overrides) {
  commitAll(repo, {
    "docs/shared.md": "# Shared\n\nPlain text.\n", "docs/old.md": "# Old\n\nPlain text.\n",
    "src/shared.js": "\"use strict\";\nmodule.exports = 0;\n",
  }, "fixture: merge base");
  return startMerge(repo, Object.assign(standardSpec(word), overrides || {}));
}

// Two upstreams adding different files and no branch commit: an octopus merge without conflicts.
function octopusMerge(repo, word) {
  const b = bodies(word);
  return startMerge(repo, {
    upstream: { "docs/main-only.md": b.md("Main only") },
    upstream2: { "docs/main-two.md": "# Main two\n\nPlain text.\n" },
  });
}

// MERGE_HEAD rewritten to a well-formed oid of an object that does not exist.
const MISSING_OID = "1234567890abcdef1234567890abcdef12345678";
function corruptMergeHead(repo) {
  fs.writeFileSync(mergeHeadPathOf(repo), `${MISSING_OID}\n`);
}

// A branch named MERGE_HEAD (git versions that refuse the name get it through update-ref).
function makeMergeHeadBranch(repo) {
  const r = git(repo, ["branch", "MERGE_HEAD"], true);
  if (r.error || r.status !== 0) git(repo, ["update-ref", "refs/heads/MERGE_HEAD", "HEAD"]);
  return git(repo, ["rev-parse", "-q", "--verify", "MERGE_HEAD"], true).status === 0;
}

function stagedNames(repo) {
  return git(repo, ["diff", "--cached", "--name-only", "-z", "--no-renames"]).stdout.split("\0").filter(Boolean);
}

function stagedPairsDigest(repo, stage, classify) {
  const paths = stagedNames(repo).filter((p) => classify(p) === stage).sort();
  const oids = new Map();
  for (const rec of git(repo, ["ls-files", "-s", "-z"]).stdout.split("\0").filter(Boolean)) {
    const tab = rec.indexOf("\t");
    oids.set(rec.slice(tab + 1), rec.slice(0, tab).split(" ")[1]);
  }
  const pairs = paths.map((p) => [p, oids.get(p) || "deleted"]);
  return crypto.createHash("sha256").update(JSON.stringify(pairs)).digest("hex");
}

// C:/x/y -> /c/x/y (the Git Bash form); other paths unchanged.
const toPosixDrive = (p) => String(p).replace(/\\/g, "/").replace(/^([A-Za-z]):\//, (_, d) => `/${d.toLowerCase()}/`);

// Index and worktree apart. → { indexIsMergeHead, worktreeIsMergeHead } for rel, compared by blob oid.
function sidesOf(repo, rel) {
  const head = git(repo, ["rev-parse", `MERGE_HEAD:${rel}`]).stdout.trim();
  const index = git(repo, ["rev-parse", `:${rel}`]).stdout.trim();
  const work = git(repo, ["hash-object", "--", rel]).stdout.trim();
  return { indexIsMergeHead: index === head, worktreeIsMergeHead: work === head };
}

// Stages an edit of rel carrying `word`, then puts the MERGE_HEAD blob back in the worktree only.
function stagedEditWorktreeAtMergeHead(repo, rel, word) {
  apply(repo, { [rel]: `# Main only\n\nEach ${word} is checked, edited and staged in the merge.\n` });
  writeFile(repo, rel, git(repo, ["show", `MERGE_HEAD:${rel}`]).stdout);
  return sidesOf(repo, rel);
}

// Edits rel in the worktree only; the index keeps the MERGE_HEAD blob.
function worktreeOnlyEdit(repo, rel) {
  writeFile(repo, rel, "# Main only\n\nEdited in the worktree, never staged.\n");
  return sidesOf(repo, rel);
}

// Runs fn; an exception becomes one FAIL through check instead of ending the file.
function guarded(check, name, fn) {
  try {
    fn();
  } catch (e) {
    check(`${name} ran to the end`, false, (e && e.stack) || e);
  }
}

module.exports = {
  IDENT, MISSING_OID, git, writeFile, apply, commitAll, mergeHeadPathOf, startMerge, standardSpec,
  standardMerge, octopusMerge, corruptMergeHead, makeMergeHeadBranch, stagedNames, stagedPairsDigest, toPosixDrive,
  sidesOf, stagedEditWorktreeAtMergeHead, worktreeOnlyEdit, guarded,
};
