"use strict";
// hooks/lib/interpreter-inline-body.js — inline bodies handed to a shell / pwsh
// interpreter (`bash -lc '…'`, `powershell -Command …`, `eval …`) (#1861).
// Heredoc bodies are dropped, the rest split into logical lines and parsed to argv;
// every argv position is scanned for an interpreter so any prefix (sudo, xargs,
// find -exec, env …) is covered. Bodies recurse up to MAX_DEPTH; unparsable lines
// come back as unparsedLines. A rest-of-line body (eval, pwsh) ends the segment
// scan (recursion reaches later interpreters); exceeding MAX_BODIES or
// MAX_TOTAL_BYTES, or a depth-MAX_DEPTH body that still wraps a quoted interpreter
// body, sets `overflow`, which callers must treat as fail-closed.

const { parse } = require("./command-ir");
const { scanHeredocs } = require("./command-ir/heredoc");
const { spanAwareNewlineSplit } = require("./quote-spans");
const { endsWithLineContinuation, stripQuotedArgs } = require("./strip-quoted-args");
const { commandBasename } = require("./bash-write-patterns/segment-utils");

const MAX_DEPTH = 3;
const MAX_BODIES = 1000;
const MAX_TOTAL_BYTES = 1024 * 1024;
const POSIX_SHELLS = new Set(["bash", "sh", "zsh", "dash", "fish", "ksh", "ksh93", "mksh", "ash"]);
const PWSH_SHELLS = new Set(["pwsh", "powershell"]);
const FISH_COMMAND_EQ = "--command=";

function isInlineBodyFlag(arg, interpBase) {
  if (typeof arg !== "string") return false;
  const al = arg.toLowerCase();
  if (PWSH_SHELLS.has(interpBase)) return al === "-c" || al === "-command";
  if (interpBase === "fish" && (al === "--command" || al.startsWith(FISH_COMMAND_EQ))) return true;
  return al === "-c" || (arg.startsWith("-") && !arg.startsWith("--") && arg.slice(1).includes("c"));
}

// fish `--command=<body>` carries its body inside the flag token itself.
function attachedBodyOf(flag) {
  return typeof flag === "string" && flag.toLowerCase().startsWith(FISH_COMMAND_EQ) ? flag.slice(FISH_COMMAND_EQ.length) : null;
}

function logicalLines(text) {
  const lexText = scanHeredocs(text).lexText;
  const split = spanAwareNewlineSplit(lexText);
  const physical = split.ok ? split.lines : [lexText];
  const lines = [];
  let pending = "";
  for (const line of physical) {
    if (endsWithLineContinuation(line)) {
      pending += line.replace(/\\[ \t]*$/, "") + " ";
      continue;
    }
    lines.push(pending + line);
    pending = "";
  }
  if (pending) lines.push(pending);
  return lines.filter((l) => l.trim() !== "");
}

// POSIX shells read options after -c too (`bash -c -- 'x'`, `bash -c -x 'x'`).
function skipShellOptions(toks, k) {
  while (k < toks.length) {
    const t = toks[k];
    if (t === "--") return k + 1;
    if (t === "-o" || t === "+o" || t === "-O" || t === "+O") k += 2;
    else if (/^[-+][A-Za-z]+$/.test(t)) k++;
    else break;
  }
  return k;
}

// One pass per segment: a flag search that reached the end cannot succeed for a
// later interpreter of the same family, so it is never repeated (no O(N^2) scan).
function segmentBodies(toks) {
  const bodies = [];
  let restTaken = false;
  let posixExhausted = false;
  let pwshExhausted = false;
  for (let i = 0; i < toks.length; i++) {
    const base = commandBasename(toks[i]);
    if (base === "eval") {
      if (!restTaken && i + 1 < toks.length) bodies.push(toks.slice(i + 1).join(" "));
      restTaken = true;
      continue;
    }
    const isPwsh = PWSH_SHELLS.has(base);
    if (isPwsh ? restTaken || pwshExhausted : !POSIX_SHELLS.has(base) || posixExhausted) continue;
    let j = i + 1;
    while (j < toks.length && !isInlineBodyFlag(toks[j], base)) j++;
    if (isPwsh) {
      if (j + 1 < toks.length) {
        bodies.push(toks.slice(j + 1).join(" "));
        restTaken = true;
      } else pwshExhausted = true;
      continue;
    }
    const attached = j < toks.length ? attachedBodyOf(toks[j]) : null;
    if (attached !== null) {
      bodies.push(attached);
      i = j;
      continue;
    }
    const k = skipShellOptions(toks, j + 1);
    if (k >= toks.length) {
      posixExhausted = true;
      continue;
    }
    bodies.push(toks[k]);
    i = k;
  }
  return bodies;
}

function collect(commandText, depth, acc) {
  if (acc.overflow || typeof commandText !== "string" || commandText.trim() === "") return;
  for (const line of logicalLines(commandText)) {
    const ir = parse(line);
    if (ir.parseFailure) {
      acc.unparsedLines.push(line);
      continue;
    }
    for (const seg of ir.segments) {
      const segBodies = segmentBodies([seg.cmd0, ...seg.argv]);
      if (depth >= MAX_DEPTH) {
        // Past the cap only a body already visible unquoted in this line (an eval
        // rest-of-line) is scanned via its parent; any other one fails closed.
        const visible = stripQuotedArgs(line);
        if (segBodies.some((b) => !visible.includes(b))) {
          acc.overflow = true;
          return;
        }
        continue;
      }
      for (const body of segBodies) {
        acc.bytes += body.length;
        if (acc.bodies.length >= MAX_BODIES || acc.bytes > MAX_TOTAL_BYTES) {
          acc.overflow = true;
          return;
        }
        acc.bodies.push(body);
        collect(body, depth + 1, acc);
        if (acc.overflow) return;
      }
    }
  }
}

function inlineBodiesOf(commandText) {
  const acc = { bodies: [], unparsedLines: [], bytes: 0, overflow: false };
  collect(commandText, 0, acc);
  return { bodies: acc.bodies, unparsedLines: acc.unparsedLines, overflow: acc.overflow };
}

module.exports = { isInlineBodyFlag, attachedBodyOf, skipShellOptions, inlineBodiesOf, POSIX_SHELLS, MAX_BODIES, MAX_TOTAL_BYTES };
