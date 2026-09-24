"use strict";
// bin/worker-dispatch/workers/worktree-backup.js
//
// Stage 2 worker (replaces agents/worktree-backup-worker.md): copies gitignored
// and untracked worktree state through fsguard, so there is no command line for a
// write hook to parse. backup_dir is derived (<main-root>/.worktree-backup/<branch>),
// never accepted from the caller — see bin/worker-dispatch/capability.js.

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const { run: spawnRun } = require("../spawn");

const GIT_TIMEOUT_MS = 120000;
const DOCKER_TIMEOUT_MS = 30000;

const parseCap = (v, def) => { const n = Number(v); return Number.isFinite(n) && n > 0 ? n : def; };
const MAX_BACKUP_FILES    = parseCap(process.env.WORKTREE_BACKUP_MAX_FILES,     2000);
const MAX_BACKUP_BYTES    = parseCap(process.env.WORKTREE_BACKUP_MAX_BYTES,     50 * 1024 * 1024);
const MAX_ENUMERATE_FILES = parseCap(process.env.WORKTREE_BACKUP_MAX_ENUMERATE, 20000);

function stamp() {
  return new Date().toISOString().replace(/[:.]/g, "-");
}

function splitNul(text) {
  return String(text || "")
    .split("\0")
    .filter((s) => s !== "");
}

function firstLine(text) {
  return (String(text || "").split("\n").find((l) => l.trim() !== "") || "").trim();
}

function humanSize(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function git(ctx, worktreePath, args) {
  const res = spawnRun(ctx.entry, {
    anchors: ctx.anchors,
    command: "git",
    args,
    cwd: worktreePath,
    timeoutMs: GIT_TIMEOUT_MS,
  });
  if (res.timedOut) return { error: `git ${args[0]} exceeded its budget` };
  if (res.spawnError !== null) return { error: `git could not run: ${res.spawnError}` };
  if (res.status !== 0) return { error: firstLine(res.stderr) || `git ${args[0]} exited ${res.status}` };
  return { stdout: res.stdout };
}

// Preservation candidates are everything git does not track: ignored files
// (build state, .env-adjacent local config) plus plain untracked files. The two
// lists are disjoint by construction, but they are unioned rather than
// concatenated so a future git flag change cannot silently double-count.
function inventory(ctx, worktreePath, dirExpand) {
  // --directory makes git return directory names instead of their contents for
  // untracked/ignored directories. This is needed for dir_expand so that
  // expandDir() is called on the directory entry. Without it, git returns
  // individual files inside plain (non-opaque) ignored directories, bypassing
  // expandDir entirely. The flag is omitted when dir_expand is off to preserve
  // the original behavior: files inside plain ignored dirs are copied individually.
  const dirFlag = dirExpand === true ? ["--directory"] : [];
  const ignored = git(ctx, worktreePath, ["ls-files", "--others", "--ignored", ...dirFlag, "--exclude-standard", "-z"]);
  if (ignored.error) return { error: ignored.error };
  const untracked = git(ctx, worktreePath, ["ls-files", "--others", ...dirFlag, "--exclude-standard", "-z"]);
  if (untracked.error) return { error: untracked.error };
  const modified = git(ctx, worktreePath, ["status", "--porcelain=v1", "-z"]);
  if (modified.error) return { error: modified.error };

  const seen = new Set();
  const candidates = [];
  for (const raw of splitNul(ignored.stdout).concat(splitNul(untracked.stdout))) {
    const rel = raw.endsWith("/") ? raw.slice(0, -1) : raw;
    if (seen.has(rel)) continue;
    seen.add(rel);
    candidates.push(rel);
  }
  candidates.sort();

  const expansionIssues = [];
  if (dirExpand === true) {
    const enumBudget = { remaining: MAX_ENUMERATE_FILES };
    let enumerationTruncated = false;
    const expanded = [];
    for (const rel of candidates) {
      let st = null;
      try { st = fs.lstatSync(path.join(worktreePath, rel)); } catch (_e) { expanded.push(rel); continue; }
      if (st.isDirectory() && !st.isSymbolicLink()) {
        const result = expandDir(worktreePath, rel, enumBudget);
        for (const f of result.files) expanded.push(f);
        for (const issue of result.irregularIssues) expansionIssues.push(issue);
        if (result.truncated && !enumerationTruncated) {
          enumerationTruncated = true;
          expansionIssues.push(
            `enumeration budget reached (${MAX_ENUMERATE_FILES} entries across all expanded gitignored directories); remaining directory contents may be lost on worktree deletion`
          );
        }
      } else {
        expanded.push(rel);
      }
    }
    // Dedup (parent dir + child may both be in candidates from git ls-files)
    const seen2 = new Set();
    for (const rel of expanded) {
      if (!seen2.has(rel)) { seen2.add(rel); }
    }
    candidates.length = 0;
    for (const rel of seen2) candidates.push(rel);
    candidates.sort();
  }

  return {
    candidates,
    expansionIssues,
    ignoredCount: splitNul(ignored.stdout).length,
    untrackedCount: splitNul(untracked.stdout).length,
    dirtyCount: splitNul(modified.stdout).length,
  };
}

// Every spelling of the same directory a container mount could carry: the
// Windows form, the same with forward slashes, the MSYS form and the WSL form.
// A bind mount is reported when any of them appears in the container record.
function pathNeedles(worktreePath) {
  const win = worktreePath.replace(/\//g, "\\");
  const fwd = worktreePath.replace(/\\/g, "/");
  const needles = [win.toLowerCase(), fwd.toLowerCase()];
  const drive = /^([A-Za-z]):[\\/](.*)$/.exec(fwd);
  if (drive) {
    const rest = drive[2].replace(/\\/g, "/");
    needles.push(`/${drive[1].toLowerCase()}/${rest}`.toLowerCase());
    needles.push(`/mnt/${drive[1].toLowerCase()}/${rest}`.toLowerCase());
  }
  return needles.filter((n) => n !== "");
}

// Best effort by contract: docker not installed, not running, or a daemon that
// refuses the query all mean "no impact information", never a failed backup.
function dockerImpact(ctx, worktreePath, cwd) {
  let res = null;
  try {
    res = spawnRun(ctx.entry, {
      anchors: ctx.anchors,
      command: "docker",
      args: ["ps", "-a", "--format", "json"],
      cwd,
      timeoutMs: DOCKER_TIMEOUT_MS,
    });
  } catch (_e) {
    return { checked: false, containers: [] };
  }
  if (res.timedOut || res.spawnError !== null || res.status !== 0) {
    return { checked: false, containers: [] };
  }

  const needles = pathNeedles(worktreePath);
  const containers = [];
  for (const line of String(res.stdout || "").split("\n")) {
    const trimmed = line.trim();
    if (trimmed === "") continue;
    const hay = trimmed.toLowerCase();
    if (!needles.some((n) => hay.includes(n))) continue;
    let obj = null;
    try {
      obj = JSON.parse(trimmed);
    } catch (_e) {
      obj = null;
    }
    const state = obj && typeof obj.State === "string" ? obj.State : "unknown";
    containers.push({
      name: obj && typeof obj.Names === "string" ? obj.Names : "(unnamed)",
      state,
      status: obj && typeof obj.Status === "string" ? obj.Status : "",
      running: state === "running",
    });
  }
  return { checked: true, containers };
}

// Expand one gitignored directory into its constituent file/symlink rel paths.
// Forward-slash concatenation keeps rel paths normalized regardless of OS. The
// shared enumeration budget caps total entries across all expanded directories.
function expandDir(worktreePath, relDir, enumBudget) {
  const files = [];
  const irregularIssues = [];
  let truncated = false;

  function walk(rel) {
    if (truncated) return;
    let entries;
    try {
      entries = fs.readdirSync(path.join(worktreePath, rel), { withFileTypes: true });
    } catch (_e) {
      return;
    }
    for (const dirent of entries) {
      if (truncated) break;
      const childRel = rel + "/" + dirent.name;
      if (dirent.isSymbolicLink()) {
        if (enumBudget.remaining <= 0) { truncated = true; break; }
        enumBudget.remaining -= 1;
        files.push(childRel);
      } else if (dirent.isDirectory()) {
        walk(childRel);
      } else if (dirent.isFile()) {
        if (enumBudget.remaining <= 0) { truncated = true; break; }
        enumBudget.remaining -= 1;
        files.push(childRel);
      } else {
        irregularIssues.push(
          `${childRel}: non-regular file skipped (not a regular file, directory, or symlink) — contents not preserved`
        );
      }
    }
  }

  walk(relDir);
  return { files, truncated, irregularIssues };
}

// A candidate is measured, not read, in dry-run mode. Symlinks are resolved so
// that one pointing outside the worktree can be dropped before it is ever
// followed — copying through it would pull in state the worktree does not own.
function describe(worktreePath, rel) {
  const abs = path.join(worktreePath, rel);
  let st = null;
  try {
    st = fs.lstatSync(abs);
  } catch (e) {
    return { rel, skip: `unreadable: ${e && e.code ? e.code : "error"}` };
  }
  if (st.isSymbolicLink()) {
    let target = null;
    try {
      target = fs.realpathSync(abs);
    } catch (_e) {
      return { rel, skip: "symlink with an unresolvable target" };
    }
    const root = fs.existsSync(worktreePath) ? fs.realpathSync(worktreePath) : worktreePath;
    const rooted = root.endsWith(path.sep) ? root : root + path.sep;
    if (!target.toLowerCase().startsWith(rooted.toLowerCase())) {
      return { rel, skip: "symlink pointing outside the worktree" };
    }
    try {
      st = fs.statSync(abs);
    } catch (e) {
      return { rel, skip: `unreadable: ${e && e.code ? e.code : "error"}` };
    }
  }
  if (st.isDirectory()) return { rel, skip: "directory" };
  return { rel, abs, size: st.size, mtime: st.mtime.toISOString() };
}

// Bound the read set by file count and total bytes. Applied only when dir_expand
// is on, since expansion is the only path that can grow the set past the budget.
function applyReadBudget(describedFiles) {
  const kept = [];
  const budgetIssues = [];
  let files = 0;
  let bytes = 0;
  for (const f of describedFiles) {
    if (files + 1 > MAX_BACKUP_FILES || bytes + f.size > MAX_BACKUP_BYTES) {
      const remaining = describedFiles.length - kept.length;
      budgetIssues.push(
        `budget cap reached (${MAX_BACKUP_FILES} files / ${humanSize(MAX_BACKUP_BYTES)}); ${remaining} candidate file(s) NOT preserved — contents may be lost on worktree deletion`
      );
      break;
    }
    kept.push(f);
    files += 1;
    bytes += f.size;
  }
  return { kept, budgetIssues };
}

function dryRun(payload, ctx, inv) {
  const { fsguard, anchors } = ctx;
  const worktreePath = payload.worktree_path;
  const artifactDir = payload.artifact_dir || anchors.plansDir;

  const described = inv.candidates.map((rel) => describe(worktreePath, rel));
  const files = described.filter((d) => d.skip === undefined);
  const skipped = described.filter((d) => d.skip !== undefined);
  let actualFiles = files;
  let budgetIssues = [];
  if (payload.dir_expand === true) {
    const budget = applyReadBudget(files);
    actualFiles = budget.kept;
    budgetIssues = budget.budgetIssues;
  }
  const total = actualFiles.reduce((sum, f) => sum + f.size, 0);
  const docker = payload.docker_check === false
    ? { checked: false, containers: [] }
    : dockerImpact(ctx, worktreePath, worktreePath);
  const stopped = docker.containers.filter((c) => !c.running);

  let written = null;
  try {
    written = fsguard.writeFile(
      path.join(artifactDir, `${stamp()}-backup-worker-dry-run.txt`),
      [
        `DRY RUN — ${worktreePath} (${payload.branch})`,
        `destination: ${payload.backup_dir}`,
        `candidates: ${actualFiles.length} files, ${humanSize(total)}`,
        `  ignored: ${inv.ignoredCount}  untracked: ${inv.untrackedCount}  dirty tracked: ${inv.dirtyCount}`,
        `skipped: ${skipped.length}`,
        `docker: ${docker.checked ? `${docker.containers.length} container(s) bind-mount this worktree, ${stopped.length} stopped` : "not checked"}`,
        "",
        ...actualFiles.map((f) => `  ${f.rel} (${humanSize(f.size)})`),
        ...skipped.map((s) => `  [skip] ${s.rel} — ${s.skip}`),
        ...inv.expansionIssues.map((i) => `  [dir] ${i}`),
        ...budgetIssues.map((b) => `  [budget] ${b}`),
        ...docker.containers.map((c) => `  [docker] ${c.name} — ${c.status || c.state}`),
        "",
      ].join("\n")
    );
  } catch (e) {
    return {
      status: "failed",
      summary: `dry-run log write failed: ${e && e.message ? e.message : "unknown error"}`,
      artifactPath: "(none)",
    };
  }

  const allIssues = inv.expansionIssues.length + budgetIssues.length;
  return {
    status: "dry_run_complete",
    summary:
      `${actualFiles.length} files / ${humanSize(total)} to ${payload.backup_dir}` +
      (docker.containers.length === 0 ? "" : `; ${docker.containers.length} docker bind-mount(s)`) +
      (allIssues === 0 ? "" : `; ${allIssues} directory/file(s) NOT fully preserved`),
    artifactPath: written,
  };
}

function execute(payload, ctx, inv) {
  const { fsguard, anchors } = ctx;
  const worktreePath = payload.worktree_path;
  const backupDir = payload.backup_dir;
  const artifactDir = payload.artifact_dir || anchors.plansDir;

  const described = inv.candidates.map((rel) => describe(worktreePath, rel));
  const pending = described.filter((d) => d.skip === undefined);
  let actualPending = pending;
  let budgetIssues = [];
  if (payload.dir_expand === true) {
    const budget = applyReadBudget(pending);
    actualPending = budget.kept;
    budgetIssues = budget.budgetIssues;
  }
  const notes = described
    .filter((d) => d.skip !== undefined)
    .map((d) => `${d.rel}: ${d.skip}`)
    .concat(inv.expansionIssues)
    .concat(budgetIssues);

  if (actualPending.length === 0 && notes.length === 0) {
    return {
      status: "skipped",
      summary: "no gitignored or untracked files to back up",
      artifactPath: "(none)",
    };
  }

  const manifestFiles = [];
  let copiedBytes = 0;
  for (const f of actualPending) {
    try {
      const data = fs.readFileSync(f.abs);
      fsguard.writeFile(path.join(backupDir, f.rel), data);
      manifestFiles.push({
        path: f.rel.split(path.sep).join("/"),
        size_bytes: f.size,
        mtime_iso: f.mtime,
        // Content is hashed, never embedded: a manifest that quoted the bytes of
        // a local .env would turn the backup index itself into a secret.
        sha256: crypto.createHash("sha256").update(data).digest("hex"),
      });
      copiedBytes += f.size;
    } catch (e) {
      notes.push(`${f.rel}: copy failed — ${e && e.message ? e.message : "unknown error"}`);
    }
  }

  const docker = payload.docker_check === false
    ? { checked: false, containers: [] }
    : dockerImpact(ctx, worktreePath, worktreePath);

  let manifestPath = null;
  try {
    manifestPath = fsguard.writeFile(
      path.join(backupDir, "manifest.json"),
      `${JSON.stringify(
        {
          generated_at: new Date().toISOString(),
          worktree_path: worktreePath,
          branch: payload.branch,
          backup_dir: backupDir,
          file_count: manifestFiles.length,
          total_size_bytes: copiedBytes,
          files: manifestFiles,
          docker_impact: {
            checked: docker.checked,
            containers: docker.containers,
            stopped_count: docker.containers.filter((c) => !c.running).length,
          },
          issues: notes,
        },
        null,
        2
      )}\n`
    );
  } catch (e) {
    return {
      status: "failed",
      summary: `manifest write failed: ${e && e.message ? e.message : "unknown error"}`,
      artifactPath: "(none)",
    };
  }

  // The execute log is best-effort: the manifest is the artifact the caller
  // needs, and losing the log must not downgrade a completed backup.
  try {
    fsguard.writeFile(
      path.join(artifactDir, `${stamp()}-backup-worker-execute.log`),
      [
        `worktree: ${worktreePath}`,
        `branch: ${payload.branch}`,
        `backup-dir: ${backupDir}`,
        `copied: ${manifestFiles.length} / ${actualPending.length} candidates (${humanSize(copiedBytes)})`,
        `manifest: ${manifestPath}`,
        `docker: ${docker.checked ? `${docker.containers.length} bind-mount(s)` : "not checked"}`,
        ...notes.map((n) => `  ${n}`),
        "",
      ].join("\n")
    );
  } catch (_e) {
    /* keep the reported status; the manifest already carries `issues` */
  }

  const failedCopies = actualPending.length - manifestFiles.length;
  const notPreservedCount = inv.expansionIssues.length + budgetIssues.length;
  const dirExpandWarning = payload.dir_expand === true && notPreservedCount > 0
    ? `; WARNING: ${notPreservedCount} path(s) NOT preserved — their contents will be LOST when the worktree is deleted`
    : (notes.length === 0 ? "" : `; ${notes.length} issue(s) — see the manifest`);
  return {
    status: failedCopies === 0 && notes.length === 0 ? "copied" : "partial",
    summary:
      `${manifestFiles.length} files / ${humanSize(copiedBytes)} to ${backupDir}` +
      (docker.containers.length === 0 ? "" : `; ${docker.containers.length} docker bind-mount(s)`) +
      dirExpandWarning,
    artifactPath: manifestPath,
  };
}

function run(payload, ctx) {
  const inv = inventory(ctx, payload.worktree_path, payload.dir_expand === true);
  if (inv.error !== undefined) {
    return { status: "failed", summary: `inventory failed: ${inv.error}`, artifactPath: "(none)" };
  }
  return payload.mode === "dry_run" ? dryRun(payload, ctx, inv) : execute(payload, ctx, inv);
}

module.exports = { run, inventory, describe, pathNeedles, humanSize };
