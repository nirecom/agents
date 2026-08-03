// hooks/block-off-clearance-write/interpreter-scan.js
// Interpreter-one-liner analysis, split out of the entrypoint (file-split,
// rules/coding/file-split.md). Tier-1 gate and Tier-2 prefilter recognize
// protected session markers as well as the clearance token, via the shared
// SSOT in hooks/lib/protected-basenames.js (CPR-5).
"use strict";

const { mentionsProtectedName, TOKEN_MENTION_RE } = require("../lib/protected-basenames");
const { ci, PWSH_ENV_PREFIX } = require("../lib/case-insensitive-literal");

// vector2 heuristic (best-effort, deliberately incomplete): an interpreter
// one-liner whose body mentions the clearance-token name. Covers POSIX shells
// (`bash -c`, `sh -ec`, clustered/abbreviated flags like `pwsh -Comm`) as well
// as scripting languages — INTERPRETER_RE and the Tier-2 flagRe extractor MUST
// recognize the same flag shapes, or one fails open. Interpreter names and
// pwsh parameter names fold case (Windows exec lookup / PowerShell semantics);
// POSIX short flags stay case-sensitive (`sh -C` is noclobber, not `-c`).

// Split by EXECUTION MODEL: a shell reads shell text (recursed by
// ./nested-bodies.js); a language interpreter reads its own language, judged
// by interpreterBodyHitsProtected() below.
const LANGUAGE_INTERPRETER_NAMES = [
  "node", "nodejs", "python", "python3", "perl", "ruby", "deno", "bun",
  "pwsh", "powershell",
];
const SHELL_INTERPRETER_NAMES = ["bash", "sh", "zsh", "dash", "busybox"];
const INTERPRETER_NAMES = LANGUAGE_INTERPRETER_NAMES.concat(SHELL_INTERPRETER_NAMES);
const LANGUAGE_INTERPRETER_SET = new Set(LANGUAGE_INTERPRETER_NAMES);
const SHELL_INTERPRETER_SET = new Set(SHELL_INTERPRETER_NAMES);

// interpreterKindOfWord(word): "language" | "shell" | null for one command word.
// Case- and path-insensitive, and `.exe`-tolerant, for the same reason
// INTERPRETER_RE folds case (Windows executable lookup).
function commandBaseName(word) {
  if (typeof word !== "string" || word === "") return "";
  return word.replace(/\\/g, "/").split("/").pop().toLowerCase().replace(/\.exe$/, "");
}
function interpreterKindOfWord(word) {
  const base = commandBaseName(word);
  if (base === "") return null;
  if (LANGUAGE_INTERPRETER_SET.has(base)) return "language";
  if (SHELL_INTERPRETER_SET.has(base)) return "shell";
  return null;
}
// The pwsh family is split out of the language family because its PARAMETER
// NAMES are its own: `-Command` / `-EncodedCommand` prefixes are program flags
// for pwsh and meaningless everywhere else.
const PWSH_INTERPRETER_NAMES = ["pwsh", "powershell"];
const PWSH_INTERPRETER_SET = new Set(PWSH_INTERPRETER_NAMES);
function isPwshWord(word) {
  return PWSH_INTERPRETER_SET.has(commandBaseName(word));
}
const INTERPRETER_NAME_ALTS = INTERPRETER_NAMES.map(ci).join("|");
const CLUSTER_FLAG = String.raw`-[A-Za-z]{0,2}[ce][A-Za-z]{0,2}`;
const LONG_FLAG = String.raw`--(?:eval|${ci("command")}|${ci("encoded-command")})`;
// Progressive optional-letter chain: matches every unambiguous minimal
// prefix of "Command" (C, Co, Com, ... Command) / "EncodedCommand" (E, En,
// Enc, ... EncodedCommand) that pwsh accepts — in any casing, as pwsh does.
const L = (c, inner) => (inner ? `${ci(c)}(?:${inner})?` : ci(c));
const PWSH_COMMAND_PREFIX = L("C", L("o", L("m", L("m", L("a", L("n", L("d")))))));
const PWSH_ENCCMD_PREFIX = L("E", L("n", L("c", L("o", L("d", L("e", L("d", L("C", L("o", L("m", L("m", L("a", L("n", L("d")))))))))))))); // eslint-disable-line
const FLAG_ALTS = String.raw`${CLUSTER_FLAG}\b|${LONG_FLAG}\b|-{1,2}(?:${PWSH_COMMAND_PREFIX}|${PWSH_ENCCMD_PREFIX})\b`;
const INTERPRETER_RE = new RegExp(
  String.raw`\b(${INTERPRETER_NAME_ALTS})\b[^\n]*\s(?:${FLAG_ALTS})`
);

// ---------------------------------------------------------------------------
// PROOF that the program is on argv (word-level): clears a stdin-program route
// in ./nested-bodies.js. Unlike FLAG_ALTS (extraction — wide is safe, since
// over-matching just makes Tier 2 read more text), this set grants PERMISSION,
// so over-matching is a bypass: reusing FLAG_ALTS's pwsh `-E`/EncodedCommand
// prefix here once let `printf '<program>' | python3 -E -` (ignore-env, read
// stdin) go ALLOW. Short clusters stay lowercase-only, pwsh parameter names
// count only when cmd0 is actually pwsh, and ambiguous flags (`-E`, `-p`,
// `--print`) are omitted (CPR-8) — doubt always resolves toward over-block.
// `(?:=|$)` accepts the attached long form (`--eval=code`) too.
// ---------------------------------------------------------------------------
const PROOF_CLUSTER_FLAG = String.raw`-[a-z]{0,2}[ce][a-z]{0,2}`;
const PROOF_LONG_FLAG = String.raw`--eval`;
const PWSH_ENCCMD_PROOF_PREFIX = `${ci("E")}${ci("n")}(?:${L("c", L("o", L("d", L("e", L("d", L("C", L("o", L("m", L("m", L("a", L("n", L("d"))))))))))))})?`; // eslint-disable-line
const PWSH_PROOF_FLAG = String.raw`-{1,2}(?:${PWSH_COMMAND_PREFIX}|${PWSH_ENCCMD_PROOF_PREFIX})`;
const GENERIC_PROOF_ALTS = String.raw`${PROOF_CLUSTER_FLAG}|${PROOF_LONG_FLAG}`;
const GENERIC_INLINE_PROGRAM_FLAG_RE = new RegExp(String.raw`^(?:${GENERIC_PROOF_ALTS})(?:=|$)`);
const PWSH_INLINE_PROGRAM_FLAG_RE = new RegExp(String.raw`^(?:${PWSH_PROOF_FLAG})(?:=|$)`);
// The union of both halves — the whole vocabulary of proof, for callers that
// only want to know whether a word is a program flag AT ALL (the unit probe).
// Anything making a permission decision must call inlineProgramFlagProof()
// instead, so the pwsh half stays scoped to pwsh.
const INLINE_PROGRAM_FLAG_RE = new RegExp(
  String.raw`^(?:${GENERIC_PROOF_ALTS}|${PWSH_PROOF_FLAG})(?:=|$)`
);

// inlineProgramFlagProof(word, interpreterWord): the kind-scoped predicate.
function inlineProgramFlagProof(word, interpreterWord) {
  if (typeof word !== "string" || word === "") return false;
  if (GENERIC_INLINE_PROGRAM_FLAG_RE.test(word)) return true;
  return isPwshWord(interpreterWord) && PWSH_INLINE_PROGRAM_FLAG_RE.test(word);
}

// INTERPRETER_RE requires a `-c`/`-e`-family flag, but a family of interpreters
// (awk, php -r, lua -e, tclsh, env -S ...) reads its program from argv[0] with
// no flag at all — `awk 'BEGIN{...}'` was a measured one-line write bypassing
// the whole hook. These are matched on NAME ALONE, arming Tier 1; Tier 2 then
// finds no extractable body and fails closed, which is correct since none has
// a recognized read-only shape. This is enumeration and inherently lags — the
// real backstops are the structural, name-independent checks elsewhere (CPR-8).
const BODY_FIRST_INTERPRETER_NAMES = [
  "awk", "gawk", "mawk", "nawk", "busybox-awk",
  "tclsh", "wish", "php", "lua", "luajit", "rscript", "osascript", "expect",
  "env", "xargs",
];
// Anchored at COMMAND POSITION (start of the segment, or just after a
// separator), not with a bare `\b`: `env` and `xargs` are ordinary substrings of
// `process.env` / `$env:` / `os.environ`, and a `\b` match there would arm the
// Tier-1 gate for every node or pwsh body that reads an environment variable.
const BODY_FIRST_INTERPRETER_RE = new RegExp(
  String.raw`(?:^|[\s;&|(])(?:${BODY_FIRST_INTERPRETER_NAMES.map(ci).join("|")})\b`
);

// looksLikeInterpreterInvocation(text): either recognized shape.
function looksLikeInterpreterInvocation(text) {
  return INTERPRETER_RE.test(text) || BODY_FIRST_INTERPRETER_RE.test(text);
}

// READ must not be blocked, but "not a write" is undecidable inside an
// arbitrary interpreter body (execSync / os.system / Path.touch / Deno.* / ...
// all write without naming any enumerable write verb). So the classification is
// inverted: only a SHORT LIST of fully-anchored read-only shapes is recognized,
// and everything else — including anything unparsable — is treated as a write.
// Plain shell reads (cat / Get-Content / ls / type) never reach this function:
// they produce no write target and do not match INTERPRETER_RE.

// (C3) Interpolation / escape guard: "inside quotes" is NOT inert — pwsh "..."
// interpolates $(...)/$var (` escapes), node `...` interpolates ${...}, python
// f-strings interpolate {...}. Any of these is rejected before shape matching
// (a crafted `Get-Content "$(Remove-Item ...)"` can't present as read-only).
// Accepted consequence: paths must use forward slashes or $env:/process.env.
//
// Bare `$NAME` guard: the hook sees the command text BEFORE shell expansion, so
// an unbraced variable (`$P`) is still live danger even though it looks inert
// statically. Any bare `$` fails closed UNLESS it starts the one sanctioned,
// validated token: pwsh `$env:VAR` (case-insensitive prefix, PWSH_ENV below,
// SSOT in hooks/lib/case-insensitive-literal.js) — node/python env access
// doesn't start with `$` so is unaffected.
const INTERPOLATION_RE = new RegExp(String.raw`[\x60\\]|\$(?!${PWSH_ENV_PREFIX})|@\(|\bf['"]`);

// Language-specific literal grammars. Single-quoted strings never interpolate in
// node / python / PowerShell, so they are the one form shared by all three.
const SQ        = String.raw`'[^'\\]*'`;
// Double quotes are inert in node/python only, and only with no $ / ` / \ inside.
const DQ_INERT  = String.raw`"[^"$\\\x60]*"`;
const NODE_ENV  = String.raw`process\.env\.[A-Za-z_][A-Za-z0-9_]*`;
const PY_ENV    = String.raw`os\.environ\[(?:${SQ}|${DQ_INERT})\]`;
// The `env:` scope prefix is case-insensitive (PowerShell); the VARIABLE NAME
// after it is left case-sensitive on purpose — env-var names are not folded by
// this scanner anywhere else either.
const PWSH_ENV  = String.raw`\$${PWSH_ENV_PREFIX}[A-Za-z_][A-Za-z0-9_]*`;

// One or more alternatives joined by `+` (string concatenation).
const concatOf = (...alts) => {
  const a = `(?:${alts.join("|")})`;
  return `${a}(?:\\s*\\+\\s*${a})*`;
};
const NODE_PATH_ARG = concatOf(SQ, DQ_INERT, NODE_ENV);
const PY_PATH_ARG   = concatOf(SQ, DQ_INERT, PY_ENV);
// pwsh: NO double-quoted form at all — PowerShell interpolates inside "...".
const PWSH_PATH_ARG = concatOf(SQ, PWSH_ENV);

// Extension rule: add a shape ONLY when it is fully anchored, side-effect free,
// and its argument grammar is provably inert IN THAT LANGUAGE. When adding a new
// language, first determine which of its quote forms interpolate and define a
// fresh PATH_ARG for it — never reuse an existing one. Missing entries fail
// toward block (safe), so when in doubt do not add.
const READONLY_BODY_SHAPES = [
  // node / deno / bun: print the contents / existence / listing of one path
  new RegExp(String.raw`^\s*(?:console\.log|process\.stdout\.write)\(\s*(?:require\((?:'fs'|"fs")\)|fs)\.(?:readFileSync|existsSync|readdirSync|statSync)\(\s*${NODE_PATH_ARG}\s*(?:,\s*(?:'utf8'|"utf8"))?\s*\)[^()]*\)\s*;?\s*$`),
  // python: print(open(p).read())
  new RegExp(String.raw`^\s*print\(\s*open\(\s*${PY_PATH_ARG}\s*\)\.read\(\)\s*\)\s*;?\s*$`),
  // pwsh: Get-Content [-Raw] <path>. PowerShell cmdlet/parameter names are
  // case-insensitive, so canonical-case-only matching fail-closed BLOCKED
  // legit spellings like `get-content -raw` (a read-allow regression). The
  // path argument grammar itself stays as strict as before.
  new RegExp(String.raw`^\s*${ci("Get-Content")}\s+(?:${ci("-Raw")}\s+)?${PWSH_PATH_ARG}\s*$`),
];

// extractAllInterpreterBodies(text): every quoted body passed to -e/-c/-Command,
// plus invocationCount (total flags seen, quoted or not). The caller fail-
// closes on `invocationCount > bodies.length`: an unquoted or unmodeled-quote
// (e.g. ANSI-C `$'...'`) argument yields no body but must still count, since it
// can't be proven token-free. Extraction walks the string once per flag via
// scanQuotedBody() (no backtracking) to avoid a catastrophic-backtracking DoS.
// Operates on one shell segment at a time — never the whole command line.
// NOTE: this is a best-effort heuristic, not a proof — anything it cannot
// cleanly account for fails closed.
function scanQuotedBody(str, openIdx) {
  const q = str[openIdx];
  let i = openIdx + 1;
  let body = "";
  while (i < str.length) {
    const c = str[i];
    // Backslash-escape (bash/node/python) and backtick-escape (pwsh) both
    // consume the escape char plus the next char as one atomic unit, so a
    // quote immediately following either never terminates the body early.
    if ((c === "\\" || c === "`") && i + 1 < str.length) { body += c + str[i + 1]; i += 2; continue; }
    if (c === q) {
      if (str[i + 1] === q) { body += q + q; i += 2; continue; } // doubled-quote escape (pwsh)
      return { body, endIndex: i + 1 };
    }
    body += c;
    i++;
  }
  return null; // unterminated
}

function extractAllInterpreterBodies(text) {
  const bodies = [];
  let invocationCount = 0;
  // F-1: same flag-shape alternation as INTERPRETER_RE (FLAG_ALTS) — see the
  // comment above INTERPRETER_RE for why the two must never diverge.
  const flagRe = new RegExp(String.raw`\s(?:${FLAG_ALTS})\s+`, "g");
  let m;
  while ((m = flagRe.exec(text)) !== null) {
    invocationCount++;
    const argStart = flagRe.lastIndex;
    const ch = text[argStart];
    if (ch === "'" || ch === '"') {
      const scanned = scanQuotedBody(text, argStart);
      if (scanned) {
        bodies.push(scanned.body);
        flagRe.lastIndex = scanned.endIndex; // don't rescan flag-shaped text inside the body
        continue;
      }
    }
    // Unquoted or unterminated argument: not added to bodies, so it inflates
    // invocationCount past bodies.length and the caller fails closed.
  }
  return { bodies, flagCount: invocationCount };
}

function interpreterBodyIsRecognizedReadOnly(body) {
  if (INTERPOLATION_RE.test(body)) return false;     // (C3) interpolation → write
  return READONLY_BODY_SHAPES.some((re) => re.test(body));
}

// Closes an indirection class: a body that only dereferences an env var
// (`process.env.A`, `os.environ['A']`, `$env:A`, bash `$A`/`${A}`) never
// spells the token out, so the plain substring prefilter let a same-segment
// `A=<token> node -e "...process.env.A..."` through as "out of scope". For
// every env-var name the body dereferences, this looks for a same-segment (or
// contiguous preceding) `NAME=value` assignment and fails closed if that value
// carries the token. Only the pwsh `$env:` prefix folds case; other spellings
// and variable names stay case-sensitive. The trailing `\$\{?(...)\}?` alt is
// last so it never preempts the more specific `$env:NAME` alt.
const ENV_DEREF_NAME_RE = new RegExp(
  String.raw`process\.env\.([A-Za-z_][A-Za-z0-9_]*)|os\.environ\[\s*(?:'([A-Za-z_][A-Za-z0-9_]*)'|"([A-Za-z_][A-Za-z0-9_]*)")\s*\]|\$${PWSH_ENV_PREFIX}([A-Za-z_][A-Za-z0-9_]*)|\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?`,
  "g"
);

function bodyDerefsProtectedViaAssignment(body, gateText) {
  if (typeof gateText !== "string" || gateText === "") return false;
  ENV_DEREF_NAME_RE.lastIndex = 0;
  let m;
  while ((m = ENV_DEREF_NAME_RE.exec(body)) !== null) {
    const varName = m[1] || m[2] || m[3] || m[4] || m[5];
    if (!varName) continue;
    // Same `$env:` prefix handling as segmentArgvHitsProtectedArg in ./bash-scan.js.
    const assignRe = new RegExp("(?:^|[\\s;&|]|\\$" + PWSH_ENV_PREFIX + ")" + varName + "=(\\S+)", "m");
    const am = assignRe.exec(gateText);
    // A marker path assigned to the variable is the same class of
    // indirection as a token path (CPR-5).
    if (am && mentionsProtectedName(am[1])) return true;
  }
  return false;
}

// interpreterBodyHitsProtected(body, gateText): the verdict for ONE interpreter
// program body, whatever route delivered it. Hoisted into its own function so
// DELIVERY ROUTE and LANGUAGE JUDGEMENT are independent — previously reachable
// only via a `-c`/`-e`/`-Command` flag, so a body arriving via here-string/
// heredoc/pipe fell back to the shell scanner and was approved as an ordinary
// non-matching word. ./nested-bodies.js now reuses this one classifier
// (CPR-2/CPR-4).
function interpreterBodyHitsProtected(body, gateText) {
  if (typeof body !== "string" || body === "") return false;
  const scope = typeof gateText === "string" ? gateText : body;
  // Out of scope: the body neither names a protected path nor dereferences a
  // variable the surrounding text assigns one to.
  if (!mentionsProtectedName(body) && !bodyDerefsProtectedViaAssignment(body, scope)) return false;
  // In scope: approved only for an anchored, provably side-effect-free read
  // shape; everything else is a write until proven otherwise.
  return !interpreterBodyIsRecognizedReadOnly(body);
}

function hitsProtectedViaInterpreter(text, gateText) {
  if (gateText === undefined) gateText = text;
  if (!looksLikeInterpreterInvocation(text)) return false;
  // `text` is one shell segment, or the whole raw command as a fail-closed
  // fallback when segmentation wasn't possible. Two-tier gate: Tier 1
  // (`gateText`, this segment plus any contiguous preceding assignment-only
  // segments) approves immediately if no protected name appears anywhere in
  // it — without this, an unrelated command whose body outruns the anchored
  // extractor (`node -e "console.log(1)" > out.txt`) would fail-closed block
  // for no reason. The marker regex is anchored on the `.<kind>` basename tail
  // so ordinary repo paths never arm this gate.
  if (!mentionsProtectedName(gateText)) return false;
  // Tier 2 (body): the segment mentions a protected name, so extract every
  // interpreter body and re-check there. An opaque body (e.g. `node -e $BODY`)
  // hides its own reference and can't be cleared by substring prefilter, so
  // unextractable (or partially so — flagCount > bodies.length) fails closed.
  const { bodies, flagCount } = extractAllInterpreterBodies(text);
  if (bodies.length === 0 || flagCount > bodies.length) return true;
  // Every extracted body must be protected-name-free or a recognized read-only
  // shape. The prefilter tests each `body`, never the whole `cmd` — surrounding
  // shell text (e.g. a `cd` into a directory that happens to share the name)
  // would otherwise misclassify a body that never touches the token.
  for (const body of bodies) {
    if (interpreterBodyHitsProtected(body, gateText)) return true;
  }
  return false;
}

module.exports = {
  INTERPRETER_RE,
  INLINE_PROGRAM_FLAG_RE,
  inlineProgramFlagProof,
  isPwshWord,
  BODY_FIRST_INTERPRETER_RE,
  LANGUAGE_INTERPRETER_NAMES,
  SHELL_INTERPRETER_NAMES,
  interpreterKindOfWord,
  looksLikeInterpreterInvocation,
  TOKEN_MENTION_RE,
  extractAllInterpreterBodies,
  interpreterBodyIsRecognizedReadOnly,
  interpreterBodyHitsProtected,
  bodyDerefsProtectedViaAssignment,
  hitsProtectedViaInterpreter,
};
