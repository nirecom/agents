"use strict";
// maskDisplayOnlySegments(line) — blank the segments of a command line whose
// command word is `echo` or `printf`, so an interpreter or shell NAME handed to
// one of them reads as the data it is: `echo sh -c x` PRINTS text and runs
// nothing. Consumers are the execution detectors that match interpreter names
// with a whitespace-tolerant anchor (hooks/lib/unrecognized-exec-check.js,
// hooks/preuse-auto-approve/script-body-scan.js); that anchor alone cannot tell
// a command word from an argument, and over-blocking every self-documenting
// script would make the scratchpad auto-approve useless.
// CONSERVATIVE: a segment is blanked ONLY when it is provably inert — it starts
// with echo/printf AND carries no command substitution, whose body would run.

const DISPLAY_ONLY_RE = /^\s*(?:echo|printf)(?:\.exe)?(?=\s)/i;
const SUBSTITUTION_RE = /\$\(|`/;
// Capturing split: the separators survive, so every segment that is NOT blanked
// still sits at the command position its own anchor expects.
const SEGMENT_SPLIT_RE = /([;|&()\n])/;

function maskDisplayOnlySegments(line) {
  if (typeof line !== "string" || line === "") return "";
  const parts = line.split(SEGMENT_SPLIT_RE);
  for (let i = 0; i < parts.length; i += 2) {
    if (DISPLAY_ONLY_RE.test(parts[i]) && !SUBSTITUTION_RE.test(parts[i])) parts[i] = "";
  }
  return parts.join("");
}

module.exports = { maskDisplayOnlySegments };
