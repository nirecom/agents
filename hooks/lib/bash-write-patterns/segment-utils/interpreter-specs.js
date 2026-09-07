"use strict";

// Which command names carry an INLINE PROGRAM BODY on their argv, how each
// spells the flag that introduces it, and how to pull that body back out.
// Split out of segment-utils.js when the interpreter table pushed it past the
// 500-line hard limit (rules/coding/file-split.md); the parent keeps the
// wrapper-peel half and re-exports this one, so INTERPRETER_SPECS still has a
// single owner (CPR-SSOT) shared by the mid-argv scanWrappedInterpreter net and
// the recursive-delete scan's effective-command path.

// Text that cannot be resolved statically (expansion / substitution).
const UNRESOLVABLE_RE = /[$`(]/;

// `kind` tells the caller how to judge the body ("shell" = command text,
// "language" = source); `bodyLetters` are the short-option letters that
// introduce it inside a single-dash cluster; `attachedBody` says whether the
// cluster's remainder is itself the body (`python -cCODE`, `perl -e'CODE'`).
// POSIX shells clear attachedBody because their cluster remainder is more
// option LETTERS (`sh -ce CMD` runs CMD, not "e"). fish/tcsh/csh join the shell
// set: each takes one command STRING after `-c` exactly as sh does.
const SHELL_BODY_SPEC = {
  kind: "shell", lang: null,
  bodyLetters: new Set(["c"]), longFlags: new Set(["--command"]), attachedBody: false,
};

// Per-language bundling rules differ, so each declares its own body letters
// rather than reusing the shell's `c`: python bundles boolean flags ahead of
// `-c` (`-uc CODE`), perl ahead of `-e` (`-le CODE`), node clusters `-pe` and
// also accepts `--eval=CODE` with the value attached by `=`.
const LANG_SPECS = {
  python: { kind: "language", lang: "python", bodyLetters: new Set(["c"]), longFlags: new Set(), attachedBody: true },
  perl: { kind: "language", lang: "perl", bodyLetters: new Set(["e", "E"]), longFlags: new Set(), attachedBody: true },
  ruby: { kind: "language", lang: "ruby", bodyLetters: new Set(["e"]), longFlags: new Set(["--eval"]), attachedBody: true },
  node: { kind: "language", lang: "node", bodyLetters: new Set(["e", "p"]), longFlags: new Set(["--eval", "--print"]), attachedBody: true },
};

// The second family the sibling guard block-clearance-token-write/
// interpreter-scan.js already enumerates (BODY_FIRST_INTERPRETER_NAMES): each
// runs an inline one-liner and each can shell out, so a recursive delete hides
// in one exactly as it does in `python -c`. Modeled here so the same body
// reaches the delete-shape matcher (CPR-ORTH). None declares its own delete
// SHAPES beyond the shell spellings except `r` and `tcl` — see
// LANGUAGE_DELETE_SHAPES in recursive-delete-scan/interpreter-bodies.js.
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

// awk reads its PROGRAM from the first positional argument, with no flag at all
// — `awk 'BEGIN{system("rm -rf d")}'`. `-f progfile` loads the program from a
// FILE instead, so that form carries no inline body to scan.
const AWK_SPEC = {
  kind: "language", lang: "awk", bodyFirst: true,
  valueFlags: new Set(["-F", "-v", "-f"]),
  programFileFlags: new Set(["-f", "--file", "--exec"]),
  bodyLongFlags: new Set(["--source"]),
};

/**
 * interpreterInlineBodies(spec, argv) — every inline body `spec`'s interpreter
 * would run, given the argv that FOLLOWS its name. Both readings of an attached
 * cluster are returned (`node -pe CODE` clusters two body letters and takes the
 * next word; `python -cCODE` glues the body on) — the caller judges each, so
 * neither reading can be lost to a guess.
 */
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

// The body-first reading: skip the interpreter's own options, then take the
// first remaining positional as the program. An option whose value follows as a
// separate token consumes it so the program is not mistaken for that value; a
// program-FILE flag means there is no inline body at all.
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

// `pwsh -EncodedCommand <base64>` runs a BASE64 UTF-16LE script, so the token is
// decoded before it can be scanned. Anything that cannot be decoded statically
// returns null and the caller fails closed (#2210 round-4 C3).
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

// PowerShell's own inline-body flags: `-Command`/`-EncodedCommand` or any
// case-insensitive prefix of either (`-c`, `-Comm`, `-enc`). `-Command` consumes
// ALL remaining arguments and joins them into ONE script — reading only the next
// token left `pwsh -Command Remove-Item -Recurse d` looking like a bare
// `Remove-Item`, which approved (#2210 round-6). `-EncodedCommand` keeps its
// single-token payload, decoded above; anything undecodable yields
// "unresolvable" so the caller fails closed.
function pwshInterpreterBodies(argv) {
  const toks = Array.isArray(argv) ? argv : [];
  for (let i = 0; i < toks.length; i++) {
    const tok = toks[i];
    if (typeof tok !== "string" || !tok.startsWith("-")) continue;
    const name = tok.slice(1).toLowerCase();
    if (name === "") continue;
    if ("command".startsWith(name)) {
      const rest = toks.slice(i + 1).filter((t) => typeof t === "string");
      // `-Command -` is PowerShell's own stdin marker (like bash's `-s`), not a
      // literal one-character script body — treating it as inline text let the
      // real script arrive via stdin unscanned (`echo 'Remove-Item -Recurse d'
      // | pwsh -Command -`, #2210 security-scanner C26). Report no inline body
      // so the stdin-delivery path picks it up instead.
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

// Still NOT modeled, deliberately: `deno eval CODE` (a SUBCOMMAND, not a flag —
// a body-first reading would take the word "eval" as the program), and
// `busybox awk`/`busybox-awk` (busybox is peeled as a WRAPPER, so its applet
// resolves to a plain `awk` only in the peeled form). Both are enumeration
// gaps, and enumeration inherently lags — the structural checks are the backstop.

// The one entry point every caller uses, so no caller has to know which of the
// three extraction shapes its spec declares. Returns {kind, lang, body} entries
// (kind "unresolvable" carries no body).
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
