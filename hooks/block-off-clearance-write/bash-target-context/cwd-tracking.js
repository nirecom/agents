// hooks/block-off-clearance-write/bash-target-context/cwd-tracking.js
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
// #1780 round-13: "which segments really precede this one" — see the block
// comment above sourceOrderView() in ../../lib/substitution-spans.js.
const { sourceOrderView } = require("../../lib/substitution-spans");
const { resolveDirSpelling, WIN_ABS_RE } = require("./classify");

// Statically resolve a `cd <dir>` prefix so a relative target later on the same
// command line still resolves (`cd <wf> && echo x > s1*`). Only unambiguous
// literal arguments count; anything dynamic leaves the cwd unchanged.
//
// #1780 round-9 MEDIUM-1: `cd ~/.claude/projects/workflow && echo x | tee *` was
// ALLOW while the literal-path spelling of the same command was BLOCK, purely
// because a leading `~`/`$` made this return null. The directory is now routed
// through the same resolver globTargetInsideWorkflowDir uses, so both spellings
// of a `cd` into the workflow dir land on the same verdict (CPR-5/CPR-8).
function staticPathArg(rawArg) {
  if (typeof rawArg !== "string" || rawArg === "" || rawArg[0] === "-") return null;
  const t = unquoteBashWord(rawArg);
  if (t === "") return null;
  const resolved = resolveDirSpelling(t);
  if (/[$`]/.test(resolved)) return null;
  return resolved;
}

// #1780 round-13 codex HIGH-2: commandCwd() recognized `cd` and NOTHING else, so
// every other spelling of "change directory" left the tracked cwd sitting at the
// tool's original directory. Measured bypass:
//
//     pushd "$CLAUDE_WORKFLOW_DIR" && printf x | tee *
//
// The shell really is inside the workflow dir when the bare `*` glob is expanded,
// but ctx.cwd (built from this function in ../bash-scan/scan.js and
// ../bash-scan/redirect-scan.js, consumed by globTargetInsideWorkflowDir /
// targetBaseInsideWorkflowDir via resolveAgainstCwd) still resolved `*` against
// the ORIGINAL cwd, so the N-2 containment qualifier never saw that the glob
// lands on protected state — and the write was approved.
//
// Widening the set is safe by construction: like resolveDirSpelling, this
// runs in the DETECTION direction — recognizing one more directory-changing
// command can only ADD a containment hit, never clear one.
//
// PowerShell cmdlet and alias names are case-INSENSITIVE at the real runtime
// (`Set-Location`, `SL`, `Push-Location`, `CHDIR`), while ../../lib/command-ir.js
// keeps cmd0 case-PRESERVED, so membership folds case here — the same treatment
// PWSH_ENV_PREFIX (../../lib/case-insensitive-literal.js) encodes for the regex
// call sites. Folding case also admits bash-impossible spellings such as `CD`;
// that is deliberate over-recognition in the fail-wide direction, not an
// assumption about which shell ran the line (CPR-8: stated, not implicit).
const DIR_CHANGE_CMDS = new Set([
  "cd",                            // bash builtin / pwsh alias of Set-Location
  "pushd",                         // bash builtin / pwsh alias of Push-Location
  "set-location", "sl", "chdir",   // pwsh cmdlet + aliases
  "push-location",                 // pwsh cmdlet
]);

// codex round-14 (#1780): `pushd`/`cd` were modelled as one-way moves — nothing
// ever POPPED the stack or swapped back to OLDPWD, so the tracked cwd could only
// walk forward. Measured bypass, starting inside the workflow dir:
//
//     pushd /tmp && popd && printf x | tee *
//
// The real shell is back in the workflow dir by the time `tee *` runs (`popd`
// restores exactly what `pushd` pushed), but the old commandCwd() left the
// tracked cwd at `/tmp` forever — `popd` was not in DIR_CHANGE_CMDS at all, so
// the loop silently skipped it — and the glob was approved as "outside". `cd -`
// has the identical shape via OLDPWD instead of a stack. Both are now modelled
// as real inverses of the forward moves (a directory stack for push/pop, an
// OLDPWD slot for the `-` swap) rather than being folded into "unresolvable ->
// leave cwd unchanged", because that fallback is exactly the bug: an unresolved
// pop leaves the STALE forward-moved cwd in place instead of undoing it.
const POP_CMDS = new Set([
  "popd",           // bash builtin / pwsh alias of Pop-Location
  "pop-location",   // pwsh cmdlet
]);

// Commands whose bare `-` argument means "swap with OLDPWD" (bash `cd -`; pwsh
// has no direct equivalent, but folding it into the same set for Set-Location/
// sl/chdir is deliberate over-recognition in the fail-wide direction, same
// doctrine as case-folding DIR_CHANGE_CMDS above). `pushd`/`push-location` are
// excluded: bash's `pushd` treats a bare `-` as a usage error, not an OLDPWD
// swap, so folding it in would misdirect the stack instead of widening detection.
const OLDPWD_SWAP_CMDS = new Set(["cd", "set-location", "sl", "chdir"]);

// `pushd +1` / `pushd -0` (and Push-Location's stack forms) ROTATE the directory
// stack and name no path at all. Such an argument must not be mistaken for a
// relative directory: it is treated exactly like a `cd` whose argument could not
// be resolved statically — the cwd is left unchanged (the `arg == null` line
// below). Precisely modelling the rotation itself is not attempted (CPR-8 named
// exception): it need not be, since leaving cwd unchanged is what happens when
// this loop cannot resolve ANY directory-changing argument, and rotation forms
// are rare enough that the residual-indirection clauses in
// classifyBashWriteTarget remain the backstop for them.
const DIR_STACK_ROTATION_RE = /^[+-]\d+$/;

function isDirChangeCmd(cmd0) {
  return typeof cmd0 === "string" && cmd0 !== "" && DIR_CHANGE_CMDS.has(cmd0.toLowerCase());
}

function isPopCmd(cmd0) {
  return typeof cmd0 === "string" && cmd0 !== "" && POP_CMDS.has(cmd0.toLowerCase());
}

// codex round-14 sibling sweep (MEDIUM, MUST): `command cd <wf>` and
// `builtin cd <wf>` change the directory exactly like bare `cd` — `command`/
// `builtin` only suppress function/alias lookup, they do not change what the
// builtin does — but seg.cmd0 for those lines is the WRAPPER word, so the
// isDirChangeCmd test above never saw the real command. Measured live bypass
// via the actual hook: `cd <wf> && printf x | tee *` blocked, `command cd <wf>
// && printf x | tee *` allowed. Unwrapping one level here (mirroring the
// wrapper's own accepted flags — `command` takes leading `-p`/`-v`/`-V`,
// `builtin` takes none) restores parity without touching command-ir.js's
// general parsing (`eval "cd <wf>"` remains out of scope for this function —
// interpreter-scan.js is the layer that re-scans interpreter bodies).
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
  // #1780 round-13: a substitution-span segment (../bash-scan/scan.js) is
  // APPENDED after the ordinary segments, so its array index says nothing about
  // where it sits in the command text. sourceOrderView() hands back the reading
  // that segment actually came from, in true source order (CPR-2 — one spelling
  // of "which segments precede this one", shared with priorAssignmentsText).
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
    // security-scanner round-14 HIGH-1: `pushd -n <dir>` pushes the directory
    // onto the stack WITHOUT changing the shell's cwd (bash: `-n` = "no cd").
    // staticPathArg already drops the `-n` token itself (leading `-`), so the
    // loop below would otherwise walk straight to `<dir>` and treat it as a
    // real cd — moving the tracked cwd while the real one stays put, the exact
    // inverse of the popd/cd- bug this round set out to fix. `-n` is real-bash
    // -specific (pwsh Push-Location has no equivalent), so it is checked only
    // for `pushd`, not `push-location` — folding it in there would be
    // detection-narrowing for a flag pwsh doesn't accept.
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
