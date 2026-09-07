// tests/feature-2132-prompt-issuance/judge-probe.js
// One node process per suite run: reads the #2132 ledger and prints
// "<site>\t<verdict>" for every judged row. A missing judge prints
// MISSING-JUDGE and exits 2 so the suite fails attributably, never vacuously.
// Usage: node judge-probe.js <agents-dir> <inventory.tsv>

const fs = require("fs");
const path = require("path");

const AGENTS_DIR = process.argv[2];
const TSV = process.argv[3];
const JUDGE = path.join(AGENTS_DIR, "hooks", "bash-guard", "judge.js");

if (!fs.existsSync(JUDGE)) {
  process.stdout.write("MISSING-JUDGE\thooks/bash-guard/judge.js\n");
  process.exit(2);
}

let judgeBashCommand;
try {
  ({ judgeBashCommand } = require(JUDGE));
} catch (e) {
  process.stdout.write("MISSING-JUDGE\trequire threw: " + e.message + "\n");
  process.exit(2);
}
if (typeof judgeBashCommand !== "function") {
  process.stdout.write("MISSING-JUDGE\tjudgeBashCommand is not exported as a function\n");
  process.exit(2);
}

// The judge's input shape is the implementer's choice (#2134 S-judge), but it
// MUST be the same PreToolUse envelope the hook itself receives -- a probe that
// also accepts a bare string or a {command} envelope would score every row
// vacuously the moment judgeBashCommand short-circuits on tool_name !== "Bash".
// Accept only the real hook envelope; anything else is reported as BAD-SHAPE
// rather than silently scored.
function judge(cmd) {
  let r;
  try {
    r = judgeBashCommand({ tool_name: "Bash", tool_input: { command: cmd } });
  } catch (e) {
    return "BAD-SHAPE";
  }
  if (r && typeof r === "object" && typeof r.verdict === "string") return r.verdict;
  return "BAD-SHAPE";
}

const rows = fs.readFileSync(TSV, "utf8").split(/\r?\n/);
for (const row of rows) {
  if (!row.trim() || row.startsWith("#")) continue;
  const cols = row.split("\t");
  if (cols.length < 3) continue;
  const [site, cls] = cols;
  const cmd = cols.slice(2).join("\t");
  if (cls !== "issuance" && cls !== "allow-rule-covered") continue;
  process.stdout.write(site + "\t" + judge(cmd) + "\n");
}

// Attributability control (mirrors cases-tool-scope.sh T2 / cases-fail-open.sh
// O4): a known-deny compound command MUST still be denied through this same
// judge() helper. Without this row, a judge() that silently allow-everything'd
// (e.g. because the envelope shape is still wrong) would make every P2 "allow"
// assertion above pass vacuously.
process.stdout.write("__CONTROL_DENY__\t" + judge("git status && ls") + "\n");
