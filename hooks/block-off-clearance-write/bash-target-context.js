// hooks/block-off-clearance-write/bash-target-context.js
// Context-aware classification of a single Bash WRITE TARGET (a redirect target
// or an argv path candidate), for the block-off-clearance-write entrypoint.
//
// A bare basename test is not enough for two reasons, both confirmed bypasses:
//
//   N-1 (#1780) — the protected tail can be hidden by shell syntax the hook
//   sees BEFORE the shell resolves it. Backslash escapes and intra-word quoting
//   are handled by the Bash-word normalizer in ../lib/protected-basenames.js;
//   what is left here is VARIABLE SPLICING (`S=.workflow-off; … > <wf>/s1$S`).
//   The sibling case where the WHOLE argv token is `$NAME` was already covered
//   by bash-scan.js's VAR_REF_RE, but concatenation (`<wf>/s1$S`) and redirect
//   targets were not — an asymmetry (CPR-5). substituteAssignments() resolves
//   `$NAME` / `${NAME}` ANYWHERE inside the target against the same contiguous
//   preceding assignment chain, and anything still unresolved fails closed when
//   the chain mentions a protected name at all.
//
//   N-2 (#1780) — a PURE-WILDCARD target (`<wf>/*`, `<wf>/s1*`, `<wf>/???…`)
//   commits no literal character to the protected suffix, so the glob matcher in
//   ../lib/basename-glob-normalize.js deliberately reports it as a non-match
//   (otherwise `rm -rf build/*` would block). That named exception is only safe
//   while such a glob cannot land on a protected file — so the exception is
//   qualified here by DIRECTORY CONTAINMENT: a glob basename whose directory
//   resolves at/under getWorkflowDir() fails closed, regardless of literal
//   overlap. Directories outside the workflow dir are untouched, so ordinary
//   bulk operations keep working.
//
// Unresolvable directories deliberately fall back to "not contained" (approve):
// turning every relative glob into a block would over-block ordinary work, which
// is the failure mode this hook has regressed into before.
"use strict";

const path = require("path");
const {
  classifyProtectedPath,
  classifyProtectedBashToken,
  unquoteBashWord,
  mentionsProtectedName,
  TOKEN_MENTION_RE,
} = require("../lib/protected-basenames");
const { hasGlobMetachar } = require("../lib/basename-glob-normalize");
const { resolvesUnder } = require("../lib/path-containment");
// #1780 round-13: "which segments really precede this one" — see the block
// comment above sourceOrderView() in ../lib/substitution-spans.js.
const { sourceOrderView } = require("../lib/substitution-spans");
// The SAME static expander marker-gate.js and scope-checks.js already use for
// $HOME / ~ (CPR-2) — one spelling of "what does this directory resolve to".
const { expandStaticShellTokens } = require("../lib/bash-write-targets/helpers");

// A `NAME=value` prefix on an argv token is an OPERAND, not a path component
// (`dd of=<wf>/s1*`). Stripped only for DIRECTORY extraction — the basename
// matchers already ignore it, since they read the tail.
const OPERAND_PREFIX_RE = /^[A-Za-z_][A-Za-z0-9_]*=/;
const VAR_REF_IN_TEXT_RE = /\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)/g;
const WIN_ABS_RE = /^[A-Za-z]:[\\/]/;
const UNRESOLVABLE_DIR_RE = /[$`*?[\]]/;

// #1780 round-5 MEDIUM-4 (CPR-5): `$NAME` and `` `cmd` `` are symmetric members
// of one class — text the SHELL replaces before the write lands — so "does this
// target still hold an unresolved expansion?" must ask about both. Testing only
// `$` meant a backtick-spliced target (`` echo x > `printf s1.<marker>` ``) was
// declared fully resolved and cleared on its literal spelling alone. (The
// substitution BODY is separately re-scanned as command text by ./bash-scan.js;
// this half is about the target that body produces.)
const EXPANSION_CHAR_RE = /[$`]/;

// An ANSI-C quoted segment `$'…'` is QUOTING, not an expansion: bash decodes it
// statically and the shell never substitutes anything into it. Its leading `$`
// nonetheless satisfies EXPANSION_CHAR_RE, which would make every ANSI-C-spelled
// target look like residual indirection — and the round-10 MEDIUM-1 clause below
// decides on exactly that flag, so a fully static `echo x > $'<wf>/plain.txt'`
// would be blocked with a "dynamically-named" reason that is simply untrue.
// The segment is therefore removed before the residual test only; `text` itself
// keeps its ANSI-C form, because the basename normalizer in
// ../lib/protected-basenames.js decodes it there (that is what catches
// `$'<wf>/s1.workflow-of\x66'`), and dropping it here would lose the match.
const ANSI_C_SEGMENT_RE = /\$'(?:\\.|[^'])*'/g;
function withoutAnsiCSegments(text) {
  return String(text).replace(ANSI_C_SEGMENT_RE, "");
}

// Same assignment shape bash-scan.js / interpreter-scan.js already look for,
// including the pwsh `$env:NAME=` prefix (CPR-2 — one spelling of the lookup).
function lookupAssignedValue(assignText, varName) {
  if (typeof assignText !== "string" || assignText === "") return null;
  // H-4 (#1780 round-4): `$ENV:`/`$Env:` are the same prefix — folded via the
  // shared PWSH_ENV_PREFIX so all three assignment lookups agree (CPR-2/CPR-5).
  const { PWSH_ENV_PREFIX } = require("../lib/case-insensitive-literal");
  const re = new RegExp("(?:^|[\\s;&|]|\\$" + PWSH_ENV_PREFIX + ")" + varName + "=(\\S+)", "m");
  const m = re.exec(assignText);
  return m ? m[1] : null;
}

// substituteAssignments(text, assignText):
//   { text, substituted, unresolved }
// `unresolved` is true when a `$` survives substitution — the caller decides
// whether that is fail-closed material (it is, but only when the assignment
// chain mentions a protected name; `> $LOG` must stay approved).
function substituteAssignments(text, assignText) {
  if (typeof text !== "string") return { text: "", substituted: false, unresolved: false };
  if (!EXPANSION_CHAR_RE.test(text)) return { text, substituted: false, unresolved: false };
  let out = text;
  let substituted = false;
  for (let pass = 0; pass < 4 && out.includes("$"); pass++) {
    let changed = false;
    out = out.replace(VAR_REF_IN_TEXT_RE, (m, braced, bare) => {
      const value = lookupAssignedValue(assignText, braced || bare);
      if (value === null) return m;
      changed = true;
      substituted = true;
      return value;
    });
    if (!changed) break;
  }
  return {
    text: out,
    substituted,
    unresolved: EXPANSION_CHAR_RE.test(withoutAnsiCSegments(out)),
  };
}

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
// but ctx.cwd (built from this function in ./bash-scan/scan.js and
// ./bash-scan/redirect-scan.js, consumed by globTargetInsideWorkflowDir /
// targetBaseInsideWorkflowDir via resolveAgainstCwd) still resolved `*` against
// the ORIGINAL cwd, so the N-2 containment qualifier never saw that the glob
// lands on protected state — and the write was approved.
//
// Widening the set is safe by construction: like resolveDirSpelling above, this
// runs in the DETECTION direction — recognizing one more directory-changing
// command can only ADD a containment hit, never clear one.
//
// PowerShell cmdlet and alias names are case-INSENSITIVE at the real runtime
// (`Set-Location`, `SL`, `Push-Location`, `CHDIR`), while ../lib/command-ir.js
// keeps cmd0 case-PRESERVED, so membership folds case here — the same treatment
// PWSH_ENV_PREFIX (../lib/case-insensitive-literal.js) encodes for the regex
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

// resolveWorkflowDir(): the SAME getWorkflowDir() the rest of the hook chain
// uses (CPR-2). Lazy-required and fail-soft: an unresolvable workflow dir simply
// disables the containment qualifier rather than blocking everything.
//
// codex round-5 HIGH: this used to return a case-FOLDED lexical path, folded on
// `process.platform === "win32"` alone, and containment was then a `startsWith`
// on that string. Both halves were wrong — a symlink inside the workflow dir
// escaped a lexical prefix test, and a case-insensitive volume that is not
// Windows (macOS by default, a share mounted under WSL) made a case-only
// spelling difference read as "outside". The one filesystem-aware
// implementation, shared with hooks/enforce-worktree/, now answers both
// (hooks/lib/path-containment.js). The raw directory is returned; resolution
// happens inside resolvesUnder().
function resolveWorkflowDir() {
  try {
    const { getWorkflowDir } = require("../workflow-state");
    const dir = getWorkflowDir();
    return dir ? String(dir) : null;
  } catch (_e) {
    return null;
  }
}

// A Bash word can be read two ways; test both so neither spelling escapes.
function pathSpellings(rawText) {
  const unquoted = unquoteBashWord(rawText);
  const folded = String(rawText).replace(/\\/g, "/");
  return unquoted === folded ? [unquoted] : [unquoted, folded];
}

// resolveDirSpelling(dir, workflowDir): the directory a target's dirname
// actually names, with `~`, `$HOME`/`${HOME}` and `$CLAUDE_WORKFLOW_DIR`
// resolved. Returns the input unchanged when nothing could be resolved.
//
// DIRECTION DISCIPLINE (the mirror of the block comment in
// ./interpreter-scan.js; see also the header of
// ../lib/basename-glob-normalize/brace-ansi-expand.js): this resolver runs in
// the DETECTION direction. Its only consumer asks "does this directory land
// inside the workflow dir?", where resolving one more spelling can only ADD a
// block and never clear one — so it must fail WIDE.
//
// #1780 round-9 MEDIUM-1: the qualifier used to `continue` — i.e. CLEAR the
// route — the instant the directory spelling contained a `$`, and the relative
// branch `continue`d on `~` because path.isAbsolute("~/…") is false. The
// workflow dir's canonical spelling is `~/.claude/projects/workflow`, so the
// NATURAL way to write it was the bypassing way: `tee $HOME/.claude/projects/
// workflow/*`, `${HOME}/…/*`, `~/…/*` and `$CLAUDE_WORKFLOW_DIR/*` were all
// measured ALLOW while the literal spelling BLOCKed. A glob cannot create a
// file, so this is not a marker forge — it is a CONTENT forge (bin/request-off-
// clearance mints an UNSIGNED token, so rewriting a live token file can flip
// `target`/`claimed_target`) and a clean `tee`-truncation DoS on clearance
// state. Abandoning on the first `$` is now reserved for spellings that survive
// expansion.
const ENV_REF_RE = /\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)/g;
const WORKFLOW_DIR_ENV_NAME = "CLAUDE_WORKFLOW_DIR";

function resolveDirSpelling(dir, workflowDir) {
  if (typeof dir !== "string" || dir === "") return dir;
  let out = dir;
  if (out[0] === "~" || out.includes("$")) {
    try {
      const expanded = expandStaticShellTokens(out, { fromQuotedContext: "unquoted" });
      if (typeof expanded === "string" && expanded !== "") out = expanded;
    } catch (_e) { /* fail-soft: keep the literal spelling and let the caller decide */ }
  }
  // expandStaticShellTokens is scoped to $HOME / ~ / the plans dir, so the one
  // env var that NAMES this very directory is resolved here — from the resolved
  // workflow dir itself (CPR-2: getWorkflowDir is the SSOT), falling back to the
  // process environment for any other variable whose value is a plain path.
  if (out.includes("$")) {
    out = out.replace(ENV_REF_RE, (m, braced, bare) => {
      const name = braced || bare;
      const value = name === WORKFLOW_DIR_ENV_NAME
        ? (workflowDir || resolveWorkflowDir() || process.env[name])
        : process.env[name];
      if (typeof value !== "string" || value === "" || UNRESOLVABLE_DIR_RE.test(value)) return m;
      return value;
    });
  }
  return out;
}

// resolveAgainstCwd(p, ctx): `p` as an absolute path, or null when it cannot be
// made absolute (still dynamic, or relative with no known cwd). One spelling of
// the resolution step both qualifiers below need (CPR-2).
function resolveAgainstCwd(p, ctx, wfDir) {
  let out = resolveDirSpelling(p, wfDir);                // ~ / $HOME / $CLAUDE_WORKFLOW_DIR
  if (UNRESOLVABLE_DIR_RE.test(out)) return null;        // STILL dynamic or itself a glob
  if (!path.isAbsolute(out) && !WIN_ABS_RE.test(out)) {
    if (!ctx || !ctx.cwd) return null;                   // unresolvable → prior behavior
    out = path.resolve(ctx.cwd, out);
  }
  return out;
}

// #1780 round-10 MEDIUM-1 (CPR-4): the N-2 qualifier asked "does the basename
// carry a GLOB metachar?", but a glob is only one member of the class "the name
// the write lands on is NOT the name the hook can see". A residual expansion —
// `$(`, a backtick, or a `$` that substituteAssignments could not resolve — is
// the other member, and it is the STRONGER one: a glob can only ever match a
// file that already exists, while a substitution can CREATE the exact protected
// basename. Measured ALLOW before this: `touch "$(printf '%s%s' <wf>/s1.workflow
// -off)"` and `touch <wf>/s1.workflow$(printf -- -off)`, while the `$VAR` sibling
// of the same shape already blocked.
const RESIDUAL_EXPANSION_RE = /[$`]/;

// targetBaseInsideWorkflowDir(rawText, ctx, baseIsSuspect): true iff some
// spelling of the target has a basename `baseIsSuspect` rejects as statically
// resolvable AND a DIRECTORY that resolves at/under the workflow dir.
function targetBaseInsideWorkflowDir(rawText, ctx, baseIsSuspect) {
  if (typeof rawText !== "string" || rawText === "") return false;
  const wfDir = ctx && ctx.workflowDir;
  if (!wfDir) return false;
  for (const spelling of pathSpellings(rawText)) {
    const stripped = spelling.replace(OPERAND_PREFIX_RE, "");
    const cut = Math.max(stripped.lastIndexOf("/"), stripped.lastIndexOf("\\"));
    const base = cut === -1 ? stripped : stripped.slice(cut + 1);
    if (!baseIsSuspect(base)) continue;
    const dir = resolveAgainstCwd(cut === -1 ? "." : (stripped.slice(0, cut) || "/"), ctx, wfDir);
    if (dir === null) continue;
    // allowEqual: true — a target whose directory IS the workflow dir
    // (`<wf>/s1*`, `<wf>/s1.workflow$(…)`) is exactly the case this exists for.
    // onUnknown: true (codex scanner C) — this predicate ARMS a block; an
    // unresolvable directory (e.g. a symlink chain crafted to make
    // realResolve() throw) must not be silently treated as "not contained".
    if (resolvesUnder(dir, wfDir, { allowEqual: true, onUnknown: true })) return true;
  }
  return false;
}

// globTargetInsideWorkflowDir(rawText, ctx): true iff the target's BASENAME
// carries a glob metachar AND its DIRECTORY resolves at/under the workflow dir.
function globTargetInsideWorkflowDir(rawText, ctx) {
  return targetBaseInsideWorkflowDir(rawText, ctx, hasGlobMetachar);
}

// dynamicTargetInsideWorkflowDir(rawText, ctx): the sibling for the OTHER member
// of the class — a basename carrying a residual expansion.
function dynamicTargetInsideWorkflowDir(rawText, ctx) {
  return targetBaseInsideWorkflowDir(rawText, ctx, (base) => RESIDUAL_EXPANSION_RE.test(base));
}

// textNamesPathInsideWorkflowDir(text, ctx): a path-like fragment ANYWHERE in
// the text — including inside a substitution BODY — that resolves at/under the
// workflow dir.
//
// This is the third evidence source for the same question, and the only one that
// survives the target being assembled INSIDE the substitution:
// `"$(printf '%s%s' <wf>/s1.workflow -off)"` has no usable directory part (its
// dirname still holds the `$(`), so the two qualifiers above cannot see it —
// but the workflow directory is still spelled out in plain text right there.
// Consulted ONLY when the target carries residual indirection, so a fully static
// write into the workflow directory keeps its existing verdict.
const PATH_FRAGMENT_RE = /[^\s'"`$(){}[\],;|&<>]*[\\/][^\s'"`$(){}[\],;|&<>]*/g;

function textNamesPathInsideWorkflowDir(text, ctx) {
  const wfDir = ctx && ctx.workflowDir;
  if (!wfDir || typeof text !== "string" || text === "") return false;
  const fragments = text.match(PATH_FRAGMENT_RE);
  if (!fragments) return false;
  for (const fragment of fragments) {
    const stripped = fragment.replace(OPERAND_PREFIX_RE, "");
    if (stripped === "" || stripped === "/" || stripped === "\\") continue;
    const resolved = resolveAgainstCwd(stripped, ctx, wfDir);
    if (resolved === null) continue;
    // onUnknown: true — same detection-direction reasoning as above.
    if (resolvesUnder(resolved, wfDir, { allowEqual: true, onUnknown: true })) return true;
  }
  return false;
}

function literalKind(text) {
  return classifyProtectedBashToken(text) || classifyProtectedPath(text);
}

// classifyBashWriteTarget(raw, assignText, ctx): "token" | "marker" |
// "workflow-glob" | "workflow-dynamic" | null — the single decision point every
// Bash write-target call site in ./bash-scan.js routes through.
function classifyBashWriteTarget(raw, assignText, ctx) {
  if (typeof raw !== "string" || raw === "") return null;
  const direct = literalKind(raw);
  if (direct) return direct;
  if (globTargetInsideWorkflowDir(raw, ctx)) return "workflow-glob";
  if (!EXPANSION_CHAR_RE.test(raw)) return null;
  const sub = substituteAssignments(raw, assignText);
  if (sub.substituted) {
    const kind = literalKind(sub.text);
    if (kind) return kind;
    if (globTargetInsideWorkflowDir(sub.text, ctx)) return "workflow-glob";
  }
  // Everything below is the RESIDUAL-INDIRECTION clause: the scanner could not
  // finish resolving this target, so it decides on EVIDENCE instead. Blanket
  // fail-closed here is not acceptable — `> $LOG`, `> "$OUT"`, `> $TMPDIR/out.txt`,
  // `> "$(mktemp)"` and `T=$(mktemp); > "$T"` are ordinary idioms — so each
  // evidence source below must name the workflow dir or a protected file.
  if (!sub.unresolved) return null;

  // #1780 round-10 MEDIUM-1 (a): the mention question used to be asked of the
  // ASSIGNMENT CHAIN alone, which is only one of the three texts in scope. The
  // raw target and its partially-substituted form carry exactly the same kind of
  // evidence and were simply never consulted (CPR-5).
  for (const evidence of [assignText, raw, sub.text]) {
    if (mentionsProtectedName(evidence)) {
      return TOKEN_MENTION_RE.test(evidence) ? "token" : "marker";
    }
  }

  // (b) the basename is not statically resolvable and its directory is the
  // workflow dir; (c) the text names a path under the workflow dir anywhere,
  // including inside the substitution body that assembles the target.
  //
  // WHERE THIS RULE STILL LOSES (named exception, CPR-8): a target assembled
  // ENTIRELY inside a substitution that references neither the workflow
  // directory nor any protected fragment — e.g. a body that reconstructs the
  // directory from pieces, reads it out of a file, or decodes it — leaves no
  // evidence in any of the three texts and is still approved here. The remaining
  // defences for that case are the substitution-body re-scan in ./bash-scan.js
  // and the Phase2 human approval prompt, not this clause.
  if (dynamicTargetInsideWorkflowDir(raw, ctx) ||
      dynamicTargetInsideWorkflowDir(sub.text, ctx) ||
      textNamesPathInsideWorkflowDir(raw, ctx) ||
      textNamesPathInsideWorkflowDir(sub.text, ctx)) {
    return "workflow-dynamic";
  }
  return null;
}

module.exports = {
  substituteAssignments,
  commandCwd,
  resolveWorkflowDir,
  globTargetInsideWorkflowDir,
  dynamicTargetInsideWorkflowDir,
  textNamesPathInsideWorkflowDir,
  classifyBashWriteTarget,
};
