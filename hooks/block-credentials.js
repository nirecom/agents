#!/usr/bin/env node
// PreToolUse hook: block Read/Edit/Write/Grep/Glob/Bash access to credential
// files. Absorbs the former hooks/block-ssh-private-key.js. WORKFLOW_OFF does
// NOT bypass this hook — credentials are never a legitimate working-document
// target.
"use strict";
const fs = require("fs");
const { checkBashCommand } = require("./lib/command-parser");
const { isUnderAnyRoot, globMatchesUnder } = require("./lib/path-match");

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

// CREDENTIALS_TABLE — single source of truth for protected paths.
// Entry shape:
//   root:               primary ~/... path.
//   extraLiteralRoots?: additional absolute paths (SSH only adds /root/.ssh).
//   displayName:        human-readable name (reserved for future per-family msgs).
const CREDENTIALS_TABLE = [
  { root: "~/.ssh",                                    extraLiteralRoots: ["/root/.ssh"], displayName: "SSH keys" },
  { root: "~/.gnupg",                                                                     displayName: "GnuPG keyring" },
  { root: "~/.aws",                                                                       displayName: "AWS credentials" },
  { root: "~/.azure",                                                                     displayName: "Azure credentials" },
  { root: "~/.config/gh",                                                                 displayName: "GitHub CLI config" },
  { root: "~/.git-credentials",                                                           displayName: "Git credentials store" },
  { root: "~/.docker/config.json",                                                        displayName: "Docker config" },
  { root: "~/.kube",                                                                      displayName: "Kubernetes config" },
  { root: "~/.npmrc",                                                                     displayName: "npm credentials" },
  { root: "~/.pypirc",                                                                    displayName: "PyPI credentials" },
  { root: "~/.gem/credentials",                                                           displayName: "RubyGems credentials" },
  { root: "~/.netrc",                                                                     displayName: "netrc credentials" },
  { root: "~/.pgpass",                                                                    displayName: "PostgreSQL password file" },
  { root: "~/.my.cnf",                                                                    displayName: "MySQL config" },
  { root: "~/.curlrc",                                                                    displayName: "curl credentials" },
  { root: "~/.m2/settings.xml",                                                           displayName: "Maven settings" },
  { root: "~/.gradle/gradle.properties",                                                  displayName: "Gradle properties" },
  { root: "~/.terraform.d/credentials.tfrc.json",                                         displayName: "Terraform credentials" },
  { root: "~/.terraformrc",                                                               displayName: "Terraform CLI config" },
  { root: "~/.terraform.rc",                                                              displayName: "Terraform CLI config (Windows)" },
];

const ALL_ROOTS = CREDENTIALS_TABLE.map((e) => e.root);
const ALL_LITERAL_ROOTS = CREDENTIALS_TABLE.flatMap((e) => e.extraLiteralRoots || []);

function isCredentialPath(p) {
  return isUnderAnyRoot(p, ALL_ROOTS, ALL_LITERAL_ROOTS);
}

function isCredentialGlobPattern(pattern) {
  return globMatchesUnder(pattern, [...ALL_ROOTS, ...ALL_LITERAL_ROOTS]);
}

// -i deliberately omitted from PATH_FLAGS: collides with sed -i / grep -i / cp -i.
// Positional fallback still catches ssh -i ~/.ssh/key host.
const TEXT_FLAGS = new Set([
  "-m", "--message", "--body", "--title", "--notes", "--description",
  "--subject", "--branch", "--label", "--assignee", "--reviewer",
  "--milestone", "--project", "--head", "--base",
]);
const PATH_FLAGS = new Set([
  "-f", "--file", "-o", "--output", "--input",
  "--from-file", "--to-file", "-T", "--upload-file",
]);
const TEXT_CMDS = new Set(["echo", "printf"]);
const SHELL_BINS = new Set(["bash", "sh", "dash", "zsh", "ksh"]);

function checkBash(command) {
  return checkBashCommand(command, {
    isTargetPath: isCredentialPath,
    textFlags: TEXT_FLAGS,
    pathFlags: PATH_FLAGS,
    textCmds: TEXT_CMDS,
    shellBins: SHELL_BINS,
  });
}

const BLOCK_MSG =
  "Access to credential files (~/.ssh, ~/.aws, ~/.gnupg, ~/.kube, ~/.git-credentials, " +
  "~/.docker/config.json, ~/.npmrc, ~/.pypirc, ~/.gem/credentials, ~/.netrc, ~/.pgpass, " +
  "~/.my.cnf, ~/.curlrc, ~/.m2/settings.xml, ~/.gradle/gradle.properties, " +
  "~/.terraform.d/credentials.tfrc.json, ~/.terraformrc, ~/.terraform.rc, ~/.azure, " +
  "~/.config/gh) is blocked by hooks/block-credentials.js. " +
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
    if (checkBash(toolInput.command || "")) block(BLOCK_MSG);
    break;
  case "Read":
    if (isCredentialPath(toolInput.file_path)) block(BLOCK_MSG);
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
