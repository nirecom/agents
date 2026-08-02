// hooks/block-off-clearance-write/interpreter-scan.js
// Interpreter-one-liner analysis for the block-off-clearance-write entrypoint
// (file-split, rules/coding/file-split.md — the entrypoint exceeded the 500-line
// HARD limit). Moved verbatim from that file apart from one change: the Tier-1
// mention gate and the Tier-2 body prefilter now recognize PROTECTED SESSION
// MARKERS as well as the clearance token (#1780 H-1/H-2, CPR-5) via the shared
// SSOT in hooks/lib/protected-basenames.js.
"use strict";

const { mentionsProtectedName, TOKEN_MENTION_RE } = require("../lib/protected-basenames");
const { ci, PWSH_ENV_PREFIX } = require("../lib/case-insensitive-literal");

// vector2 heuristic (best-effort, deliberately incomplete): an interpreter
// one-liner whose body mentions the clearance-token name.
// H2 (security-scanner round 5): the original list covered only the "scripting
// language" interpreters and left every POSIX shell (bash/sh/zsh/dash) `-c` /
// `--eval`/`--command` long-flag invocation unrecognized, even though
// hooks/lib/bash-write-targets.js's isInterpreterCWriteIR — used by the
// sibling enforce-worktree.js hook on the SAME diff — already treats those
// shells as interpreters. That asymmetry let `bash -c "..."` reach a token
// via `process.env`/argv indirection while `node -e` did not (CPR-5).
//
// F-1 (security-scanner round 6): the single-flag alternation above never
// matched a CLUSTERED short-option group (`bash -ce`, `sh -ec`, `python3
// -uc`) or a pwsh minimal-unambiguous-prefix abbreviation (`pwsh -Comm`),
// even though all of these really do invoke -c/-e/-Command at runtime.
// INTERPRETER_RE (the Tier-1 gate) and flagRe (body extraction, below) MUST
// recognize the exact same flag shapes: a broadened gate paired with a
// narrower extractor would fail-closed block every legitimate read-only
// one-liner using a clustered/abbreviated flag (defeating #1709), while a
// broadened extractor paired with a narrower gate reproduces the original
// bug (Tier 2 never runs). CLUSTER_FLAG is capped at 3 letters after the
// dash so it still catches short combos (`-ec`, `-uc`) without also
// matching an unrelated multi-letter flag that happens to contain a c/e
// (e.g. `-File`, `-force`) — those stay outside INTERPRETER_RE, same as
// before this fix.
//
// H-4 (#1780 round-4): CASE. `Node -e`, `BASH -c` and `PwSh -Command` all
// execute on Windows (executable lookup is case-insensitive there, and
// PowerShell parameter names are case-insensitive on every platform), but the
// gate only recognized the all-lowercase spellings, so capitalizing the
// interpreter name walked straight past this hook.
//
// The fix is applied PER LANGUAGE rather than by putting the `i` flag on the
// whole pattern (hooks/lib/case-insensitive-literal.js explains why that would
// be wrong):
//   interpreter names   -> case-INSENSITIVE  (Windows exec lookup)
//   pwsh -Command / -EncodedCommand and their prefixes, --command,
//   --encoded-command -> case-INSENSITIVE    (PowerShell parameter names)
//   POSIX short flags (the `[ce]` core of CLUSTER_FLAG) and `--eval`
//                     -> case-SENSITIVE      (`sh -C` is noclobber, NOT -c;
//                                             node's long option is lowercase)
// flagRe in extractAllInterpreterBodies() is built from the SAME FLAG_ALTS, so
// the Tier-1 gate and the Tier-2 extractor widen together — the pairing this
// file's comment above insists on is preserved by construction.
// Split by EXECUTION MODEL, not alphabetically: the two halves differ in how a
// program delivered on stdin must be judged. A shell reads shell text (recurse
// the whole bash scanner over it — ./nested-bodies.js); a language interpreter
// reads ITS OWN language, which only interpreterBodyHitsProtected() below can
// judge. INTERPRETER_NAMES keeps the original order (languages then shells) so
// INTERPRETER_RE's alternation is byte-identical to before this split.
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
// INTERPRETER_RE folds case (Windows executable lookup — H-4, #1780 round-4).
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
// for pwsh and meaningless everywhere else (round 8).
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
// PROOF that the program is on argv: does this ONE argv word show the
// interpreter is reading its program from argv, so that stdin carries DATA?
// ./nested-bodies.js clears a stdin-program route on the strength of it.
//
// DIRECTION DISCIPLINE — read this before merging anything below back into
// FLAG_ALTS above. The two alternations point in OPPOSITE directions and must
// stay separately defined:
//
//   FLAG_ALTS       EXTRACTION. Over-matching only makes Tier 2 read more text
//                   and fail closed more often -> safe, so it is built wide on
//                   purpose (every pwsh minimal prefix, `-E` included).
//   proof set here  PERMISSION. A match CLEARS a stdin program route, so
//                   over-matching is a BYPASS.
//
// Round 8 was exactly that mistake: this regex was derived from FLAG_ALTS, so
// it inherited pwsh's `-E` EncodedCommand prefix and accepted it for EVERY
// interpreter — and `printf '<program>' | python3 -E -` is a real invocation
// (`-E` = ignore environment, `-` = read the program from stdin), so a live
// route to delete a clearance marker went ALLOW.
//
// Every rule below therefore resolves doubt towards over-block:
//   * short clusters are LOWERCASE-only (`-c`, `-e`, `-uc`, `-ec`), which is
//     what keeps `-E`, `-En` and `-Enc` out for everyone;
//   * pwsh PARAMETER names count only when cmd0 really is pwsh/powershell —
//     see inlineProgramFlagProof(); a pwsh prefix must never clear a python3
//     or node invocation;
//   * the `-EncodedCommand` chain starts at `-En`, the shortest spelling real
//     pwsh resolves unambiguously (`-E` is ambiguous with `-ExecutionPolicy`,
//     so nothing legitimate is lost);
//   * `-E`, `-p`, `-P`, `--print` are absent although each IS an inline-program
//     flag in one language (`perl -E`, `node -p`): each is an ordinary option
//     in another (`python3 -E` ignore-env, `bash -p` privileged), and this
//     predicate has to hold across the whole interpreter domain, not just the
//     language that names the flag (CPR-8). A missing proof costs over-block;
//     an extra one costs a bypass.
// `(?:=|$)` accepts the attached long form (`--eval=code`) as well as the
// separate-token form.
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

// #1780 round-5 MEDIUM-6. INTERPRETER_RE requires a `-c`/`-e`-family FLAG before
// it will call something an interpreter, which is right for the languages above
// (they need one) and wrong for a whole family that does not:
//
//   awk 'BEGIN{print "x" > "<wf>/s1.<marker>"}'   — program is argv[0], no flag
//   php -r '…'   lua -e '…'   Rscript -e '…'   osascript -e '…'   tclsh f.tcl
//   env -S 'sh -c …'
//
// `awk` was a measured ALLOW: a one-line, unobfuscated file write past the whole
// hook. These names are therefore matched on the NAME ALONE. That makes the
// Tier-1 gate below arm for any segment naming one of them, and Tier 2 then
// finds no extractable `-c`/`-e` body and fails closed — which is the intended
// verdict, since none of these has a recognized read-only shape and none is a
// sanctioned way to read a token (plain `cat` / `Get-Content` is).
//
// This is enumeration, and enumeration inherently LAGS: the next interpreter
// nobody listed is the next bypass. It is deliberately the weakest of the
// defences added in this round and not the one being relied on. The real
// backstops are structural and name-independent — cmd0 is classified like argv
// (./bash-scan.js, HIGH-1 part 2), unparsable text fails closed (HIGH-2),
// unresolved expansions in a write target fail closed (./bash-target-context.js,
// MEDIUM-4), and nested command text is recursed rather than pattern-matched
// (./nested-bodies.js, HIGH-3/MEDIUM-5). CPR-8: prefer the general rule; keep
// the enumeration as a cheap extra layer, never as the boundary.
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

// #1709: READ must not be blocked, but "not a write" is undecidable inside an
// arbitrary interpreter body (execSync / os.system / Path.touch / Deno.* / ...
// all write without naming any enumerable write verb). So the classification is
// inverted: only a SHORT LIST of fully-anchored read-only shapes is recognized,
// and everything else — including anything unparsable — is treated as a write.
// Plain shell reads (cat / Get-Content / ls / type) never reach this function:
// they produce no write target and do not match INTERPRETER_RE.

// (C3) Interpolation / subexpression / escape guard. Being "inside quotes" does
// NOT make an argument inert:
//   pwsh  -> "..." interpolates $(...) and $var, and ` is an escape char
//   node  -> `...` interpolates ${...}
//   python-> f'...' / f"..." interpolate {...}
// Any body containing these constructs is rejected BEFORE shape matching, so a
// crafted `Get-Content "$( Remove-Item ... )"` can never present as read-only.
// Backslash is rejected too: it is pwsh/JS/py escape material and would let a
// quote be smuggled past the anchored shapes. Consequence (accepted): paths must
// use forward slashes or the $env:/process.env form — both work on Windows.
//
// Bare `$NAME` guard: the hook sees tool_input.command BEFORE the shell expands
// it. `$(`/`${` are not the only interpolation vectors — a plain unbraced shell
// variable (`$P`, pwsh `$var`) is expanded by bash/pwsh at execution time even
// though it looks like an inert literal to static analysis here (e.g.
// `P="<payload>"; node -e "console.log(require('fs').existsSync('$P'))"`). So
// ANY bare `$` must fail closed UNLESS it is the start of the one sanctioned
// token this hook already understands and validates as a unit: pwsh `$env:VAR`
// (see PWSH_ENV below). `process.env.X` / `os.environ['X']` do not start with a
// bare `$` in node/python syntax, so they are unaffected by this check.
//
// H-4 (#1780 round-4): the `env:` scope prefix is case-insensitive in
// PowerShell (`$ENV:PATH` works), so the sanctioned-token exemption must be
// too — otherwise `$ENV:X` trips the interpolation guard and a legitimate
// read-only one-liner fails closed. The exemption and PWSH_ENV below use the
// same spelling so they can never disagree about what is sanctioned
// (PWSH_ENV_PREFIX is the SSOT in hooks/lib/case-insensitive-literal.js).
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
// this scanner anywhere else either (H-4, #1780 round-4).
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
  // pwsh: Get-Content [-Raw] <path>
  // H-4 (#1780 round-4): PowerShell cmdlet and parameter names are
  // case-insensitive, so `get-content -raw` / `GET-CONTENT -RAW` are the SAME
  // read-only cmdlet. Recognizing only the canonical casing fail-closed
  // BLOCKED those spellings — a #1709 read-allow regression, in the opposite
  // direction from the interpreter-name gap. The path argument grammar is
  // untouched: it stays as strict as before.
  new RegExp(String.raw`^\s*${ci("Get-Content")}\s+(?:${ci("-Raw")}\s+)?${PWSH_PATH_ARG}\s*$`),
];

// extractAllInterpreterBodies(text): every quoted body passed to -e/-c/-Command
// in `text`, plus invocationCount — how many -e/-c/-Command flags appear in
// total, quoted or not. Caller fail-closes on `invocationCount > bodies.length`
// (round 4, supervisor-audit-4 + security-scanner-4):
//   - A flag whose argument is unquoted, or quoted with a form this scanner
//     does not model (e.g. bash ANSI-C `$'...'`), is counted by
//     invocationCount but yields no body — it cannot be proven token-free, so
//     it must fail closed rather than being silently excluded from the count
//     (the prior version only counted flags immediately followed by a quote
//     character, so an ANSI-C or bare-`$VAR` body sat outside BOTH counters
//     and was invisible to the mismatch check — H-A, security-scanner round 4).
//   - Extraction itself walks the string once per flag with scanQuotedBody()
//     below (no regex backtracking over the body), closing the catastrophic-
//     backtracking DoS the prior alternation-based body regex had on crafted
//     unterminated backtick runs (H-B, security-scanner round 4).
// This function receives one shell segment's text (bashHitsProtected scopes the
// caller to a single segment — see supervisor-audit-4), not the whole
// command line, so an interpreter invocation in one segment is never
// conflated with flags belonging to an unrelated segment.
// NOTE (accepted limitation, unchanged from the TRUST MODEL comment at the
// top of the entrypoint): this is still a best-effort heuristic, not a proof.
// Bodies that are provably extracted and provably token-free are approved;
// anything this scanner cannot cleanly account for fails closed.
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

// supervisor-audit-5: an env-prefix assignment (`A=<token> node -e "...
// process.env.A..."`) lives in the SAME segment as the interpreter
// invocation (resolveEffectiveSegment strips it from cmd0/argv, but
// seg.rawText — and therefore gateText — still carries it), so Tier 1
// correctly sees "off-clearance" and enters Tier 2. But the extracted body
// only dereferences `process.env.A` / `os.environ['A']` / `$env:A` — it
// never spells the token out — so the per-body substring check at the
// Tier-2 loop let it through as "out of scope". Close this indirection
// class: for every env-var name the body dereferences, look for a same-
// segment (or contiguous-preceding-assignment) `NAME=value` assignment
// in gateText and fail closed when that assigned value carries the token.
// A body that dereferences an env var the assignment chain never sets to
// the token stays out of scope, unchanged.
// F-1 follow-up (round 6 verification): the original alternation covered only
// the node/python/pwsh dereference spellings, so a body reachable via
// `bash -c` / `bash -ce` / `sh -ec` (clustered short options now recognized by
// FLAG_ALTS above, but plain `bash -c` already matched before this file's F-1
// change too) that dereferences an env var with bash's OWN syntax (`$A`,
// `${A}`) was never counted as "derefs an env var" at all, so a preceding
// `A=<token> bash -ce "echo \$A"` fell through the mentionsToken/derefs-check
// as "out of scope" even though the body clearly leaks the token via $A. The
// trailing `\$\{?(...)\}?` alt is intentionally LAST so it never preempts the
// more specific `$env:NAME` alt for the same leading `$`.
// H-4 (#1780 round-4): only the pwsh `$env:` scope prefix is folded. The
// node (`process.env`) and python (`os.environ`) spellings are language
// identifiers and stay case-sensitive, as do the variable names themselves.
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
    // round-6 F-1 follow-up: same `$env:` prefix addition as the
    // segmentArgvHitsProtectedArg sibling in ./bash-scan.js — see that comment.
    const assignRe = new RegExp("(?:^|[\\s;&|]|\\$" + PWSH_ENV_PREFIX + ")" + varName + "=(\\S+)", "m");
    const am = assignRe.exec(gateText);
    // #1780 H-1: a marker path assigned to the variable is the same class of
    // indirection as a token path (CPR-5).
    if (am && mentionsProtectedName(am[1])) return true;
  }
  return false;
}

// interpreterBodyHitsProtected(body, gateText): the verdict for ONE interpreter
// program body, whatever route delivered it.
//
// #1780 round-5 follow-up: this used to exist only as the inner half of the
// Tier-2 loop below, which made it reachable exclusively through a `-c`/`-e`/
// `-Command` FLAG. Every other route a program body arrives by — a here-string,
// a heredoc, a pipe — therefore fell back to the SHELL scanner, which judges
// `require("fs").unlinkSync("<marker>")` as an ordinary (non-matching) word and
// approved the identical payload that the flag form blocks. Hoisting the
// judgement into its own function makes the DELIVERY ROUTE and the LANGUAGE
// JUDGEMENT independent, so ./nested-bodies.js can route by the receiving
// command's interpreter identity and reuse this one classifier (CPR-2/CPR-4).
function interpreterBodyHitsProtected(body, gateText) {
  if (typeof body !== "string" || body === "") return false;
  const scope = typeof gateText === "string" ? gateText : body;
  // Out of scope: the body neither names a protected path nor dereferences a
  // variable the surrounding text assigns one to.
  if (!mentionsProtectedName(body) && !bodyDerefsProtectedViaAssignment(body, scope)) return false;
  // In scope: approved only for an anchored, provably side-effect-free read
  // shape (#1709); everything else is a write until proven otherwise.
  return !interpreterBodyIsRecognizedReadOnly(body);
}

function hitsProtectedViaInterpreter(text, gateText) {
  if (gateText === undefined) gateText = text;
  if (!looksLikeInterpreterInvocation(text)) return false;
  // `text` is one shell segment (bashHitsProtected scopes each call to a single
  // segment — supervisor-audit-4), or the whole raw command as a fail-closed-
  // conservative fallback when segmentation itself was not possible.
  // Two-tier fail-closed gate. Tier 1 (`gateText`: this segment's text, plus
  // any contiguous assignment-only segments immediately preceding it — see
  // bashHitsProtected): if no protected name appears anywhere in it, there
  // is nothing to protect against in THIS segment — approve immediately,
  // even when the interpreter body can't be cleanly extracted. Without this
  // gate, ordinary unrelated commands whose body runs past the anchored
  // extractor (e.g. `node -e "console.log(1)" > out.txt`) get fail-closed
  // blocked for no reason, since they never mention a protected name.
  // The marker half of mentionsProtectedName() is anchored on the `.<kind>`
  // basename tail precisely so ordinary repo paths (`rules/workflow-off.md`,
  // `skills/enforce-workflow-off/`) do NOT arm this gate.
  if (!mentionsProtectedName(gateText)) return false;
  // Tier 2 (body): this segment DOES mention a protected name somewhere, so
  // extract EVERY interpreter body in it and re-check there. Body extraction
  // comes first at this tier: an opaque body (e.g. `node -e $BODY`) hides its
  // own token reference, so the body-level substring prefilter cannot clear
  // it. Unextractable (or partially unextractable — flagCount >
  // bodies.length) → cannot be proven unrelated → fail-closed block (this is
  // exactly the suspicious wrap-and-obscure case the hook exists for).
  const { bodies, flagCount } = extractAllInterpreterBodies(text);
  if (bodies.length === 0 || flagCount > bodies.length) return true;
  // Every extracted body must be either protected-name-free or a recognized
  // read-only shape. The prefilter must test each `body`, never the whole `cmd`:
  // surrounding shell text (a `cd` into a directory named
  // .../off-clearance-1780/..., an unrelated --detail "…off-clearance…"
  // argument on the same line) would otherwise misclassify an interpreter
  // body that never touches the token.
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
