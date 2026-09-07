#!/usr/bin/env node
// PreToolUse hook: block Read/Edit/Write/Grep/Glob/Bash access to credential
// files. Absorbs the former hooks/block-ssh-private-key.js. WORKFLOW_OFF does
// NOT bypass this hook — credentials are never a legitimate working-document
// target.
"use strict";
const fs = require("fs");
const {
  isCredentialPath,
  isCredentialGlobPattern,
  checkExploreQuery,
  commandTouchesCredentials,
} = require("./lib/credential-check");

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(4096);
  try {
    while (true) {
      const n = fs.readSync(0, buf, 0, buf.length);
      if (n === 0) break;
      chunks.push(buf.slice(0, n));
    }
  } catch (_e) {}
  return Buffer.concat(chunks).toString("utf8");
}

function approve() { console.log(JSON.stringify({ decision: "approve" })); process.exit(0); }
function block(reason) { console.log(JSON.stringify({ decision: "block", reason })); process.exit(0); }

const BLOCK_MSG =
  "Access to credential files (~/.ssh, ~/.aws, ~/.gnupg, ~/.kube, ~/.git-credentials, " +
  "~/.docker/config.json, ~/.npmrc, ~/.pypirc, ~/.gem/credentials, ~/.netrc, ~/.pgpass, " +
  "~/.my.cnf, ~/.curlrc, ~/.m2/settings.xml, ~/.gradle/gradle.properties, " +
  "~/.terraform.d/credentials.tfrc.json, ~/.terraformrc, ~/.terraform.rc, ~/.azure, " +
  "~/.config/gh, ~/.config/gcloud, ~/.vault-token, ~/.cargo/credentials.toml, ~/.config/op) is blocked by hooks/block-credentials.js. " +
  "WORKFLOW_OFF does not bypass this hook. If this is a false-positive (e.g. the path " +
  "appears only inside a text-flag value or a quoted message), file an issue.";

const raw = readStdin();
let input;
try { input = JSON.parse(raw); } catch { approve(); }
const toolName = input.tool_name;
const toolInput = input.tool_input || {};

switch (toolName) {
  case "Bash":
  case "runInTerminal":
  case "runCommands":
    if (commandTouchesCredentials(toolInput.command || "")) block(BLOCK_MSG);
    break;
  case "Read":
    if (isCredentialPath(toolInput.file_path)) block(BLOCK_MSG);
    break;
  case "mcp__codegraph__codegraph_explore":
    if (checkExploreQuery(toolInput.query) || isCredentialPath(toolInput.projectPath)) block(BLOCK_MSG);
    break;
  case "Grep":
    if (isCredentialPath(toolInput.path) || isCredentialGlobPattern(toolInput.glob)) block(BLOCK_MSG);
    break;
  case "Glob":
    if (isCredentialGlobPattern(toolInput.pattern)) block(BLOCK_MSG);
    break;
  case "Edit":
  case "Write":
  case "MultiEdit":
  case "editFiles":
    if (isCredentialPath(toolInput.file_path)) block(BLOCK_MSG);
    break;
  default:
    break;
}
approve();
