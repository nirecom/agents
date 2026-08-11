#!/usr/bin/env node
"use strict";

// InstructionsLoaded audit hook.
//
// Why: a rule that is meant to be read on demand disables auto-injection with a
// reserved `paths:` glob. Nothing in the loader enforces that, so the only way
// to know what a session really injected is to observe the load events. The host
// fires InstructionsLoaded once per file, asynchronously, in its own process —
// this hook classifies that ONE file and publishes a receipt for it.
//
// Division of labour: the static checker (bin/check-on-demand-rules.sh) is
// fail-CLOSED and blocks commits. This hook is fail-OPEN and always exits 0 with
// empty stdout: an observation tool that can break a live session is worse than
// no observation at all.

const fs = require("fs");
const path = require("path");

// Node's own built-ins cannot fail to load; an agents-owned module can (partial
// deploy, a syntax error introduced downstream). A module-scope require that
// throws prints a stack trace and exits non-zero — exactly the "audit hook took
// the session down" outcome this file's contract forbids — so the bindings are
// acquired defensively and main() fails open when either is missing.
let receipt = null;
let policyReader = null;
try {
  receipt = require("./lib/instructions-loaded-receipt");
  policyReader = require("./lib/rules-policy-reader");
} catch (_) {
  // fail-open: main() returns early while the bindings are unavailable
}

const SUPERVISOR_SEVERITY = {
  "S-MISSING": "warning",
  "S-MALFORMED": "error",
  "S-LEAK": "error",
};

// The policy is a contributor-editable declaration file: require()-ing it would
// execute a pull request's module body merely because a session started on that
// branch. It is read AS DATA instead — including the RULES_INJECTION_POLICY test
// seam, which points at an arbitrary path and would be strictly worse to run.
function loadPolicy() {
  const override = process.env.RULES_INJECTION_POLICY;
  const policyPath = override
    ? path.resolve(override)
    : path.join(__dirname, "lib", "rules-injection-policy.js");
  return policyReader.loadPolicyAsData(policyPath);
}

function readStdin() {
  try {
    return fs.readFileSync(0, "utf8");
  } catch (_) {
    return "";
  }
}

function stripBom(text) {
  return text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
}

// A frontmatter block exists only when the file OPENS with `---` and a closing
// `---` line follows. An unterminated block is not a block.
const FRONTMATTER_RE = /^---[ \t]*\r?\n(?:([\s\S]*?)\r?\n)?---[ \t]*(?:\r?\n|$)/;

// Parse the `paths:` key out of a frontmatter block.
// Returns { present, malformed, values }.
function parsePaths(block) {
  const lines = block.split(/\r?\n/);
  const keyLines = [];
  lines.forEach((line, i) => {
    if (/^paths:/.test(line)) keyLines.push(i);
  });
  if (keyLines.length === 0) return { present: false, malformed: false, values: [] };
  // A duplicated key has no single well-defined value; which one the loader
  // honours is an implementation detail nobody should have to know.
  if (keyLines.length > 1) return { present: true, malformed: true, values: [] };

  const start = keyLines[0];
  if (lines[start].slice("paths:".length).trim() !== "") {
    // Any inline value — a scalar, an empty flow list, an unclosed flow list —
    // is not the block-list form this repo uses.
    return { present: true, malformed: true, values: [] };
  }

  const items = [];
  for (let i = start + 1; i < lines.length; i += 1) {
    const item = /^\s+-\s?(.*)$/.exec(lines[i]);
    if (!item) break;
    items.push(item[1].trim());
  }
  if (items.length === 0) return { present: true, malformed: true, values: [] };

  const values = [];
  for (const raw of items) {
    if (raw === "") return { present: true, malformed: true, values: [] };
    const quoted = /^(["'])([\s\S]*)\1$/.exec(raw);
    if (quoted) {
      if (quoted[2] === "") return { present: true, malformed: true, values: [] };
      values.push(quoted[2]);
      continue;
    }
    // A non-string element is a glob that matches nothing while looking
    // well-formed to a shape-only check.
    if (/^(true|false|null|~|-?\d+(?:\.\d+)?)$/i.test(raw)) {
      return { present: true, malformed: true, values: [] };
    }
    values.push(raw);
  }
  return { present: true, malformed: false, values };
}

// Classify one loaded file. `rulesKey` is the normalized `rules/<subpath>.md`
// identity — empty for anything that is not a rules file — and `absPath` is what
// to actually read from disk. Classification keys on the normalized form because
// policy.EXPECTED_UNCONDITIONAL is written in that form, and because the
// repo-relative form collapses to `out-of-root:<hash>` for the config roots most
// rules are actually loaded from.
function classify(rulesKey, absPath, policy) {
  if (!rulesKey) return "ok";

  let text;
  try {
    text = stripBom(fs.readFileSync(absPath, "utf8"));
  } catch (_) {
    // The loader can report a file this process cannot stat (race, symlink,
    // permissions). Record the observation; never crash the session.
    return "unreadable";
  }

  const block = FRONTMATTER_RE.exec(text);
  if (!block) {
    return policy.EXPECTED_UNCONDITIONAL.includes(rulesKey) ? "ok" : "S-MISSING";
  }

  const paths = parsePaths(block[1] || "");
  if (!paths.present) {
    return policy.EXPECTED_UNCONDITIONAL.includes(rulesKey) ? "ok" : "S-MISSING";
  }
  if (paths.malformed) return "S-MALFORMED";
  // The reserved glob is on disk and the loader injected the file anyway.
  // Deliberately NOT AND-conditioned on load_reason: if the reserved path is
  // ever created for real, the loader reports a legitimate glob match and an
  // AND-conditioned predicate would stop detecting the leak.
  if (paths.values.includes(policy.ON_DEMAND_TOKEN)) return "S-LEAK";
  return "ok";
}

function normalizeLoadReason(value) {
  if (typeof value === "string") return receipt.redact(value);
  if (value === undefined || value === null) return null;
  return Array.isArray(value) ? "[array]" : "[" + typeof value + "]";
}

function emitSupervisor(verdict, filePath, prior) {
  const severity = SUPERVISOR_SEVERITY[verdict];
  if (!severity) return;
  // The same file loaded repeatedly collides on one receipt key by design; a
  // per-firing emit would flood the supervisor with one finding per load.
  if (prior && prior.verdict === verdict) return;
  const { resolveWorkflowSessionId } = require("./lib/resolve-workflow-session-id");
  const wsid = resolveWorkflowSessionId();
  if (!wsid) return;
  const { reportRulesInjection } = require("./lib/supervisor-emit");
  reportRulesInjection(verdict, filePath, wsid);
}

function main() {
  if (!receipt || !policyReader) return;
  let payload;
  try {
    payload = JSON.parse(readStdin());
  } catch (_) {
    return;
  }
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) return;

  const rawPath = typeof payload.file_path === "string" ? payload.file_path : "";
  const projectRoot = process.env.CLAUDE_PROJECT_DIR || "";
  const relPath = receipt.toRepoRelative(rawPath, projectRoot);
  const rulesKey = receipt.toRulesKey(rawPath);
  const absPath = projectRoot && !path.isAbsolute(rawPath)
    ? path.resolve(projectRoot, rawPath)
    : rawPath;

  const policy = loadPolicy();
  const verdict = classify(rulesKey, absPath, policy);

  // The `out-of-root:` digest exists to keep unrelated absolute paths out of the
  // receipt. A rules file is the one class whose path is the finding, so for it
  // the normalized key is recorded instead of the digest; every other file keeps
  // the repo-relative form unchanged.
  const recordedPath = rulesKey && relPath.startsWith("out-of-root:") ? rulesKey : relPath;

  const sessionId = payload.session_id || process.env.CLAUDE_SESSION_ID || "";
  const dir = receipt.receiptDirFor(sessionId);
  if (!receipt.ensureReceiptDir(dir)) return;

  const key = receipt.entryKey(rawPath);
  const prior = receipt.readReceipt(dir, key);
  // Only file_path and load_reason are persisted; every other payload value is
  // dropped and only its KEY NAME survives as a diagnostic.
  receipt.writeReceipt(dir, key, {
    fired_at: new Date().toISOString(),
    file_path: receipt.redact(recordedPath),
    load_reason: normalizeLoadReason(payload.load_reason),
    verdict,
    payload_keys: Object.keys(payload).sort(),
  });

  emitSupervisor(verdict, receipt.redact(recordedPath), prior);
}

try {
  main();
} catch (_) {
  // fail-open: an audit hook must never take the session down
}
process.exit(0);
