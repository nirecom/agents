"use strict";
// bin/worker-dispatch/workers/worktree-backup.js
//
// Stage 2 worker: replaces agents/worktree-backup-worker.md.
//
// The agent's prompt spent its longest paragraph (step 3) explaining how to
// shape `cp` invocations so the write hook's literal resolver would recognize
// them — no chaining, no shell variables in the destination, env-prefix form as
// a fallback. None of that survives here: files are copied through fsguard, so
// the destination is proven to be inside the derived backup directory by the
// same code that answers every other write in this dispatcher, and there is no
// command line for a hook to have to parse.
//
// backup_dir is derived (<main-root>/.worktree-backup/<branch>), never accepted
// from the caller — see bin/worker-dispatch/capability.js. A caller may echo the
// exact derived value for readability; anything else is rejected upstream.

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const { run: spawnRun } = require("../spawn");

const GIT_TIMEOUT_MS = 120000;
const DOCKER_TIMEOUT_MS = 30000;

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
function inventory(ctx, worktreePath) {
  const ignored = git(ctx, worktreePath, ["ls-files", "--others", "--ignored", "--exclude-standard", "-z"]);
  if (ignored.error) return { error: ignored.error };
  const untracked = git(ctx, worktreePath, ["ls-files", "--others", "--exclude-standard", "-z"]);
  if (untracked.error) return { error: untracked.error };
  const modified = git(ctx, worktreePath, ["status", "--porcelain=v1", "-z"]);
  if (modified.error) return { error: modified.error };

  const seen = new Set();
  const candidates = [];
  for (const rel of splitNul(ignored.stdout).concat(splitNul(untracked.stdout))) {
    if (seen.has(rel)) continue;
    seen.add(rel);
    candidates.push(rel);
  }
  candidates.sort();
  return {
    candidates,
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

function dryRun(payload, ctx, inv) {
  const { fsguard, anchors } = ctx;
  const worktreePath = payload.worktree_path;
  const artifactDir = payload.artifact_dir || anchors.plansDir;

  const described = inv.candidates.map((rel) => describe(worktreePath, rel));
  const files = described.filter((d) => d.skip === undefined);
  const skipped = described.filter((d) => d.skip !== undefined);
  const total = files.reduce((sum, f) => sum + f.size, 0);
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
        `candidates: ${files.length} files, ${humanSize(total)}`,
        `  ignored: ${inv.ignoredCount}  untracked: ${inv.untrackedCount}  dirty tracked: ${inv.dirtyCount}`,
        `skipped: ${skipped.length}`,
        `docker: ${docker.checked ? `${docker.containers.length} container(s) bind-mount this worktree, ${stopped.length} stopped` : "not checked"}`,
        "",
        ...files.map((f) => `  ${f.rel} (${humanSize(f.size)})`),
        ...skipped.map((s) => `  [skip] ${s.rel} — ${s.skip}`),
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

  return {
    status: "dry_run_complete",
    summary:
      `${files.length} files / ${humanSize(total)} to ${payload.backup_dir}` +
      (docker.containers.length === 0 ? "" : `; ${docker.containers.length} docker bind-mount(s)`),
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
  const notes = described.filter((d) => d.skip !== undefined).map((d) => `${d.rel}: ${d.skip}`);

  if (pending.length === 0) {
    return {
      status: "skipped",
      summary: "no gitignored or untracked files to back up",
      artifactPath: "(none)",
    };
  }

  const manifestFiles = [];
  let copiedBytes = 0;
  for (const f of pending) {
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
        `copied: ${manifestFiles.length} / ${pending.length} candidates (${humanSize(copiedBytes)})`,
        `manifest: ${manifestPath}`,
        `docker: ${docker.checked ? `${docker.containers.length} bind-mount(s)` : "not checked"}`,
        ...notes.map((n) => `  ${n}`),
        "",
      ].join("\n")
    );
  } catch (_e) {
    /* keep the reported status; the manifest already carries `issues` */
  }

  const failedCopies = pending.length - manifestFiles.length;
  return {
    status: failedCopies === 0 && notes.length === 0 ? "copied" : "partial",
    summary:
      `${manifestFiles.length} files / ${humanSize(copiedBytes)} to ${backupDir}` +
      (docker.containers.length === 0 ? "" : `; ${docker.containers.length} docker bind-mount(s)`) +
      (notes.length === 0 ? "" : `; ${notes.length} issue(s) — see the manifest`),
    artifactPath: manifestPath,
  };
}

function run(payload, ctx) {
  const inv = inventory(ctx, payload.worktree_path);
  if (inv.error !== undefined) {
    return { status: "failed", summary: `inventory failed: ${inv.error}`, artifactPath: "(none)" };
  }
  return payload.mode === "dry_run" ? dryRun(payload, ctx, inv) : execute(payload, ctx, inv);
}

module.exports = { run, inventory, describe, pathNeedles, humanSize };
