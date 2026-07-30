"use strict";
// bin/worker-dispatch/workers/doc-append.js
//
// Stage 2 worker: replaces agents/doc-append-worker.md.
//
// One CLI call, three shapes. The agent's whole job was choosing between them
// from a mode field and then not mangling the argv — which is exactly the kind
// of work a table does better, and the reason its prompt had to spend six lines
// forbidding redirection and pipes. Here there is no shell to redirect into.
//
// Two gates the agent got for free from the Bash tool and a script does not:
//
//   1. hooks/check-japanese-in-docs.js reads the doc-append COMMAND, so it can
//      only see arguments that pass through the Bash tool. A payload file is
//      invisible to it. The same check therefore runs here, calling the same two
//      libraries the hook calls, so the public-repo English-only rule cannot
//      drift between the two call sites.
//   2. Conditional required fields (commits for history, a merge target for
//      compose, test-gap for a BUGFIX history entry) are per-mode and cannot be
//      expressed in the registry's flat payloadSpec, so they are checked here
//      before anything is spawned.

const path = require("path");

const { run: spawnRun, resolveScript } = require("../spawn");
const { isPrivateRepo } = require("../../../hooks/lib/is-private-repo");
const { hasCJK } = require("../../../hooks/lib/detect-cjk");

const CLI_TIMEOUT_MS = 300000;
const NOOP_RE = /already exists|noop/i;
// The text fields that end up as document body content. Order fixes the order
// they are reported in, so a caller sees the same message for the same input.
const CONTENT_FIELDS = ["category", "subject", "background", "changes", "test_gap"];

function stamp() {
  return new Date().toISOString().replace(/[:.]/g, "-");
}

// doc-append.py requires --date and never defaults it. The agent supplied it from
// its own sense of "today", which is why no caller passes a date field. Local
// time, matching the `date +%F` the shell callers use.
function todayLocal() {
  const d = new Date();
  const pad = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

function firstLine(text) {
  return (String(text || "").split("\n").find((l) => l.trim() !== "") || "").trim();
}

function str(payload, key) {
  return typeof payload[key] === "string" ? payload[key] : "";
}

// Per-mode required fields. Returns an error string or null.
function checkRequired(payload) {
  const mode = payload.mode;
  const missing = [];
  if (mode === "history" || mode === "changelog") {
    for (const key of ["category", "subject", "background", "changes"]) {
      if (str(payload, key) === "") missing.push(key);
    }
    if (mode === "history" && str(payload, "commits") === "") missing.push("commits");
    // Same rule doc-append.py enforces, checked here so the caller is told before
    // a process is spawned. rules/docs/history.md is the SSOT for the rule itself.
    if (mode === "history" && payload.category === "BUGFIX" && str(payload, "test_gap") === "") {
      missing.push("test_gap (required for a BUGFIX history entry)");
    }
    // INCIDENT needs --cause/--fix, which no caller of this worker has ever had a
    // field for — the agent contract this replaces could not append one either.
    // Fail with the reason rather than letting the CLI reject the argv.
    if (payload.category === "INCIDENT") {
      return "category=INCIDENT is not supported here — it needs --cause/--fix; call doc-append directly";
    }
  } else {
    for (const key of ["notes_path", "branch", "merge_commit"]) {
      if (str(payload, key) === "") missing.push(key);
    }
    if (payload.bootstrap !== true && str(payload, "pr_number") === "") {
      missing.push("pr_number (required unless bootstrap is true)");
    }
  }
  return missing.length === 0 ? null : `missing required field(s) for mode=${mode}: ${missing.join(", ")}`;
}

// Mirrors hooks/check-japanese-in-docs.js: Japanese content is allowed in a
// private repo and blocked in a public one. Compose mode is deliberately out of
// scope — its text comes from WORKTREE_NOTES.md, which the hook never covered
// either, and compose-doc-append-entry owns that path.
function checkLanguage(payload, cwd) {
  if (payload.mode === "compose") return null;
  const offenders = CONTENT_FIELDS.filter((key) => hasCJK(str(payload, key)));
  if (offenders.length === 0) return null;
  if (isPrivateRepo(cwd)) return null;
  return (
    `Japanese text in ${offenders.join(", ")} — this is a public repository and` +
    " history.md/CHANGELOG.md must be written in English"
  );
}

function buildArgs(payload, ctx) {
  const mode = payload.mode;
  if (mode === "compose") {
    const args = [
      resolveScript(ctx.entry, "composeEntry", ctx.anchors),
      "--notes", str(payload, "notes_path"),
      "--branch", str(payload, "branch"),
    ];
    if (payload.bootstrap === true) args.push("--bootstrap");
    else args.push("--pr", str(payload, "pr_number"));
    args.push("--merge-commit", str(payload, "merge_commit"));
    args.push("--background", str(payload, "pr_title"));
    args.push("--closes-issues-count", String(payload.closes_issues_count || 0));
    if (str(payload, "test_gap") !== "") args.push("--test-gap", str(payload, "test_gap"));
    return { command: "bash", args };
  }

  // `uv run <script>` rather than the doc-append PATH launcher: the launcher is
  // installed by the dotfiles repo and may be absent, while the script is always
  // present under the resolved ACD anchor.
  const args = ["run", resolveScript(ctx.entry, "docAppend", ctx.anchors)];
  args.push(mode === "history" ? "docs/history.md" : "CHANGELOG.md");
  args.push("--category", str(payload, "category"));
  args.push("--subject", str(payload, "subject"));
  if (mode === "history") args.push("--commits", str(payload, "commits"));
  args.push("--background", str(payload, "background"));
  args.push("--changes", str(payload, "changes"));
  args.push("--date", str(payload, "date") || todayLocal());
  if (str(payload, "test_gap") !== "") args.push("--test-gap", str(payload, "test_gap"));
  return { command: "uv", args };
}

function run(payload, ctx) {
  const { anchors, fsguard } = ctx;
  const cwd = payload.cwd;
  const artifactDir = payload.artifact_dir || anchors.plansDir;

  const required = checkRequired(payload);
  if (required !== null) return { status: "failed", summary: required, artifactPath: "(none)" };

  const language = checkLanguage(payload, cwd);
  if (language !== null) return { status: "failed", summary: language, artifactPath: "(none)" };

  let plan = null;
  try {
    plan = buildArgs(payload, ctx);
  } catch (e) {
    return {
      status: "failed",
      summary: `could not resolve the CLI: ${e && e.message ? e.message : "unknown error"}`,
      artifactPath: "(none)",
    };
  }

  let res = null;
  try {
    res = spawnRun(ctx.entry, {
      anchors,
      command: plan.command,
      args: plan.args,
      cwd,
      timeoutMs: CLI_TIMEOUT_MS,
    });
  } catch (e) {
    return {
      status: "failed",
      summary: `could not start ${plan.command}: ${e && e.message ? e.message : "unknown error"}`,
      artifactPath: "(none)",
    };
  }

  const combined = `${res.stdout || ""}\n${res.stderr || ""}`;

  // The log is written before the status is decided: a failed append is exactly
  // the case where the caller needs the CLI's own output most.
  let written = "(none)";
  try {
    written = fsguard.writeFile(
      path.join(artifactDir, `${stamp()}-doc-append-worker.log`),
      [
        `mode: ${payload.mode}`,
        `cwd: ${cwd}`,
        `command: ${plan.command}`,
        `exit: ${res.timedOut ? "(timed out)" : res.status}`,
        "--- stdout ---",
        String(res.stdout || ""),
        "--- stderr ---",
        String(res.stderr || ""),
        "",
      ].join("\n")
    );
  } catch (_e) {
    written = "(none)";
  }

  if (res.timedOut) {
    return {
      status: "failed",
      summary: `${plan.command} exceeded its ${Math.round(CLI_TIMEOUT_MS / 1000)}s budget`,
      artifactPath: written,
    };
  }
  if (res.spawnError !== null) {
    return { status: "failed", summary: `${plan.command} could not run: ${res.spawnError}`, artifactPath: written };
  }
  if (res.status !== 0) {
    return {
      status: "failed",
      summary: firstLine(res.stderr) || firstLine(res.stdout) || `${plan.command} exited ${res.status}`,
      artifactPath: written,
    };
  }

  if (NOOP_RE.test(combined)) {
    return { status: "noop", summary: `${payload.mode}: nothing to append (entry already present)`, artifactPath: written };
  }

  const target = payload.mode === "changelog" ? "CHANGELOG.md" : payload.mode === "history" ? "docs/history.md" : "docs/history.md + CHANGELOG.md";
  return { status: "appended", summary: `${payload.mode}: appended to ${target}`, artifactPath: written };
}

module.exports = { run, checkRequired, checkLanguage, buildArgs };
