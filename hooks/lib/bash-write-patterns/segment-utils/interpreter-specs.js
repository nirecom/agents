"use strict";

// Which command names carry an INLINE PROGRAM BODY on their argv, how each
// spells the flag that introduces it, and how to pull that body back out.

// Text that cannot be resolved statically (expansion / substitution).
const UNRESOLVABLE_RE = /[$`(]/;

// `attachedBody`: the single-dash cluster's remainder is itself the body
// (`python -cCODE`). Shells clear it — their remainder is more option LETTERS
// (`sh -ce CMD` runs CMD, not "e").
const SHELL_BODY_SPEC = {
  kind: "shell", lang: null,
  bodyLetters: new Set(["c"]), longFlags: new Set(["--command"]), attachedBody: false,
};

// Bundling rules differ per language, so each declares its own body letters
// rather than reusing the shell's `c`.
const LANG_SPECS = {
  python: { kind: "language", lang: "python", bodyLetters: new Set(["c"]), longFlags: new Set(), attachedBody: true },
  perl: { kind: "language", lang: "perl", bodyLetters: new Set(["e", "E"]), longFlags: new Set(), attachedBody: true },
  ruby: { kind: "language", lang: "ruby", bodyLetters: new Set(["e"]), longFlags: new Set(["--eval"]), attachedBody: true },
  node: { kind: "language", lang: "node", bodyLetters: new Set(["e", "p"]), longFlags: new Set(["--eval", "--print"]), attachedBody: true },
};

// Mirrors BODY_FIRST_INTERPRETER_NAMES in block-clearance-token-write/
// interpreter-scan.js: each runs an inline one-liner that can shell out, so a
// recursive delete hides in one exactly as in `python -c` (CPR-ORTH).
const langFlagSpec = (lang, letters, longFlags) => ({
  kind: "language", lang,
  bodyLetters: new Set(letters), longFlags: new Set(longFlags || []), attachedBody: true,
});

const BODY_FLAG_LANG_SPECS = {
  php: langFlagSpec("php", ["r"]),
  lua: langFlagSpec("lua", ["e"]),
  r: langFlagSpec("r", ["e"]),
  osascript: langFlagSpec("osascript", ["e"]),
  expect: langFlagSpec("expect", ["c"]),
  tcl: langFlagSpec("tcl", ["c"]),
};

// awk takes its PROGRAM as the first positional, with no flag at all; `-f
// progfile` loads it from a FILE instead, so that form has no inline body.
const AWK_SPEC = {
  kind: "language", lang: "awk", bodyFirst: true,
  valueFlags: new Set(["-F", "-v", "-f"]),
  programFileFlags: new Set(["-f", "--file", "--exec"]),
  bodyLongFlags: new Set(["--source"]),
};

// Every inline body `spec`'s interpreter would run, given the argv FOLLOWING its
// name. Both readings of an attached cluster are returned (`node -pe CODE` vs
// `python -cCODE`) so neither is lost to a guess.
function interpreterInlineBodies(spec, argv) {
  const toks = Array.isArray(argv) ? argv : [];
  const bodies = [];
  for (let i = 0; i < toks.length; i++) {
    const tok = toks[i];
    if (typeof tok !== "string" || tok[0] !== "-" || tok === "-" || tok === "--") continue;
    const next = typeof toks[i + 1] === "string" ? toks[i + 1] : null;
    if (tok[1] === "-") {
      const eq = tok.indexOf("=");
      if (!spec.longFlags.has((eq === -1 ? tok : tok.slice(0, eq)).toLowerCase())) continue;
      if (eq !== -1) bodies.push(tok.slice(eq + 1));
      else if (next !== null) bodies.push(next);
      break;
    }
    const letters = [...tok.slice(1)];
    if (!spec.attachedBody) {
      if (!/^[A-Za-z]+$/.test(tok.slice(1))) continue;
      if (!letters.some((ch) => spec.bodyLetters.has(ch))) continue;
      if (next !== null) bodies.push(next);
      break;
    }
    const k = letters.findIndex((ch) => spec.bodyLetters.has(ch));
    if (k === -1) continue;
    const attached = letters.slice(k + 1).join("");
    if (attached !== "") bodies.push(attached);
    if (next !== null) bodies.push(next);
    break;
  }
  return bodies;
}

// Body-first reading: skip the interpreter's options — consuming separated
// values so the program is not mistaken for one — then take the first positional.
function bodyFirstInlineBodies(spec, argv) {
  const toks = Array.isArray(argv) ? argv : [];
  for (let i = 0; i < toks.length; i++) {
    const tok = toks[i];
    if (typeof tok !== "string" || tok === "") return [];
    if (tok === "--") return typeof toks[i + 1] === "string" ? [toks[i + 1]] : [];
    if (tok[0] !== "-") return [tok];
    const eq = tok.indexOf("=");
    const name = eq === -1 ? tok : tok.slice(0, eq);
    if (spec.programFileFlags.has(name)) return [];
    if (spec.bodyLongFlags.has(name) && eq !== -1) return [tok.slice(eq + 1)];
    if (eq === -1 && spec.valueFlags.has(tok)) i += 1;
  }
  return [];
}

// `pwsh -EncodedCommand <base64>` runs a BASE64 UTF-16LE script; null means
// undecodable and the caller fails closed (#2210).
function decodeEncodedCommand(tok) {
  if (typeof tok !== "string" || tok === "") return null;
  if (UNRESOLVABLE_RE.test(tok)) return null;
  if (!/^[A-Za-z0-9+/=]+$/.test(tok)) return null;
  try {
    const decoded = Buffer.from(tok, "base64").toString("utf16le");
    return decoded === "" ? null : decoded;
  } catch (e) {
    return null;
  }
}

// `-Command`/`-EncodedCommand`, or any case-insensitive prefix (`-c`, `-enc`).
// `-Command` consumes ALL remaining arguments as ONE script — reading only the
// next token let `pwsh -Command Remove-Item -Recurse d` pass as a bare
// `Remove-Item` (#2210).
function pwshInterpreterBodies(argv) {
  const toks = Array.isArray(argv) ? argv : [];
  for (let i = 0; i < toks.length; i++) {
    const tok = toks[i];
    if (typeof tok !== "string" || !tok.startsWith("-")) continue;
    const name = tok.slice(1).toLowerCase();
    if (name === "") continue;
    if ("command".startsWith(name)) {
      const rest = toks.slice(i + 1).filter((t) => typeof t === "string");
      // `-Command -` is a stdin marker, not a one-character body: reporting no
      // inline body hands it to the stdin-delivery path instead (#2210).
      const isStdinMarker = rest.length === 1 && rest[0] === "-";
      return rest.length === 0 || isStdinMarker ? [] : [{ kind: "shell", body: rest.join(" ") }];
    }
    if ("encodedcommand".startsWith(name)) {
      const decoded = decodeEncodedCommand(i + 1 < toks.length ? toks[i + 1] : null);
      return [decoded === null ? { kind: "unresolvable" } : { kind: "shell", body: decoded }];
    }
  }
  return [];
}

const PWSH_BODY_SPEC = { kind: "shell", lang: null, inlineBodies: pwshInterpreterBodies };

const INTERPRETER_SPECS = new Map([
  ...["bash", "sh", "zsh", "dash", "ksh", "ash", "hush", "mksh", "yash", "fish", "tcsh", "csh"]
    .map((n) => [n, SHELL_BODY_SPEC]),
  ["python", LANG_SPECS.python], ["python2", LANG_SPECS.python], ["python3", LANG_SPECS.python],
  ["perl", LANG_SPECS.perl], ["ruby", LANG_SPECS.ruby],
  ["node", LANG_SPECS.node], ["nodejs", LANG_SPECS.node], ["bun", LANG_SPECS.node],
  ["pwsh", PWSH_BODY_SPEC], ["powershell", PWSH_BODY_SPEC],
  ["php", BODY_FLAG_LANG_SPECS.php],
  ["lua", BODY_FLAG_LANG_SPECS.lua], ["luajit", BODY_FLAG_LANG_SPECS.lua],
  ["rscript", BODY_FLAG_LANG_SPECS.r], ["r", BODY_FLAG_LANG_SPECS.r],
  ["osascript", BODY_FLAG_LANG_SPECS.osascript],
  ["expect", BODY_FLAG_LANG_SPECS.expect],
  ["tclsh", BODY_FLAG_LANG_SPECS.tcl], ["wish", BODY_FLAG_LANG_SPECS.tcl],
  ...["awk", "gawk", "mawk", "nawk"].map((n) => [n, AWK_SPEC]),
]);

// Deliberately unmodeled: `deno eval CODE` (a SUBCOMMAND — a body-first reading
// would take the word "eval" as the program) and `busybox-awk`. Enumeration
// lags by nature; the structural checks are the backstop.

// Single entry point, so no caller has to know which of the three extraction
// shapes its spec declares. Kind "unresolvable" carries no body.
function interpreterFoundBodies(spec, argv) {
  if (typeof spec.inlineBodies === "function") return spec.inlineBodies(argv);
  const bodies = spec.bodyFirst ? bodyFirstInlineBodies(spec, argv) : interpreterInlineBodies(spec, argv);
  return bodies.map((body) => ({ kind: spec.kind, lang: spec.lang, body }));
}

module.exports = {
  UNRESOLVABLE_RE,
  INTERPRETER_SPECS,
  PWSH_BODY_SPEC,
  interpreterInlineBodies,
  interpreterFoundBodies,
  pwshInterpreterBodies,
  decodeEncodedCommand,
};
