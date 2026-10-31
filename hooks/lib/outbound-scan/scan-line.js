"use strict";
// One line through the outbound checks, in the order and with the match text bash scan_line
// used: IPv4 loop, email, MAC, path, msys, wsl, hard secrets, zero-width, bidi, blocklist
// hard, blocklist warn. Every ERE (built-in and list) goes through the shared ERE layer.
// compileScanner({allow, blockHard, blockWarn}, hardSecrets) -> { scanLine } | { incomplete }

const { translateEre } = require("../ere/translate");
const { leftmostLongest } = require("../ere/longest");
const { globMatch } = require("./glob");

const BS = "\\";
const SL = "/";

function builtin(ere) {
  const r = translateEre(ere);
  if (r.status !== "ok") throw new Error(`built-in ERE does not translate: ${r.reason}`);
  return r.regex;
}

const IPV4 = [
  `10${BS}.[0-9]{1,3}${BS}.[0-9]{1,3}${BS}.[0-9]{1,3}`,
  `172${BS}.(1[6-9]|2[0-9]|3[01])${BS}.[0-9]{1,3}${BS}.[0-9]{1,3}`,
  `192${BS}.168${BS}.[0-9]{1,3}${BS}.[0-9]{1,3}`,
].map(builtin);
const EMAIL = builtin(`[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+${BS}.[a-zA-Z]{2,}`);
const MAC = builtin("([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}");
const NAME = "[a-zA-Z][a-zA-Z0-9_.-]*";
const PATHS = [
  `${SL}Users${SL}${NAME}`,
  `${SL}home${SL}${NAME}`,
  `[A-Z]:${BS}${BS}Users${BS}${BS}${NAME}`,
  `[A-Z]:${SL}Users${SL}${NAME}`,
].map(builtin);
const LINUXBREW = builtin(["", "home", "linuxbrew"].join(SL));
const MSYS = builtin(`(^|[^[:alnum:]_${SL}])${SL}[a-z]${SL}[[:alnum:]_.-]`);
const WSL = builtin(`(^|[^[:alnum:]_${SL}])${SL}mnt${SL}[a-z]${SL}[[:alnum:]_.-]`);
const ZERO_WIDTH = new RegExp("[\\u200b-\\u200d\\ufeff]", "u");
const BIDI = new RegExp("[\\u202d\\u202e\\u2066-\\u2069]", "u");
const HIDDEN_TEXT = "<hidden char>";

// List ERE -> RegExp, or null for an ERE bash rejects (it never matches there either).
function listRegex(ere) {
  const r = translateEre(ere);
  if (r.status === "untranslatable") {
    const err = new Error(`list pattern has no JS form (${r.reason})`);
    err.untranslatable = true;
    throw err;
  }
  return r.status === "ok" ? r.regex : null;
}

function compileAllow(pattern) {
  const colon = pattern.indexOf(":");
  if (colon < 0) return { glob: null, re: listRegex(pattern) };
  return { glob: pattern.slice(0, colon), re: listRegex(pattern.slice(colon + 1)) };
}

const removeFirst = (s, sub) => {
  const i = s.indexOf(sub);
  return i < 0 ? s : s.slice(0, i) + s.slice(i + sub.length);
};

function compileScanner(lists, hardSecrets) {
  let allow;
  let blockHard;
  let blockWarn;
  let secrets;
  try {
    allow = lists.allow.map(compileAllow);
    blockHard = lists.blockHard.map(listRegex);
    blockWarn = lists.blockWarn.map(listRegex);
    secrets = hardSecrets.map((h) => ({ ...h, re: listRegex(h.ere) }));
  } catch (e) {
    if (e.untranslatable) return { incomplete: { reason: e.message } };
    throw e;
  }

  const isAllowed = (file, matched) => allow.some((a) => a.re !== null && (a.glob === null || globMatch(a.glob, file)) && a.re.test(matched));
  const longest = (re, s) => {
    const m = leftmostLongest(re, s);
    return m ? m.text : null;
  };

  function scanLine(file, lineno, line) {
    const out = [];
    const report = (kind, group, matched, allowSubject, severity = "hard") => {
      if (!isAllowed(file, allowSubject)) out.push({ file, line: lineno, kind, group, matched, severity });
    };
    for (const re of IPV4) {
      let tmp = line;
      for (let ip = longest(re, tmp); ip !== null; ip = longest(re, tmp)) {
        report("IPv4", "builtin", ip, ip);
        tmp = removeFirst(tmp, ip);
      }
    }
    const email = longest(EMAIL, line);
    if (email !== null) report("email", "builtin", email, email);
    const mac = longest(MAC, line);
    if (mac !== null) report("MAC", "builtin", mac, mac);
    const pathRe = PATHS.find((re) => re.test(line));
    if (pathRe && !LINUXBREW.test(line)) {
      const p = longest(pathRe, line);
      report("path", "builtin", p, p);
    }
    const msys = longest(MSYS, line);
    if (msys !== null) report("msys-path", "builtin", msys, line);
    const wsl = longest(WSL, line);
    if (wsl !== null) report("wsl-path", "builtin", wsl, line);
    let workGroup = "";
    let workLine = "";
    for (const h of secrets) {
      if (h.re === null) continue;
      if (h.group !== "-" && h.group !== workGroup) {
        workGroup = h.group;
        workLine = line;
      }
      const m = longest(h.re, h.group === "-" ? line : workLine);
      if (m === null) continue;
      report(h.label, "hard-secret", m, m);
      if (h.group !== "-") workLine = removeFirst(workLine, m);
    }
    if (ZERO_WIDTH.test(line)) report("zero-width", "hidden", HIDDEN_TEXT, line);
    if (BIDI.test(line)) report("bidi-override", "hidden", HIDDEN_TEXT, line);
    for (const re of blockHard) {
      const m = re === null ? null : longest(re, line);
      if (m !== null) report("blocklist", "blocklist", m, m);
    }
    for (const re of blockWarn) {
      const m = re === null ? null : longest(re, line);
      if (m !== null) report("blocklist-warn", "blocklist", m, m, "warn");
    }
    return out;
  }

  return { scanLine };
}

module.exports = { compileScanner };
