"use strict";
// hooks/bash-guard/readonly-class.js — the external read-only allow (#2403 N3/N4/N5).
//
// A plain command name whose class (install/readonly-command-classes.json) positively
// judges the argv read-only allows with that class's code. git/gh delegate to their own
// positive judges; every other entry goes through a syntax adapter. Reads of credential or
// dotenv paths never allow, whichever class matched. Any doubt or exception is null.

const { resolveEffectiveSegment } = require("../lib/command-ir");
const { DEFAULT_ROOT, loadReadOnlyClasses } = require("../lib/readonly-command-classes");
const { getopt, find } = require("../lib/readonly-syntax-adapters");
const { isGitPureReadArgv } = require("../lib/bash-write-patterns/git-read-ir");
const { isGhReadArgv } = require("../lib/bash-write-patterns/gh-read");
const { commandTouchesCredentials } = require("../lib/credential-check");
const { checkBashCommand: touchesDotenv } = require("../lib/dotenv-check");
const { isPlainSingleCommand } = require("./allow");
const { ALLOW_CODES } = require("./reasons");

const PATH_SEP_RE = /[\\/]/;
const EXE_SUFFIX_RE = /\.exe$/i;

const DELEGATES = Object.freeze({
  "git-pure-read": { judge: isGitPureReadArgv, code: ALLOW_CODES.READONLY_GIT },
  "gh-read": { judge: isGhReadArgv, code: ALLOW_CODES.READONLY_GH },
});
const ADAPTERS = Object.freeze({ getopt, find });

function isPlainName(seg) {
  const cmd0 = seg.cmd0;
  if (PATH_SEP_RE.test(cmd0) || PATH_SEP_RE.test(String(seg.cmd0Raw || ""))) return false;
  if (EXE_SUFFIX_RE.test(cmd0)) return false;
  const effective = resolveEffectiveSegment(seg);
  return Boolean(effective) && effective.cmd0 === cmd0;
}

// credential-check only knows the ~/, $HOME and /root roots, so an absolute home path of
// another user/OS (/home/u, /Users/u, C:\Users\u, /c/Users/u, /mnt/c/Users/u) is rewritten to ~/.
const ABS_HOME_RE = /^(?:[A-Za-z]:[\\/]Users[\\/]|\/mnt\/[A-Za-z]\/Users\/|\/[A-Za-z]\/Users\/|\/Users\/|\/home\/)[^\\/]+[\\/](.*)$/i;

function homeNormalizedPath(p) {
  const m = ABS_HOME_RE.exec(p);
  return m ? "~/" + m[1].replace(/\\/g, "/") : null;
}

function touchesSensitivePath(seg, argv) {
  const texts = [[seg.cmd0, ...argv].join(" ")];
  if (typeof seg.rawText === "string" && seg.rawText !== "") texts.push(seg.rawText);
  // Wrap with a dummy cmd0 so the checkers see each as a path argument, not a command name.
  const addPath = (v) => {
    if (!v) return;
    texts.push("x " + v);
    const home = homeNormalizedPath(v);
    if (home) texts.push("x " + home);
  };
  try {
    // Also check each token directly and path portions of revision/pathspec operands.
    // The direct per-token check bypasses TEXT_FLAGS consumption in checkBashCommand
    // (e.g., `git log -m .env` would silently consume `.env` as the -m value without it).
    for (const tok of argv) {
      addPath(tok);
      // Attached short option value: -f.env or -f/path — extract the suffix as a potential path.
      if (/^-[A-Za-z]./.test(tok)) addPath(tok.slice(2));
      // Extended pathspec magic :(magic)path — extract the path portion after ")".
      if (tok.startsWith(":(") && tok.includes(")")) addPath(tok.slice(tok.indexOf(")") + 1));
      // Plain colon-separated rev:path forms (e.g., HEAD:.env, :0:.env).
      const c = tok.lastIndexOf(":");
      if (c >= 0) addPath(tok.slice(c + 1));
    }
  } catch (_e) {
    return true;
  }
  return texts.some((t) => commandTouchesCredentials(t) || touchesDotenv(t));
}

function classOf(seg, argv, root) {
  const classes = loadReadOnlyClasses(root);
  const target = classes.delegate.get(seg.cmd0);
  if (target !== undefined) {
    const d = Object.prototype.hasOwnProperty.call(DELEGATES, target) ? DELEGATES[target] : null;
    return d && d.judge(argv, seg.argvRaw) === true ? d.code : null;
  }
  const entry = classes.generic.get(seg.cmd0);
  const adapter = entry && Object.prototype.hasOwnProperty.call(ADAPTERS, entry.syntax) ? ADAPTERS[entry.syntax] : null;
  return adapter && adapter(argv, entry) === true ? ALLOW_CODES.READONLY_GENERIC : null;
}

/**
 * Judges ONE segment. It does not look at separators, redirects or newlines: the caller
 * must hand it a segment that already stands alone (matchReadOnlyCommand does; #2404 will
 * pass each segment of a compound it has judged harmless).
 * @param {object} seg a command-ir SegmentIR
 * @param {{root?: string}} [opts] agents root override (fixture roots in tests)
 * @returns {string|null} an ALLOW_CODES value, or null
 */
function classifyReadOnlySegment(seg, opts) {
  try {
    if (!seg || typeof seg.cmd0 !== "string" || seg.cmd0 === "") return null;
    if (!isPlainName(seg)) return null;
    const argv = Array.isArray(seg.argv) ? seg.argv : [];
    if (!argv.every((t) => typeof t === "string")) return null;
    const root = opts && typeof opts.root === "string" && opts.root !== "" ? opts.root : DEFAULT_ROOT;
    const code = classOf(seg, argv, root);
    if (!code || touchesSensitivePath(seg, argv)) return null;
    return code;
  } catch (_e) {
    return null;
  }
}

/**
 * @param {object} ir parse()'s output
 * @param {object} [_ctx] judge context (unused; kept symmetric with matchSelfScript)
 * @param {{root?: string}} [opts] agents root override
 * @returns {string|null} an ALLOW_CODES value, or null
 */
function matchReadOnlyCommand(ir, _ctx, opts) {
  try {
    const seg = isPlainSingleCommand(ir);
    return seg ? classifyReadOnlySegment(seg, opts) : null;
  } catch (_e) {
    return null;
  }
}

module.exports = { classifyReadOnlySegment, matchReadOnlyCommand };
