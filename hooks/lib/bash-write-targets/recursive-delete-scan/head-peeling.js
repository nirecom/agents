"use strict";

// Transparent-keyword-head and PowerShell-brace-block peeling for
// recursive-delete-scan.js: `do rm -rf x`, `exec -a NAME rm -rf x`,
// `foreach { Remove-Item -Recurse x }` all land the wrapped command on the
// SAME segment as the head keyword, so judging the head's own cmd0 misses the
// real command underneath. Split out of the parent when it crossed the
// 500-line hard limit.

const { PWSH_BLOCK_PIPELINE_HEADS: PWSH_BLOCK_HEADS } = require("../pwsh");

// Shell heads that pass their tokens through to a wrapped command unmodified:
// `do`/`then`/`else`/`elif`/`if`/`while`/`until`/`coproc` (loop/conditional
// bodies), `{`/`!` (brace groups, negation). The parser lands these on their
// own segment with the wrapped command's tokens AS that segment's argv (e.g.
// `do rm -rf x` -> {cmd0:"do", argv:["rm","-rf","x"]}), so judging cmd0 itself
// silently misses the real command underneath (#2210 F3/N1). `exec`/`time`
// are handled separately below (OPTION_TAKING_HEADS) since they can carry
// their own options ahead of the wrapped command.
const TRANSPARENT_KEYWORD_HEADS = new Set([
  "do", "then", "else", "elif", "{", "!", "if", "while", "until", "coproc",
]);

// PWSH_BLOCK_HEADS (imported above from pwsh.js, this repo's owner of the set)
// are the PowerShell block heads whose FIRST ARG, not their cmd0, is the
// brace-wrapped body: `foreach { ... }` / `% { ... }`. Scoped narrowly (#2210
// N3) — an unconditional brace-peel fired for ANY cmd0, so `rm {a,b} -rf` got
// peeled into a non-"rm" cmd0 and its judgment discarded. Matched
// case-insensitively (#2210 F3) — PowerShell head names fold case.

// Heads that take their OWN options before the wrapped command (`exec -a NAME
// cmd`, `time -p cmd`) — every suffix position is judged, uncapped (#2210 N2/F1).
const OPTION_TAKING_HEADS = new Set(["exec", "time"]);

// Peel a chain of transparent keyword heads / PowerShell brace-block aliases
// down to the innermost wrapped command(s). Returns EVERY candidate segment
// worth judging (never just one) plus `extraScripts` — inline script bodies
// from `trap`/`eval`, which take a single script rather than word-split
// tokens, collected for a full recursive scan. Bounded depth guards
// pathological nesting (e.g. `! ! ! ... rm -rf x`) like peelWrappers does.
function peelTransparentHeads(seg) {
  let cur = seg;
  const extraScripts = [];
  const effSegs = [];
  for (let depth = 0; depth < 16; depth++) {
    if (!cur || typeof cur.cmd0 !== "string") break;
    const argv = Array.isArray(cur.argv) ? cur.argv : [];
    const argvRaw = Array.isArray(cur.argvRaw) && cur.argvRaw.length === argv.length ? cur.argvRaw : argv.slice();

    if (cur.cmd0 === "eval") {
      // `eval` joins its own argv with spaces and evaluates the result — the
      // whole-argv join IS the script (#2210 N2). A leading `--` is stripped
      // so it does not itself become the joined script's cmd0.
      const a = argv[0] === "--" ? argv.slice(1) : argv;
      if (a.length > 0) extraScripts.push(a.join(" "));
      cur = null;
      break;
    }

    if (cur.cmd0 === "trap") {
      // `trap [--] ARG SIGSPEC...` — ARG (after an optional `--`) is the one
      // script; SIGSPECs are plain signal names, never script content, so
      // pushing them as their own candidates only produced false fail-closed
      // hits on tokens like `$SIG` (#2210 F7).
      let a = argv;
      if (a[0] === "--") a = a.slice(1);
      if (typeof a[0] === "string" && a[0] !== "") extraScripts.push(a[0]);
      cur = null;
      break;
    }

    if (OPTION_TAKING_HEADS.has(cur.cmd0)) {
      for (let i = 0; i < argv.length; i++) {
        effSegs.push({
          cmd0: argv[i], cmd0Raw: argvRaw[i],
          argv: argv.slice(i + 1), argvRaw: argvRaw.slice(i + 1),
          redirects: cur.redirects,
        });
      }
      const nextIdx = argv.findIndex((t) => typeof t === "string" && !t.startsWith("-"));
      if (nextIdx === -1) { cur = null; break; }
      cur = {
        cmd0: argv[nextIdx], cmd0Raw: argvRaw[nextIdx],
        argv: argv.slice(nextIdx + 1), argvRaw: argvRaw.slice(nextIdx + 1),
        redirects: cur.redirects,
      };
      continue;
    }

    if (TRANSPARENT_KEYWORD_HEADS.has(cur.cmd0)) {
      if (argv.length === 0) { cur = null; break; }
      cur = { cmd0: argv[0], cmd0Raw: argvRaw[0], argv: argv.slice(1), argvRaw: argvRaw.slice(1), redirects: cur.redirects };
      continue;
    }

    if (PWSH_BLOCK_HEADS.has(cur.cmd0.toLowerCase())) {
      if (argv.length > 0 && argv[0] === "{") {
        if (argv.length < 2) { cur = null; break; }
        cur = { cmd0: argv[1], cmd0Raw: argvRaw[1], argv: argv.slice(2), argvRaw: argvRaw.slice(2), redirects: cur.redirects };
        continue;
      }
      // Brace glued to the wrapped command with no space (`foreach {Remove-Item ...}`).
      if (argv.length > 0 && typeof argv[0] === "string" && argv[0].startsWith("{") && argv[0] !== "{") {
        const rest = argv[0].slice(1);
        const restRaw = typeof argvRaw[0] === "string" && argvRaw[0].startsWith("{") ? argvRaw[0].slice(1) : rest;
        cur = { cmd0: rest, cmd0Raw: restRaw, argv: argv.slice(1), argvRaw: argvRaw.slice(1), redirects: cur.redirects };
        continue;
      }
    }

    break;
  }
  if (cur) effSegs.push(cur);
  return { effSegs, extraScripts };
}

module.exports = { peelTransparentHeads };
