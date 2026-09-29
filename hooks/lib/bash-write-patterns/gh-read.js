"use strict";
// hooks/lib/bash-write-patterns/gh-read.js — the positive "read" judgement for gh (#2403 N4).
// isGhWriteArgv is a denylist, so it is only an extra invariant here: the reason to allow is
// this module's own allowlist. --hostname is refused at every position, and both -R/--repo
// and the positional `repo view` selector must be a host-less OWNER/REPO, so a prompt-free
// read never sends the gh token to another host.

const { isGhWriteArgv, resolveGhSubArgv } = require("./patterns");
const { isGhApiWriteFromFlags } = require("../forge-write-extract");
const { scanGhApiFlags, hasInputFlag, PAYLOAD_FIELD_FLAGS } = require("../gh-api-argv");

const READ_SUBCOMMANDS = Object.freeze({
  issue: new Set(["list", "view", "status"]),
  pr: new Set(["list", "view", "status", "diff", "checks"]),
  repo: new Set(["view"]),
  run: new Set(["list", "view"]),
  release: new Set(["list", "view"]),
  label: new Set(["list"]),
});
const REPO_VALUE_RE = /^[^/]+\/[^/]+$/;
const HEADER_FLAGS = new Set(["-H", "--header"]);
const METHOD_OVERRIDE_RE = /x-http-method-override/i;
const SHORT_WEB_RE = /^-[A-Za-z]*w[A-Za-z]*(=.*)?$/;
// Any single-dash token other than exactly "-R" whose leading letter run contains R.
const SHORT_REPO_CLUSTER_RE = /^-[A-Za-z]*R/;

const isHostname = (tok) => tok === "--hostname" || tok.startsWith("--hostname=");
const isHostQualified = (tok) => tok.split("/").length > 2;
const isWeb = (tok) => tok === "--web" || tok.startsWith("--web=") || SHORT_WEB_RE.test(tok);

// Walks tokens for -R/--repo and checks each value. Returns false on a bad value or an
// attached (-R<value>) or clustered (-cR<value>, -cR <value>) -R spelling — never needed,
// so refused rather than parsed.
function repoValuesOk(tokens) {
  for (let i = 0; i < tokens.length; i += 1) {
    const tok = tokens[i];
    if (tok === "-R" || tok === "--repo") {
      if (!REPO_VALUE_RE.test(String(tokens[i + 1]))) return false;
      i += 1;
    } else if (tok.startsWith("--repo=")) {
      if (!REPO_VALUE_RE.test(tok.slice("--repo=".length))) return false;
    } else if (SHORT_REPO_CLUSTER_RE.test(tok)) {
      return false;
    }
  }
  return true;
}

// Returns the subcommand index, or -1 when a pre-subcommand flag is not -R/--repo.
function skipGlobals(argv) {
  let i = 0;
  while (i < argv.length && argv[i][0] === "-") {
    const tok = argv[i];
    if (tok === "-R" || tok === "--repo") i += 2;
    else if (tok.startsWith("--repo=")) i += 1;
    else return -1;
  }
  return i;
}

function isApiRead(apiArgv) {
  const scan = scanGhApiFlags(apiArgv);
  if (scan.ambiguous || typeof scan.endpoint !== "string" || scan.endpoint === "") return false;
  // Absolute URLs (containing "://") bypass --hostname screening; deny them.
  if (scan.endpoint.includes("://")) return false;
  if (isGhApiWriteFromFlags(scan.flags)) return false;
  if (hasInputFlag(scan.flags) || scan.flags.some((f) => PAYLOAD_FIELD_FLAGS.has(f.flag))) return false;
  if (scan.flags.some((f) => f.flag === "--cache")) return false;
  return !scan.flags.some((f) => HEADER_FLAGS.has(f.flag) && METHOD_OVERRIDE_RE.test(String(f.value)));
}

/**
 * @param {string[]} argv gh's argv without the `gh` word
 * @param {string[]} [_argvRaw] quote-preserving argv (accepted for the delegate contract)
 * @returns {boolean} true only for an allowlisted read; false on any doubt
 */
function isGhReadArgv(argv, _argvRaw) {
  try {
    if (!Array.isArray(argv) || argv.length === 0) return false;
    if (!argv.every((t) => typeof t === "string" && t !== "")) return false;
    if (argv.some(isHostname)) return false;
    // Positional URL args (containing "://") select a foreign host the same way --hostname does.
    if (argv.some((t) => t.includes("://"))) return false;
    const subIdx = skipGlobals(argv);
    if (subIdx < 0 || subIdx >= argv.length) return false;
    if (!repoValuesOk(argv)) return false;
    const subArgv = resolveGhSubArgv(argv);
    if (subArgv.length !== argv.length - subIdx) return false;
    if (subArgv.some(isWeb)) return false;
    if (isGhWriteArgv(argv)) return false;

    const sub0 = subArgv[0];
    if (sub0 === "api") return subIdx === 0 && isApiRead(subArgv.slice(1));
    // Only `repo view` takes a [HOST/]OWNER/REPO positional; fail closed on any 2+-slash token.
    if (sub0 === "repo" && subArgv[1] === "view" && subArgv.slice(2).some(isHostQualified)) return false;
    const allowed = Object.prototype.hasOwnProperty.call(READ_SUBCOMMANDS, sub0) ? READ_SUBCOMMANDS[sub0] : null;
    return allowed !== null && allowed.has(subArgv[1]);
  } catch (_e) {
    return false;
  }
}

module.exports = { isGhReadArgv };
