"use strict";

// Parse EM Supervisor codex-engine output (#929): content between the
// `<!-- begin-codex-output -->` / `<!-- end-codex-output -->` markers is JSON
// Lines — alert = FINDING objects only; audit = exactly one VERDICT object plus
// FINDING objects. parseSupervisorFindings(input, mode) → {ok, verdict, findings}.
// CLI (stdin, --mode): on ok writes FINDING-only JSONL to os.tmpdir and prints
// `OUTFILE:`; audit also prints `VERDICT:`. Contract SSOT: detail.md Step 8.

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

function extractContent(input) {
  if (typeof input !== "string") return null;
  const begin = input.match(/<!--\s*begin-codex-output[^>]*-->/);
  const end = input.match(/<!--\s*end-codex-output\s*-->/);
  if (!begin || !end || end.index < begin.index) return null;
  return input.slice(begin.index + begin[0].length, end.index);
}

function isValidFinding(o) {
  if (!o || typeof o !== "object" || Array.isArray(o)) return false;
  if (!Array.isArray(o.categories) || o.categories.length === 0) return false;
  for (const c of o.categories) if (!CATEGORIES.has(c)) return false;
  if (!SEVERITY_VALUES.has(o.severity)) return false;
  if (typeof o.detail !== "string") return false;
  return true;
}

function parseSupervisorFindings(input, mode) {
  const content = extractContent(input);
  if (content === null) return { ok: false, verdict: null, findings: [] };

  const lines = content.split(/\r?\n/).map((l) => l.trim()).filter((l) => l.length > 0);
  const findings = [];
  let verdict = null;
  let verdictCount = 0;

  for (const line of lines) {
    let obj;
    try {
      obj = JSON.parse(line);
    } catch (e) {
      return { ok: false, verdict: null, findings: [] };
    }
    if (!obj || typeof obj !== "object" || Array.isArray(obj)) {
      return { ok: false, verdict: null, findings: [] };
    }
    if (Object.prototype.hasOwnProperty.call(obj, "verdict")) {
      // A verdict object only belongs in audit output.
      if (mode !== "audit") return { ok: false, verdict: null, findings: [] };
      if (typeof obj.verdict !== "string" || !AUDIT_VERDICTS.has(obj.verdict)) {
        return { ok: false, verdict: null, findings: [] };
      }
      verdictCount += 1;
      verdict = obj.verdict;
    } else {
      if (!isValidFinding(obj)) return { ok: false, verdict: null, findings: [] };
      findings.push(obj);
    }
  }

  if (mode === "audit") {
    // Exactly one verdict is required; zero or two+ is a protocol violation.
    if (verdictCount !== 1) return { ok: false, verdict: null, findings: [] };
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
      // line as "not SUCCESS".
      process.exit(1);
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
