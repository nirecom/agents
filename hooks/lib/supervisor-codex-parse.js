"use strict";

// Parse EM Supervisor codex-engine output (#929): content between the
// `<!-- begin-codex-output -->` / `<!-- end-codex-output -->` markers is JSON
// Lines — alert = FINDING objects only; audit = exactly one VERDICT object plus
// FINDING objects. parseSupervisorFindings(input, mode) → {ok, verdict, findings,
// reason (on failure)}. CLI (stdin, --mode): on ok writes FINDING-only JSONL to
// os.tmpdir and prints `OUTFILE:`; audit also prints `VERDICT:`; on failure prints
// `REASON:` and exits 1. Contract SSOT: detail.md Step 8.

const os = require("os");
const fs = require("fs");
const path = require("path");

const SEVERITY_VALUES = new Set(["error", "warning", "notice"]);
const CATEGORIES = new Set([
  "intent", "outline", "detail",
  "workflow", "code", "test", "security",
  "performance", "env", "other",
]);
const AUDIT_VERDICTS = new Set(["CONTINUE", "WARN", "BLOCK"]);

// Control characters plus the Unicode line/paragraph separators (Zl, Zp).
const UNSAFE_REASON_CHARS_RE = /[\p{Cc}\p{Zl}\p{Zp}]+/gu;

function extractContent(input) {
  if (typeof input !== "string") return null;
  const begin = input.match(/<!--\s*begin-codex-output[^>]*-->/);
  const end = input.match(/<!--\s*end-codex-output\s*-->/);
  if (!begin || !end || end.index < begin.index) return null;
  return input.slice(begin.index + begin[0].length, end.index);
}

// Codex-supplied values reach an LLM-read `reason:` line: echo only a short [A-Za-z0-9_.-] string
// (anything else becomes "?"), and only its type name for a non-string, so no instruction text or
// throwing toString() gets through.
function echoValue(v) {
  if (typeof v !== "string") return typeof v;
  return v.slice(0, 40).replace(/[^A-Za-z0-9_.-]/g, "?");
}

// null when valid; otherwise a short token naming the first failing field.
function validateFinding(o) {
  if (!Array.isArray(o.categories) || o.categories.length === 0) return "categories-missing";
  for (const c of o.categories) if (!CATEGORIES.has(c)) return `unknown-category:${echoValue(c)}`;
  if (!SEVERITY_VALUES.has(o.severity)) return `invalid-severity:${echoValue(o.severity)}`;
  if (typeof o.detail !== "string") return "detail-not-string";
  return null;
}

// Every {ok:false} names its branch in `reason` (#2699) so the CLI can report why.
// The reason can embed codex-controlled text: strip control characters (a newline would let it
// forge an `OUTFILE:` line in the CLI's stdout) and cap the length.
function fail(reason) {
  const safe = String(reason).replace(UNSAFE_REASON_CHARS_RE, " ").slice(0, 200);
  return { ok: false, verdict: null, findings: [], reason: safe };
}

function parseSupervisorFindings(input, mode) {
  const content = extractContent(input);
  if (content === null) return fail("missing-markers");

  const lines = content.split(/\r?\n/).map((l) => l.trim());
  const findings = [];
  let verdict = null;
  let verdictCount = 0;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (line.length === 0) continue;
    let obj;
    try {
      obj = JSON.parse(line);
    } catch (e) {
      return fail(`non-json-line:${i + 1}`);
    }
    if (!obj || typeof obj !== "object" || Array.isArray(obj)) return fail("non-object-line");
    if (Object.prototype.hasOwnProperty.call(obj, "verdict")) {
      // A verdict object only belongs in audit output.
      if (mode !== "audit") return fail("verdict-in-alert-mode");
      if (typeof obj.verdict !== "string" || !AUDIT_VERDICTS.has(obj.verdict)) return fail("invalid-verdict");
      verdictCount += 1;
      verdict = obj.verdict;
    } else {
      const why = validateFinding(obj);
      if (why) return fail(`invalid-finding:${why}`);
      findings.push(obj);
    }
  }

  if (mode === "audit") {
    // Exactly one verdict is required; zero or two+ is a protocol violation.
    if (verdictCount !== 1) return fail(`audit-verdict-count:${verdictCount}`);
    return { ok: true, verdict, findings };
  }
  return { ok: true, verdict: null, findings };
}

module.exports = { parseSupervisorFindings };

if (require.main === module) {
  const args = process.argv.slice(2);
  let mode = null;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--mode") { mode = args[i + 1]; i++; }
  }

  const chunks = [];
  process.stdin.on("data", (d) => chunks.push(d));
  process.stdin.on("end", () => {
    const input = Buffer.concat(chunks).toString("utf8");
    const r = parseSupervisorFindings(input, mode);
    if (!r.ok) {
      // {ok:false}: never write an OUTFILE — the caller reads a missing OUTFILE
      // line as "not SUCCESS"; the REASON line names the failing branch.
      // exitCode, not exit(): Windows pipes write asynchronously.
      process.stdout.write(`REASON: ${r.reason}\n`);
      process.exitCode = 1;
      return;
    }
    const outfile = path.join(
      os.tmpdir(),
      `supervisor-findings-${process.pid}-${Date.now()}.jsonl`
    );
    const body = r.findings.length
      ? r.findings.map((f) => JSON.stringify(f)).join("\n") + "\n"
      : "";
    try {
      fs.writeFileSync(outfile, body, "utf8");
    } catch (e) {
      process.exit(1);
      return;
    }
    if (mode === "audit") process.stdout.write(`VERDICT: ${r.verdict}\n`);
    process.stdout.write(`OUTFILE: ${outfile}\n`);
  });
}
