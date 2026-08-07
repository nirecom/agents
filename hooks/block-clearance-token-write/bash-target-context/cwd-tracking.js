// hooks/block-clearance-token-write/bash-target-context/cwd-tracking.js
// commandCwd() — statically tracks the shell's working directory across the
// segments preceding a write, so a relative target on the same command line
// still resolves against where the shell actually is. Split out of
// bash-target-context.js under the file-split HARD limit (rules/coding/
// file-split.md) — see ../bash-target-context.js's header for the full N-1/N-2
// bypass background, and ./classify.js for the directory-containment half this
// module feeds into (staticPathArg below requires resolveDirSpelling from it).
"use strict";

const path = require("path");
const { unquoteBashWord } = require("../../lib/protected-basenames");
// "which segments really precede this one" — see the block comment above
// sourceOrderView() in ../../lib/substitution-spans.js.
const { sourceOrderView } = require("../../lib/substitution-spans");
const { resolveDirSpelling, WIN_ABS_RE } = require("./classify");

// Statically resolve a `cd <dir>` prefix so a relative target later on the
// same command line still resolves (`cd <wf> && echo x > s1*`). Only
// unambiguous literal arguments count; anything dynamic leaves the cwd
// unchanged. The directory is routed through the same resolver
// globTargetInsideWorkflowDir uses, so `cd ~/...` and the literal-path
// spelling of the same target land on the same verdict (CPR-ORTH/CPR-UNV).
function staticPathArg(rawArg) {
  if (typeof rawArg !== "string" || rawArg === "" || rawArg[0] === "-") return null;
  const t = unquoteBashWord(rawArg);
  if (t === "") return null;
  const resolved = resolveDirSpelling(t);
  if (/[$`]/.test(resolved)) return null;
  return resolved;
}

// commandCwd() must recognize every spelling of "change directory", not just
// `cd` — `pushd "$CLAUDE_WORKFLOW_DIR" && printf x | tee *` is really inside
// the workflow dir when `*` expands, but an unrecognized `pushd` would leave
// the tracked cwd stale and the glob containment check blind. Widening the
// set is safe by construction (DETECTION direction: recognizing one more
// command can only ADD a containment hit). PowerShell cmdlet/alias names are
// case-folded here since they're case-insensitive at runtime while
// command-ir.js keeps cmd0 case-preserved — deliberate over-recognition in
// the fail-wide direction (CPR-UNV).
const DIR_CHANGE_CMDS = new Set([
  "cd",                            // bash builtin / pwsh alias of Set-Location
  "pushd",                         // bash builtin / pwsh alias of Push-Location
  "set-location", "sl", "chdir",   // pwsh cmdlet + aliases
  "push-location",                 // pwsh cmdlet
]);

// `pushd`/`cd` are one-way moves unless something also models POPPING the
// stack or swapping back to OLDPWD: `pushd /tmp && popd && printf x | tee *`
// is really back in the workflow dir by the time `tee *` runs, so leaving
// the tracked cwd stuck at `/tmp` would misjudge containment. `popd` and
// `cd -` are modelled as real inverses (a directory stack, an OLDPWD slot)
// rather than folded into "unresolvable -> unchanged", since that fallback
// would leave the stale forward-moved cwd in place instead of undoing it.
const POP_CMDS = new Set([
  "popd",           // bash builtin / pwsh alias of Pop-Location
  "pop-location",   // pwsh cmdlet
]);

// Commands whose bare `-` argument means "swap with OLDPWD" (bash `cd -`;
// folded into Set-Location/sl/chdir too — fail-wide over-recognition, same
// doctrine as DIR_CHANGE_CMDS's case-folding). `pushd`/`push-location` are
// excluded: bash's `pushd -` is a usage error, not an OLDPWD swap.
const OLDPWD_SWAP_CMDS = new Set(["cd", "set-location", "sl", "chdir"]);

// `pushd +1` / `pushd -0` ROTATE the directory stack and name no path at
// all — must not be mistaken for a relative directory. Left unmodelled
// (CPR-UNV named exception): the cwd is simply left unchanged, same as any
// other unresolvable directory-changing argument, and the residual-
// indirection clauses in classifyBashWriteTarget remain the backstop.
const DIR_STACK_ROTATION_RE = /^[+-]\d+$/;

function isDirChangeCmd(cmd0) {
  return typeof cmd0 === "string" && cmd0 !== "" && DIR_CHANGE_CMDS.has(cmd0.toLowerCase());
}

function isPopCmd(cmd0) {
  return typeof cmd0 === "string" && cmd0 !== "" && POP_CMDS.has(cmd0.toLowerCase());
}

// `command cd <wf>` / `builtin cd <wf>` change the directory exactly like
// bare `cd` (the wrapper only suppresses function/alias lookup), but
// seg.cmd0 is the wrapper word, so isDirChangeCmd would otherwise miss it.
// Unwrapping one level here (mirroring each wrapper's own accepted flags)
// restores parity; `eval "cd <wf>"` stays out of scope — interpreter-scan.js
// re-scans interpreter bodies.
const COMMAND_WRAPPER_CMDS = new Set(["command", "builtin"]);

function effectiveCmdAndArgv(seg) {
  const head = typeof seg.cmd0 === "string" ? seg.cmd0.toLowerCase() : "";
  const argv = Array.isArray(seg.argv) ? seg.argv : [];
  if (!COMMAND_WRAPPER_CMDS.has(head) || argv.length === 0) return { cmd: head, argv };
  let i = 0;
  if (head === "command") {
    while (i < argv.length && typeof argv[i] === "string" && argv[i][0] === "-") i++;
  }
  if (i >= argv.length) return { cmd: head, argv };
  return { cmd: String(argv[i]).toLowerCase(), argv: argv.slice(i + 1) };
}

function commandCwd(segments, idx, toolCwd) {
  let cwd = typeof toolCwd === "string" && toolCwd !== "" ? toolCwd : null;
  let oldpwd = null;
  const stack = []; // pushd-pushed directories, LIFO — mirrors the real shell's dirstack.
  // A substitution-span segment (../bash-scan/scan.js) is APPENDED after the
  // ordinary segments, so its array index says nothing about where it sits
  // in the command text; sourceOrderView() recovers true source order
  // (CPR-SSOT, shared with priorAssignmentsText).
  const view = sourceOrderView(segments, idx);
  const segs = view.segments;
  const end = view.idx;
  for (let j = 0; j < end; j++) {
    const seg = segs[j];
    if (!seg || !Array.isArray(seg.argv)) continue;
    const { cmd, argv } = effectiveCmdAndArgv(seg);

    if (isPopCmd(cmd)) {
      // Empty stack -> real `popd` errors and leaves cwd unchanged; match it.
      if (stack.length > 0) {
        const prev = cwd;
        cwd = stack.pop();
        if (prev != null) oldpwd = prev;
      }
      continue;
    }

    if (!isDirChangeCmd(cmd)) continue;

    if (OLDPWD_SWAP_CMDS.has(cmd) && argv.some((a) => String(a) === "-")) {
      // OLDPWD unset -> real `cd -` errors and leaves cwd unchanged; match it
      // rather than guessing (guessing wrong in either direction is worse than
      // the pre-existing "unresolvable -> unchanged" contract this loop already
      // uses for every other unresolvable argument).
      if (oldpwd != null) {
        const prev = cwd;
        cwd = oldpwd;
        oldpwd = prev;
      }
      continue;
    }

    const isPushd = cmd === "pushd" || cmd === "push-location";
    // `pushd -n <dir>` pushes onto the stack WITHOUT changing the shell's cwd
    // (bash: `-n` = "no cd"). Without this check the loop would walk to
    // `<dir>` and treat it as a real cd, moving the tracked cwd while the
    // real one stays put. bash-specific, so checked only for `pushd`.
    if (cmd === "pushd" && argv.some((a) => String(a) === "-n")) continue;

    const arg = argv
      .filter((a) => !DIR_STACK_ROTATION_RE.test(String(a)))
      .map(staticPathArg)
      .find((a) => a !== null);
    if (arg == null) continue;
    let resolved = arg;
    if (path.isAbsolute(resolved) || WIN_ABS_RE.test(resolved)) {
      // already absolute
    } else if (cwd) {
      resolved = path.resolve(cwd, resolved);
    } else {
      continue; // relative with unknown cwd -> unresolvable, matches prior behavior
    }
    if (isPushd) {
      if (cwd != null) stack.push(cwd);
    }
    if (cwd != null) oldpwd = cwd;
    cwd = resolved;
  }
  return cwd;
}

module.exports = {
  commandCwd,
};
