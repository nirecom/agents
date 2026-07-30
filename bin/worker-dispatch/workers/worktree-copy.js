"use strict";
// bin/worker-dispatch/workers/worktree-copy.js
//
// Stage 2 worker: replaces agents/worktree-copy-worker.md.
//
// Three CLIs in sequence — enumerate, copy, write notes. Every step the agent
// performed was already a CLI call; the agent contributed only the classification
// in its step 2, and that step's output was never read by any later step. It is
// dropped here rather than reimplemented: the copy allowlist lives in
// .worktreeinclude and is applied by bin/worktree-copy-include.js, so a second
// recommended/prohibited judgment upstream of it could only disagree with the
// mechanism that actually decides. Secret-file protection is unchanged — it was
// always the include filter's job, never the classification's.
//
// main_root and agents_config_dir may appear in the payload for contract parity
// with the agent, but the resolved anchors win: a caller-supplied checkout path
// must never be able to redirect which agents repo the child CLIs come from.

const path = require("path");

const { run: spawnRun } = require("../spawn");

const GIT_TIMEOUT_MS = 120000;
const COPY_TIMEOUT_MS = 300000;
const NOTES_TIMEOUT_MS = 60000;

function stamp() {
  return new Date().toISOString().replace(/[:.]/g, "-");
}

function countNulSeparated(text) {
  return String(text || "")
    .split("\0")
    .filter((s) => s !== "").length;
}

function firstLine(text) {
  return (String(text || "").split("\n").find((l) => l.trim() !== "") || "").trim();
}

// Step 1 — inventory. Its only remaining consumer is the log and this
// precondition check: a main-root git cannot enumerate its own ignored files
// means nothing downstream is trustworthy either.
function inventory(ctx) {
  const counts = {};
  for (const [key, extra] of [["ignored", ["--ignored"]], ["untracked", []]]) {
    const res = spawnRun(ctx.entry, {
      anchors: ctx.anchors,
      command: "git",
      args: ["ls-files", "--others", ...extra, "--exclude-standard", "-z"],
      cwd: ctx.anchors.mainRoot,
      timeoutMs: GIT_TIMEOUT_MS,
    });
    if (res.timedOut) return { error: `git ls-files (${key}) exceeded its budget` };
    if (res.spawnError !== null) return { error: `git could not run: ${res.spawnError}` };
    if (res.status !== 0) return { error: firstLine(res.stderr) || `git ls-files exited ${res.status}` };
    counts[key] = countNulSeparated(res.stdout);
  }
  return { counts };
}

// Step 3 — the copy itself. Failures here are non-fatal by contract: a worktree
// missing some gitignored state is recoverable by hand, so the caller is told
// `partial` and given the log rather than being stopped.
function copyInclude(ctx, worktreePath) {
  let res = null;
  try {
    res = spawnRun(ctx.entry, {
      anchors: ctx.anchors,
      command: "node",
      script: "includeFilter",
      args: ["--main-root", ctx.anchors.mainRoot, "--worktree-path", worktreePath],
      cwd: ctx.anchors.mainRoot,
      timeoutMs: COPY_TIMEOUT_MS,
    });
  } catch (e) {
    return { copiedJson: "", result: null, error: e && e.message ? e.message : "could not start the copy CLI" };
  }

  if (res.timedOut) return { copiedJson: "", result: null, error: "the copy CLI exceeded its budget" };
  if (res.spawnError !== null) return { copiedJson: "", result: null, error: `node could not run: ${res.spawnError}` };

  const raw = String(res.stdout || "").trim();
  let parsed = null;
  try {
    parsed = JSON.parse(raw);
  } catch (_e) {
    parsed = null;
  }
  if (parsed === null || typeof parsed !== "object") {
    return {
      copiedJson: "",
      result: null,
      error: `the copy CLI did not return JSON${res.status === 0 ? "" : ` (exit ${res.status})`}: ${firstLine(res.stderr)}`,
    };
  }

  // A non-zero exit with parseable output still carries a usable copied list —
  // keep it, and let the error text explain the partial status.
  const error = res.status === 0 ? null : `the copy CLI exited ${res.status}: ${firstLine(res.stderr)}`;
  return { copiedJson: raw, result: parsed, error };
}

// Step 3b — sibling worktrees declared in intent.md. The CLI is fail-open by
// design (missing file prints `[]`), so only a spawn-level failure is reported.
function siblingWorktrees(ctx, sessionId) {
  if (sessionId === "") return "[]";
  const intentPath = path.join(ctx.anchors.plansDir, `${sessionId}-intent.md`);
  try {
    const res = spawnRun(ctx.entry, {
      anchors: ctx.anchors,
      command: "node",
      script: "parseWorktrees",
      args: [intentPath],
      cwd: ctx.anchors.mainRoot,
      timeoutMs: NOTES_TIMEOUT_MS,
    });
    const out = String(res.stdout || "").trim();
    return res.status === 0 && out !== "" ? out : "[]";
  } catch (_e) {
    return "[]";
  }
}

// Step 4 — WORKTREE_NOTES.md. The one fatal step: /worktree-start and
// /worktree-end both key off this file, so a missing one is not a degraded
// worktree but an unusable one.
function writeNotes(ctx, worktreePath, branch, sessionId, copiedJson, siblingJson) {
  let res = null;
  try {
    res = spawnRun(ctx.entry, {
      anchors: ctx.anchors,
      command: "node",
      script: "writeNotes",
      args: [ctx.anchors.mainRoot, worktreePath, branch, "", sessionId],
      cwd: ctx.anchors.mainRoot,
      timeoutMs: NOTES_TIMEOUT_MS,
      extraEnv: { COPIED_JSON: copiedJson, SIBLING_WORKTREES_JSON: siblingJson },
    });
  } catch (e) {
    return e && e.message ? e.message : "could not start the notes CLI";
  }
  if (res.timedOut) return "the notes CLI exceeded its budget";
  if (res.spawnError !== null) return `node could not run: ${res.spawnError}`;
  if (res.status !== 0) return firstLine(res.stderr) || `the notes CLI exited ${res.status}`;
  return null;
}

function run(payload, ctx) {
  const { anchors, fsguard } = ctx;
  const worktreePath = payload.worktree_path;
  const branch = payload.branch;
  const sessionId = typeof payload.session_id === "string" ? payload.session_id : "";
  const artifactDir = payload.artifact_dir || anchors.plansDir;
  const notes = [];

  const inv = inventory(ctx);
  if (inv.error !== undefined) {
    return { status: "failed", summary: `inventory failed: ${inv.error}`, artifactPath: "(none)" };
  }

  const copy = copyInclude(ctx, worktreePath);
  const copied = copy.result && Array.isArray(copy.result.copied) ? copy.result.copied : [];
  const denied = copy.result && Array.isArray(copy.result.denied) ? copy.result.denied : [];
  const errors = copy.result && Array.isArray(copy.result.errors) ? copy.result.errors : [];
  if (copy.error !== null) notes.push(copy.error);
  for (const d of denied) notes.push(`denied: ${d}`);
  for (const e of errors) notes.push(`error: ${e}`);

  const siblingJson = siblingWorktrees(ctx, sessionId);

  const notesError = writeNotes(ctx, worktreePath, branch, sessionId, copy.copiedJson, siblingJson);
  if (notesError !== null) {
    return {
      status: "failed",
      summary: `WORKTREE_NOTES.md write failed: ${notesError}`,
      artifactPath: "(none)",
    };
  }

  const status = notes.length === 0 ? "complete" : "partial";
  const summary =
    `${copied.length} files copied; WORKTREE_NOTES.md written` +
    (notes.length === 0 ? "" : `; ${notes.length} copy issue(s) — see the log`);

  // Log write is best-effort: the worktree is already correctly populated, and
  // losing the log must not downgrade a completed copy to a failure.
  let written = "(none)";
  try {
    written = fsguard.writeFile(
      path.join(artifactDir, `${stamp()}-worktree-copy-worker.log`),
      [
        `main-root: ${anchors.mainRoot}`,
        `worktree: ${worktreePath}`,
        `branch: ${branch}`,
        `session-id: ${sessionId === "" ? "(none)" : sessionId}`,
        `ignored files in main: ${inv.counts.ignored}`,
        `untracked files in main: ${inv.counts.untracked}`,
        `copied: ${copied.length}`,
        `denied: ${denied.length}`,
        `errors: ${errors.length}`,
        `sibling worktrees: ${siblingJson}`,
        ...copied.map((c) => `  copied: ${c}`),
        ...notes.map((n) => `  ${n}`),
        "",
      ].join("\n")
    );
  } catch (_e) {
    written = "(none)";
  }

  return { status, summary, artifactPath: written };
}

module.exports = { run, countNulSeparated, copyInclude, writeNotes };
