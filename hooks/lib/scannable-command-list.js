"use strict";
// Deny-side command list: commandListOf plus a runCommands string `.command`,
// which the pre-#2206 guards scanned — dropping it would reopen a bypass.
const { commandListOf } = require("./tool-command-text");

function scannableCommandListOf(toolName, toolInput) {
  const list = commandListOf(toolName, toolInput);
  const cmd = toolInput && typeof toolInput === "object" ? toolInput.command : undefined;
  if (toolName === "runCommands" && typeof cmd === "string" && cmd !== "") list.push(cmd);
  return list;
}

module.exports = { scannableCommandListOf };
