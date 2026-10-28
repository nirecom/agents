"use strict";
// hooks/block-credentials/judge.js — the block-credentials judgment: deny Read/Edit/Write/Grep/
// Glob/command access to credential files; approve everything else. WORKFLOW_OFF does NOT bypass
// it: credentials are never a legitimate working-document target.

const {
  isCredentialPath,
  isCredentialGlobPattern,
  checkExploreQuery,
  commandTouchesCredentials,
} = require("../lib/credential-check");
const { isCommandTool } = require("../lib/tool-command-text");
const { scannableCommandListOf } = require("../lib/scannable-command-list");

const BLOCK_MSG =
  "Access to credential files (~/.ssh, ~/.aws, ~/.gnupg, ~/.kube, ~/.git-credentials, " +
  "~/.docker/config.json, ~/.npmrc, ~/.pypirc, ~/.gem/credentials, ~/.netrc, ~/.pgpass, " +
  "~/.my.cnf, ~/.curlrc, ~/.m2/settings.xml, ~/.gradle/gradle.properties, " +
  "~/.terraform.d/credentials.tfrc.json, ~/.terraformrc, ~/.terraform.rc, ~/.azure, " +
  "~/.config/gh, ~/.config/gcloud, ~/.vault-token, ~/.cargo/credentials.toml, ~/.config/op) is blocked by hooks/block-credentials.js. " +
  "WORKFLOW_OFF does not bypass this hook. If this is a false-positive (e.g. the path " +
  "appears only inside a text-flag value or a quoted message), file an issue.";

const APPROVE = Object.freeze({ decision: "approve" });
const DENY = Object.freeze({ decision: "deny", reason: BLOCK_MSG });

function touchesCredentials(toolName, toolInput) {
  switch (toolName) {
    case "Read":
      return isCredentialPath(toolInput.file_path);
    case "mcp__codegraph__codegraph_explore":
      return checkExploreQuery(toolInput.query) || isCredentialPath(toolInput.projectPath);
    case "Grep":
      return isCredentialPath(toolInput.path) || isCredentialGlobPattern(toolInput.glob);
    case "Glob":
      return isCredentialGlobPattern(toolInput.pattern);
    case "Edit":
    case "Write":
    case "MultiEdit":
    case "editFiles":
      return isCredentialPath(toolInput.file_path);
    default:
      return false;
  }
}

/**
 * @param {object} input a PreToolUse hook payload
 * @returns {{decision: "deny"|"approve", reason?: string}}
 */
function judgeCredentials(input) {
  const payload = input || {};
  const toolName = payload.tool_name;
  const toolInput = payload.tool_input || {};
  if (isCommandTool(toolName)
    && scannableCommandListOf(toolName, toolInput).some((cmd) => commandTouchesCredentials(cmd))) return DENY;
  return touchesCredentials(toolName, toolInput) ? DENY : APPROVE;
}

module.exports = { judgeCredentials, BLOCK_MSG };
