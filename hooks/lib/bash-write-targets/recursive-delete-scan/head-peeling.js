"use strict";

// Head peeling for recursive-delete-scan.js: `do rm -rf x`, `exec -a N rm -rf
// x`, `foreach { ... }` land the wrapped command on the head's own segment.

const { PWSH_BLOCK_PIPELINE_HEADS: PWSH_BLOCK_HEADS } = require("../pwsh");

// Heads that pass their tokens through unmodified: `do rm -rf x` parses to
// {cmd0:"do", argv:["rm","-rf","x"]}.
const TRANSPARENT_KEYWORD_HEADS = new Set([
  "do", "then", "else", "elif", "{", "!", "if", "while", "until", "coproc",
]);

// Heads that take their OWN options before the wrapped command (`exec -a NAME
// cmd`, `time -p cmd`) — every suffix position is judged, uncapped.
const OPTION_TAKING_HEADS = new Set(["exec", "time"]);

// Peel down to the innermost wrapped command(s). Returns EVERY candidate
// segment worth judging plus `extraScripts` — `trap`/`eval` bodies, which are
// one script rather than word-split tokens. Depth is bounded against `! ! !
// ... rm -rf x`.
function peelTransparentHeads(seg) {
  let cur = seg;
  const extraScripts = [];
  const effSegs = [];
  for (let depth = 0; depth < 16; depth++) {
    if (!cur || typeof cur.cmd0 !== "string") break;
    const argv = Array.isArray(cur.argv) ? cur.argv : [];
    const argvRaw = Array.isArray(cur.argvRaw) && cur.argvRaw.length === argv.length ? cur.argvRaw : argv.slice();

    if (cur.cmd0 === "eval") {
      // `eval` evaluates its whole argv joined by spaces; a leading `--` must
      // not become the joined script's cmd0.
      const a = argv[0] === "--" ? argv.slice(1) : argv;
      if (a.length > 0) extraScripts.push(a.join(" "));
      cur = null;
      break;
    }

    if (cur.cmd0 === "trap") {
      // `trap [--] ARG SIGSPEC...` — only ARG is script; judging SIGSPECs too
      // fail-closed on signal-name tokens like `$SIG`.
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
