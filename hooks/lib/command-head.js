"use strict";

const {
  splitSegments,
  tokenizeSegment,
  stripSubstitutions,
} = require("./command-parser");

const LAUNCHERS = Object.freeze({
  uv:   { kind: "uv-run" },
  bash: { kind: "shell-c" },
  sh:   { kind: "shell-c" },
});

const UV_RUN_VALUE_FLAGS = Object.freeze(new Set([
  "--with", "--with-requirements", "--with-editable",
  "--python", "-p",
  "--index", "--index-url", "--extra-index-url", "--index-strategy",
  "--resolution", "--prerelease",
  "--directory", "--project", "--package", "--refresh-package",
]));

const UV_RUN_BOOL_FLAGS = Object.freeze(new Set([
  "--no-project", "--isolated", "--frozen", "--locked", "--no-sync",
  "--refresh", "--reinstall", "--no-dev", "--only-dev",
  "--all-extras", "--no-editable",
]));

const ENV_PREFIX_RE = /^[A-Za-z_][A-Za-z0-9_]*=/;
const SHORT_FLAG_RE = /^-[A-Za-z]$/;
const LONG_FLAG_RE = /^--[a-z][a-z0-9-]*$/;
const SHELL_C_FLAG_RE = /^-[a-zA-Z]*c[a-zA-Z]*$/;

function uvRunPeel(args, matcher, launchers) {
  let i = 0;
  while (i < args.length) {
    const tok = args[i];
    if (tok === "--") {
      const next = args[i + 1];
      if (next) {
        return peelAndMatch([next, ...args.slice(i + 2)], matcher, launchers);
      }
      return false;
    }
    if (tok === "--module" || tok === "-m") {
      const next = args[i + 1];
      if (next) {
        return peelAndMatch([next, ...args.slice(i + 2)], matcher, launchers);
      }
      return false;
    }
    if (tok === "--script") {
      const next = args[i + 1];
      if (next) {
        return matcher([next, ...args.slice(i + 2)]);
      }
      return false;
    }
    if (UV_RUN_VALUE_FLAGS.has(tok)) {
      i += 2;
      continue;
    }
    if (UV_RUN_BOOL_FLAGS.has(tok)) {
      i += 1;
      continue;
    }
    if (SHORT_FLAG_RE.test(tok) && tok !== "-p") {
      i += 1;
      continue;
    }
    if (LONG_FLAG_RE.test(tok)) {
      i += 1;
      continue;
    }
    return peelAndMatch([tok, ...args.slice(i + 1)], matcher, launchers);
  }
  return false;
}

function shellCPeel(tokens, matcher, launchers) {
  for (let k = 1; k < tokens.length; k++) {
    if (SHELL_C_FLAG_RE.test(tokens[k])) {
      const scriptStr = tokens[k + 1];
      if (scriptStr) {
        return hasCommandHead(scriptStr, matcher, { launchers });
      }
      return false;
    }
  }
  return matcher(tokens);
}

function peelAndMatch(tokens, matcher, launchers) {
  let i = 0;
  while (i < tokens.length && ENV_PREFIX_RE.test(tokens[i])) {
    i++;
  }
  const peeled = tokens.slice(i);
  if (peeled.length === 0) return false;

  const head = peeled[0];
  const launcher = launchers[head];

  if (!launcher) {
    return matcher(peeled);
  }

  if (launcher.kind === "uv-run") {
    if (peeled[1] !== "run") {
      return matcher(peeled);
    }
    return uvRunPeel(peeled.slice(2), matcher, launchers);
  }

  if (launcher.kind === "shell-c") {
    return shellCPeel(peeled, matcher, launchers);
  }

  return matcher(peeled);
}

function hasCommandHead(command, matcher, options) {
  if (!command || !command.trim()) return false;
  const launchers = (options && options.launchers) || LAUNCHERS;
  const stripped = stripSubstitutions(command);
  const segs = splitSegments(stripped);
  for (const seg of segs) {
    const tokens = tokenizeSegment(seg);
    if (tokens.length === 0) continue;
    if (peelAndMatch(tokens, matcher, launchers)) return true;
  }
  return false;
}

module.exports = { hasCommandHead };
