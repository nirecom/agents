"use strict";
const { classify, classifyDetailed, isGitWriteIR } = require("../lib/bash-write-patterns");
const { isPosixRedirWriteIR, isPwshWriteIR, isFileOpWriteIR, isCommandSubstWriteIR, isNewlineInjectedWriteIR, isExoticExecWriteIR, isInterpreterCWriteIR, isEncodedCommandWriteIR, isExtendedFileOpWriteIR } = require("../lib/bash-write-targets");
const { isPkgMgrWriteIR } = require("../lib/bash-write-targets/pkg-mgr");
const { isGhWriteCommand } = require("./bash-write-scope");

function detectWritePredicate(ir) {
  if (classify(ir) === "write") {
    const { matchedNames } = classifyDetailed(ir.rawText);
    return { name: "classify", detail: matchedNames.length ? `${matchedNames.join(", ")} (WRITE_PATTERNS)` : "WRITE_PATTERNS match" };
  }
  if (isGhWriteCommand(ir)) return { name: "isGhWriteCommand", detail: "gh write command" };
  if (isPosixRedirWriteIR(ir)) return { name: "isPosixRedirWriteIR", detail: "POSIX redirect or tee" };
  if (isPwshWriteIR(ir)) return { name: "isPwshWriteIR", detail: "PowerShell write cmdlet" };
  if (isFileOpWriteIR(ir)) return { name: "isFileOpWriteIR", detail: "rm/cp/mv file operation" };
  if (isGitWriteIR(ir)) return { name: "isGitWriteIR", detail: "git write subcommand" };
  if (isCommandSubstWriteIR(ir)) return { name: "isCommandSubstWriteIR", detail: "write inside $() or backtick" };
  if (isNewlineInjectedWriteIR(ir)) return { name: "isNewlineInjectedWriteIR", detail: "write on newline-injected line" };
  if (isExoticExecWriteIR(ir)) return { name: "isExoticExecWriteIR", detail: "write via eval/xargs/find" };
  if (isPkgMgrWriteIR(ir)) return { name: "isPkgMgrWriteIR", detail: "package manager write" };
  if (isInterpreterCWriteIR(ir)) return { name: "isInterpreterCWriteIR", detail: "write in interpreter -c body" };
  if (isEncodedCommandWriteIR(ir)) return { name: "isEncodedCommandWriteIR", detail: "write in encoded command" };
  if (isExtendedFileOpWriteIR(ir)) return { name: "isExtendedFileOpWriteIR", detail: "extended file operation write" };
  return null;
}

module.exports = { detectWritePredicate };
