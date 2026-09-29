"use strict";
// hooks/bash-guard/readonly-class.js — the external read-only allow (#2403 N3/N4/N5).
//
// A plain command name whose class (install/readonly-command-classes.json) positively
// judges the argv read-only allows with that class's code. git/gh delegate to their own
// positive judges; every other entry goes through a syntax adapter. Reads of credential or
// dotenv paths never allow, whichever class matched; neither does any argument the shell
// would expand (glob, brace, variable, escape) nor a URL spelling (query/fragment suffix,
// percent-encoding) that resolves to such a path. Any doubt or exception is null.

const { resolveEffectiveSegment } = require("../lib/command-ir");
const { DEFAULT_ROOT, loadReadOnlyClasses } = require("../lib/readonly-command-classes");
const { getopt, find } = require("../lib/readonly-syntax-adapters");
const { isGitPureReadArgv } = require("../lib/bash-write-patterns/git-read-ir");
const { isGhReadArgv } = require("../lib/bash-write-patterns/gh-read");
const { commandTouchesCredentials, isCredentialGlobPattern } = require("../lib/credential-check");
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

const OPTION_LETTER_RE = /[A-Za-z0-9]/;
const DOUBLE_QUOTE_ACTIVE = "$`\\";
const UNQUOTED_ACTIVE = DOUBLE_QUOTE_ACTIVE + "*?[{";

// True when the shell would expand the raw token (variable, substitution, escape, glob,
// brace): the path it finally reads is then unknowable from the literal text.
function isShellExpanded(raw) {
  let quote = "";
  for (const ch of raw) {
    if (quote === "'") {
      if (ch === "'") quote = "";
    } else if (quote === '"') {
      if (ch === '"') quote = "";
      else if (DOUBLE_QUOTE_ACTIVE.includes(ch)) return true;
    } else if (ch === "'" || ch === '"') {
      quote = ch;
    } else if (UNQUOTED_ACTIVE.includes(ch)) {
      return true;
    }
  }
  return false;
}

const URL_SUFFIX_RE = /[?#]/;
const PERCENT_BYTE_RE = /%([0-9A-Fa-f]{2})/g;

// Every spelling a URL consumer (gh api) may resolve the value to: the part before the query
// or fragment, and its percent-decoded form. Byte-wise decoding never throws on a stray `%`
// (git log --format=%H), and both steps only shrink the string, so the closure terminates.
function urlSpellings(v) {
  const seen = new Set([v]);
  const queue = [v];
  while (queue.length > 0) {
    const s = queue.pop();
    const m = URL_SUFFIX_RE.exec(s);
    const next = [m ? s.slice(0, m.index) : s, s.replace(PERCENT_BYTE_RE, (_, h) => String.fromCharCode(parseInt(h, 16)))];
    for (const n of next) {
      if (!seen.has(n)) {
        seen.add(n);
        queue.push(n);
      }
    }
  }
  return [...seen];
}

function touchesSensitivePath(seg, argv) {
  const raws = seg.argvRaw;
  if (!Array.isArray(raws) || raws.length !== argv.length) return true;
  if (raws.some((r) => typeof r !== "string" || isShellExpanded(r))) return true;
  const texts = [[seg.cmd0, ...argv].join(" ")];
  if (typeof seg.rawText === "string" && seg.rawText !== "") texts.push(seg.rawText);
  const paths = [];
  // Wrap with a dummy cmd0 so the checkers see each as a path argument, not a command name.
  const addPath = (v) => {
    if (!v) return;
    for (const s of urlSpellings(v)) {
      if (!s) continue;
      texts.push("x " + s);
      paths.push(s);
    }
  };
  try {
    // Also check each token directly and path portions of revision/pathspec operands.
    // The direct per-token check bypasses TEXT_FLAGS consumption in checkBashCommand
    // (e.g., `git log -m .env` would silently consume `.env` as the -m value without it).
    for (const tok of argv) {
      addPath(tok);
      if (tok.startsWith("--")) {
        // --name=value: the value may be a path (--file=, --files0-from=).
        if (tok.includes("=")) addPath(tok.slice(tok.indexOf("=") + 1));
      } else if (tok.startsWith("-")) {
        // Attached short option value, bundled or not (-f.env, -bf.env): the value may start
        // after any option letter, so every suffix that follows a letter is a candidate.
        for (let i = 2; i < tok.length && OPTION_LETTER_RE.test(tok[i - 1]); i++) addPath(tok.slice(i));
      }
      // Extended pathspec magic :(magic)path — extract the path portion after ")".
      if (tok.startsWith(":(") && tok.includes(")")) addPath(tok.slice(tok.indexOf(")") + 1));
      // Plain colon-separated rev:path forms (e.g., HEAD:.env, :0:.env).
      const c = tok.lastIndexOf(":");
      if (c >= 0) addPath(tok.slice(c + 1));
    }
  } catch (_e) {
    return true;
  }
  // The root-anchored check only knows ~/, $HOME and /root; any other spelling of a home
  // (/c//Users/u, ~u, ../../Users/u, \\?\C:\Users\u) is caught by the credential directory
  // segment itself, whatever precedes it.
  return paths.some(isCredentialGlobPattern) || texts.some((t) => commandTouchesCredentials(t) || touchesDotenv(t));
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
