// hooks/lib/bash-write-patterns/patterns.js
// Pattern-based Bash command classifier: classify(cmd) -> "read" | "write"
// Design: fail-safe — when in doubt, returns "write". A UX guard, not a security
// boundary; ENFORCE_WORKTREE=off bypasses. Accepted false-negatives: language-level
// file writes (open()/File.write), binary tools (dd, xxd), writes through runtime
// variable expansion. Accepted false-positive: echo "a > b". FD-to-FD redirects
// (2>&1) classify as read — the posix-redirect lookahead excludes `>&<digit>`.
// echo "<<WORKFLOW_...>>" is excluded by the here-doc anchor fix. Redirects to
// /dev/null are read (the terminator set excludes `/`, so /dev/null/foo is a write);
// Windows NUL is deliberately not excluded — pwsh null-sinks have their own patterns.

"use strict";
const { resolveEffectiveCommand, resolveEffectiveArgv } = require("./segment-utils");
// Git write detection lives in a sibling module (#1401 file-split): patterns.js
// exceeded the 500-line HARD limit, so the git-write classifier was extracted.
const { isGitWriteIR, resolveGitSubArgv } = require("./git-write-ir");

const WRITE_PATTERNS = [
  // posix-redirect + tee (kind posix-redir) retired (#1400): now owned by
  // isPosixRedirWriteIR (IR-based) reached via the enforce-worktree fast-allow gate.
  // here-doc: <<EOF, <<-EOF, <<'EOF', <<"EOF"
  // spanAware:true (#1679 S-1): tested against a stripped form to avoid FP from
  // <<'EOF' / <<EOF prose inside a double-quoted argument.
  // stripDQOnly:true (#1679 S-1 fix): strip ONLY DQ content (not SQ) so that the
  // heredoc delimiter <<'EOF' is preserved for pattern matching. Full stripQuotedArgs
  // strips the SQ span 'EOF', making bash <<'EOF' indistinguishable from bare <<.
  { name: "here-doc", kind: "posix", regex: /(?:^|[\s;|&])(?:\d*)<<-?['"]?\w/, spanAware: true, stripDQOnly: true },
  // here-string: <<<
  // stripDQOnly:true: same rationale as here-doc (SQ spans must not be stripped).
  { name: "here-string", kind: "posix", regex: /<<</, spanAware: true, stripDQOnly: true },
  // PowerShell write cmdlets (kind pwsh) and aliases (kind pwsh-alias) retired
  // (#1400 / #1402 canary-7): isPwshWriteIR owns them via PWSH_CMDLET_RE in
  // bash-write-targets.js. encoded-command / ps-stop-parsing (kind pwsh-encoded)
  // retired too: isEncodedCommandWriteIR (bash-write-targets/encoded.js) is the
  // fail-closed SSOT, scoped to pwsh/powershell interpreters (not arbitrary -enc).
  // PowerShell here-strings: the here-* entries are RETAINED (not retired #1402) as
  // QUOTING_ONLY markers required by the Group A override + isSafeHeredocOnly gate;
  // isHereWriteIR (bash-write-targets/here.js) is the IR-side companion. spanAware:
  // true — @'…'@ / @"…"@ inside a DQ arg is prose, not a here-string.
  { name: "pwsh-here-single", kind: "pwsh-here", regex: /@'[\s\S]*?'@/, spanAware: true },
  { name: "pwsh-here-double", kind: "pwsh-here", regex: /@"[\s\S]*?"@/, spanAware: true },
  // Destructive file operations (kind file-op) retired (#1402 canary-7):
  // isExtendedFileOpWriteIR (bash-write-targets/file-op.js) is the SSOT; flag-gated
  // verbs (sed -i, perl -i, tar -x, dd of=) require explicit flags. pkg-mgr retired
  // to isPkgMgrWriteIR (#1411 canary-6a). git verbs retired to isGitWriteIR (#1401),
  // reaching enforce-worktree via the collect→scope pipeline as {resolveVia:"self"};
  // git-c-config-flag too (C3 returns true for `-c k=v` / --config-env regardless of
  // subcommand). gh Group A (pr/issue/repo coordination) is deliberately NOT write —
  // GitHub-side metadata only; the kind:"gh" group is retired (#1296) and isGhWriteIR
  // below is the sole SSOT. interpreter-c retired to isInterpreterCWriteIR (#1411
  // canary-6a) in hooks/lib/bash-write-targets.js.
];

// gh "Group A" coordination commands: pr/issue/repo lifecycle that touch
// GitHub-side metadata only (never tracked repo content). When the only "write"
// trigger is heredoc/here-string (multi-line body argument), override read.
const GH_GROUP_A_REGEX = /\bgh\b\s+(?:pr\s+(?:create|edit|close|comment|review)|issue\s+(?:create|edit|close|comment)|repo\s+(?:create|edit|rename|archive))\b/;

// Known dispatcher scripts whose inline --body/--title args are safe to strip.
// SECURITY: matched by full known-path suffix (not basename alone) so that
// a script merely named issue-create-dispatch.sh at an arbitrary path cannot
// gain Group A override behavior.
const KNOWN_DISPATCH_SUFFIXES = [
  "bin/github-issues/issue-create-dispatch.sh",
  "bin/github-issues/issue-create.sh",
];

// WRITE_PATTERNS names that are merely quoting/heredoc shapes — they signal a
// multi-line string argument, not file I/O.
const QUOTING_ONLY_NAMES = new Set([
  "here-doc", "here-string", "pwsh-here-single", "pwsh-here-double",
]);

// Pattern kinds where classify() tests the stripped (quote-removed) command.
// - posix-redir (posix-redirect, tee): redirect chars inside quoted args (#460)
//   and `tee` in quoted prose must not false-positive.
// - git (#692): git verbs inside quoted args must not false-positive, since the
//   `\bgit\b.*\bverb\b` regexes span quoted prose without stripping.
// gh is NOT in STRIP_KINDS — the kind:"gh" group was retired (#1296) and
// isGhWriteIR works on parsed argv, unaffected by quote-stripping. "pkg-mgr"
// (AT-DP1 #416), file-op, pwsh-alias and pwsh-encoded were removed likewise; the
// here-* entries are kind "posix"/"pwsh-here" and never strip. The Set is now
// empty, so classify() no longer strips quoted args for any write-path kind.
const STRIP_KINDS = new Set();

// Write command words that, when quoted at command-position, must still be
// classified as write (#515). git/npm/gh excluded — too many false positives.
// sed/perl/tar excluded from QUOTED_COMMAND_WORD_WRITE_NAMES: their write mode
// requires an explicit flag (-i / -x). Quoted command-position presence alone
// does not imply a write. isExtendedFileOpWriteIR covers the flag-gated path.
const QUOTED_COMMAND_WORD_WRITE_NAMES = new Set([
  "tee", "rm", "mv", "cp", "patch", "touch", "chmod", "dd", "rsync",
  "unzip", "gunzip", "bunzip2", "sc", "ac", "ni", "ri", "mi", "ci",
]);

// Reason-text guard: reject expansion triggers inside a bash double-quoted string.
// Dangerous: $(  command substitution; ${  parameter expansion (brace form); $[  arithmetic expansion;
//            `   command substitution; "  quote termination.
// Safe (now allowed): bare $WORD / $IDENTIFIER — shell does expand these in DQ context,
//   but the echo output is just the variable's value; not a write operation.
//
// Bare \ is safe: only a bash escape when immediately followed by one of
// { $ ` " \ newline }. Those second chars are already covered above.
const UNSAFE_REASON_CHARS = /\$[({[]|[`"]/;

// resolveGhSubArgv: skip leading gh GLOBAL FLAGS so the subcommand is read from
// its effective position, not shifted by a preceding flag.
// #1296 retire bypass class: the retired regex `\bgh\b.*\bpr\b.*\bmerge\b` was
// order-tolerant, so `gh -R owner/repo pr merge 123` still matched. The IR
// replacement uses strict positional matching (sub0/sub1), so a global flag before
// the subcommand shifted argv → sub0="-R" → detection returned false → the gh
// mutation fast-allowed with NO session-scope enforcement against an arbitrary
// `-R owner/repo` target. Value-taking global flags consume a following token (or
// the attached =value form): -R/--repo, --hostname. Any other leading `-` token is
// a lone boolean flag (skip just it), to avoid over-skipping the subcommand.
const GH_VALUE_TAKING_GLOBAL_FLAGS = new Set(["-R", "--repo", "--hostname"]);
function resolveGhSubArgv(ghArgv) {
  let i = 0;
  while (i < ghArgv.length) {
    const tok = ghArgv[i];
    if (typeof tok !== "string" || tok[0] !== "-") break; // first non-flag = effective subcommand
    if (tok === "--") break; // end-of-options: nothing after it is a global flag
    const eq = tok.indexOf("=");
    const flagName = eq === -1 ? tok : tok.slice(0, eq);
    if (eq !== -1) {
      // attached =value form (e.g. --repo=o/r) — skip the single token
      i += 1;
    } else if (GH_VALUE_TAKING_GLOBAL_FLAGS.has(flagName)) {
      // value-taking flag with separate value (e.g. -R o/r) — skip flag + value
      i += 2;
    } else {
      // unknown/boolean lone flag — skip just it
      i += 1;
    }
  }
  return ghArgv.slice(i);
}

// isGhWriteIR: IR-owned gh write detector. The kind:"gh" WRITE_PATTERNS group
// has been removed (#1296); isGhWriteIR is now the sole SSOT for gh write detection.
function isGhWriteIR(ir) {
  if (!ir || ir.parseFailure === true) return false;
  if (!ir.segments || ir.segments.length === 0) return false;

  for (const seg of ir.segments) {
    // Resolve the effective gh argv for this segment (direct, env-prefix, or VAR=val-prefix).
    // argv in IR excludes cmd0 — it starts with the first argument after the command name.
    let ghArgv = null;
    if (seg.cmd0 === "gh") {
      ghArgv = seg.argv; // argv already excludes cmd0
    } else if (seg.cmd0 === "env" && Array.isArray(seg.argv) && seg.argv.length > 0) {
      // `env VARNAME=val gh ...` form — synthetic seg so resolveEffectiveCommand skips leading assignments
      const synthSeg = { cmd0: seg.argv[0], argv: seg.argv.slice(1) };
      if (resolveEffectiveCommand(synthSeg) === "gh") {
        ghArgv = resolveEffectiveArgv(synthSeg);
      }
    } else if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(seg.cmd0) && Array.isArray(seg.argv)) {
      // `VAR=val gh ...` form (inline env assignment as cmd0)
      if (resolveEffectiveCommand(seg) === "gh") {
        ghArgv = resolveEffectiveArgv(seg);
      }
    }
    if (!ghArgv || ghArgv.length === 0) continue;

    // Skip leading gh global flags (and their values) so sub0/sub1 read from the
    // effective subcommand position — closes the global-flag-before-subcommand
    // bypass (#1296 retire; see resolveGhSubArgv). Composes with the env-prefix /
    // VAR=val resolution above (that ran first, so subArgv starts after `gh`).
    const subArgv = resolveGhSubArgv(ghArgv);
    if (subArgv.length === 0) continue;

    const sub0 = subArgv[0];
    const sub1 = subArgv[1];
    const sub2 = subArgv[2];

    if (sub0 === "pr" && sub1 === "merge") return true;
    if (sub0 === "issue" && sub1 === "delete") return true;
    if (sub0 === "repo" && sub1 === "delete") return true;
    if (sub0 === "release" && sub1 != null && /^(?:create|delete|edit|upload)$/.test(sub1)) return true;
    if (sub0 === "issue" && sub1 === "create") return true;

    if (sub0 === "api") {
      // gh api -X METHOD / --method METHOD (loop is order-tolerant, matches the
      // retired regex; iterate the effective subArgv so global flags before `api`
      // are already stripped).
      for (let i = 1; i < subArgv.length; i++) {
        const tok = subArgv[i];
        if (tok === "-X" || tok === "--method") {
          const method = subArgv[i + 1];
          if (method && /^(?:POST|PUT|PATCH|DELETE)$/i.test(method)) return true;
        // -X=? preserves the retired gh-api-mutate regex's -X= (equals) coverage (#1296)
        } else if (/^-X=?(?:POST|PUT|PATCH|DELETE)$/i.test(tok) || /^--method=(?:POST|PUT|PATCH|DELETE)$/i.test(tok)) {
          return true;
        }
      }
      // gh api PUT repos/.../contents/...
      if (sub1 === "PUT" && sub2 != null && /^repos\/[^/\s]+\/[^/\s]+\/contents\//.test(sub2)) return true;
      // gh api POST|PATCH repos/.../git/{blobs,trees,commits,refs}
      if ((sub1 === "POST" || sub1 === "PATCH") && sub2 != null && /^repos\/[^/\s]+\/[^/\s]+\/git\/(?:blobs|trees|commits|refs)/.test(sub2)) return true;
    }
  }

  return false;
}

module.exports = { WRITE_PATTERNS, GH_GROUP_A_REGEX, KNOWN_DISPATCH_SUFFIXES, QUOTING_ONLY_NAMES, STRIP_KINDS, QUOTED_COMMAND_WORD_WRITE_NAMES, UNSAFE_REASON_CHARS, isGhWriteIR, isGitWriteIR, resolveGitSubArgv, resolveGhSubArgv };
