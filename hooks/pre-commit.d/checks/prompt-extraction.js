"use strict";
// prompt-extraction backstop (#2507, #1642): runs bin/lib/prompt-extraction/cli.js --staged when
// .prompt-extraction-allowlist exists at the repo top (the agents-repo guard is the registry's).
// rc 1 blocks, rc 2 blocks as misinstalled, a missing module blocks, any other rc fails open.

const fs = require("fs");
const path = require("path");
const { out, err, linesOf } = require("../output");
const { fromCfg, captureStreams, sessionMarkerOff } = require("../lib/support");

const CLI_MODULE = "bin/lib/prompt-extraction/cli.js";
const RC_NOT_FOUND = 127;

function loadCli(cfgDir) {
  try {
    const mod = fromCfg(cfgDir, CLI_MODULE);
    return mod && typeof mod.run === "function" ? mod : null;
  } catch (_) {
    return null;
  }
}

async function run({ context, files, narrowed }) {
  if (!context.repoTop || !fs.existsSync(path.join(context.repoTop, ".prompt-extraction-allowlist"))) {
    return { verdict: "pass", messages: [] };
  }
  const messages = [];
  const marker = sessionMarkerOff(context.cfgDir);
  if (marker === 0) return { verdict: "pass", messages };
  if (marker !== 2) messages.push(err(`pre-commit: _session_marker_off rc=${marker} — prompt-extraction backstop check continues`));

  const cli = loadCli(context.cfgDir);
  if (!cli) {
    messages.push(err(`Commit blocked: check-prompt-extraction not found or not executable (rc=${RC_NOT_FOUND}).`),
      err(`Expected at: ${path.join(context.cfgDir, "bin", "check-prompt-extraction")}`));
    return { verdict: "block", messages };
  }
  const cap = captureStreams();
  const rc = await cli.run({ argv: ["--staged"], cwd: context.repoTop, env: context.env || process.env, stdout: cap.stdout, stderr: cap.stderr, only: narrowed ? files : undefined });
  const lines = linesOf(cap.text());
  if (rc === 0) return { verdict: "pass", messages };
  if (rc === 1) {
    messages.push(...lines.map(out), out(""), out("Commit blocked: prompt extraction violations in staged files."),
      out("Extract the content (rules/prompt.md §1.3 / §1.5), or unstage the file."));
    return { verdict: "block", messages };
  }
  if (rc === 2) {
    messages.push(...lines.map(err), err(""), err("Commit blocked: check-prompt-extraction usage error (rc=2)."),
      err("The prompt-extraction backstop is misinstalled — fix the invocation before committing."));
    return { verdict: "block", messages };
  }
  messages.push(err(`pre-commit: check-prompt-extraction rc=${rc} — prompt-extraction backstop skipped`));
  return { verdict: "pass", messages };
}

module.exports = { run };
