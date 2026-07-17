// hooks/lib/bash-write-patterns/patterns.js
// Pattern-based Bash command classifier: classify(cmd) -> "read" | "write"
//
// Design: fail-safe — when in doubt, returns "write" (false positive is preferred).
// This is a UX guard, not a security boundary. Use ENFORCE_WORKTREE=off to bypass.
//
// Accepted false-negatives (detected as "read" even though they write):
//   - Python/Ruby/Perl file writes via language constructs: open(), File.write, etc.
//   - Binary write tools: dd, xxd, etc.
//   - Writes through variables expanded at shell runtime: cmd=$(cat) > file
//
// Accepted false-positives (detected as "write" even though they don't write files):
//   - echo "a > b" with quoted '>' inside the argument
// Note: FD-to-FD redirects (cmd 2>&1, cmd 1>&2) are correctly classified as read —
// the posix-redirect lookahead excludes `>&<digit>` (see line 28).
// Note: echo "<<WORKFLOW_...>>" is NOT a false-positive — the here-doc anchor fix excludes it.
// Note: redirects to /dev/null (e.g. 2>/dev/null) are excluded from write — null-sink
//       discards output and is common in read-only commands like `git status 2>/dev/null`.
//       The lookahead uses (?=\s|[;|&)]|$) not \b — `)` accepts 2>/dev/null inside $(...) (#359);
//       /dev/null/foo remains a write because `/` is not in the terminator set.
//       Windows NUL is intentionally NOT excluded: this pattern is for POSIX bash commands
//       only. PowerShell null-sink uses Out-Null/> $null and is handled by pwsh-specific patterns.

"use strict";
const { resolveEffectiveCommand, resolveEffectiveArgv } = require("./segment-utils");
// Git write detection lives in a sibling module (#1401 file-split): patterns.js
// exceeded the 500-line HARD limit, so the git-write classifier was extracted.
const { isGitWriteIR, resolveGitSubArgv } = require("./git-write-ir");

const WRITE_PATTERNS = [
  // posix-redirect + tee (kind posix-redir) retired (#1400): now owned by
  // isPosixRedirWriteIR (IR-based) reached via the enforce-worktree fast-allow gate.
  // here-doc: <<EOF, <<-EOF, <<'EOF', <<"EOF"
  { name: "here-doc", kind: "posix", regex: /(?:^|[\s;|&])(?:\d*)<<-?['"]?\w/ },
  // here-string: <<<
  { name: "here-string", kind: "posix", regex: /<<</ },
  // PowerShell write cmdlets (kind pwsh) retired (#1400): now owned by isPwshWriteIR.
  // PowerShell write aliases (kind pwsh-alias) retired (#1402 canary-7): now owned by
  // isPwshWriteIR (IR-based) via PWSH_CMDLET_RE in bash-write-targets.js.
  // PowerShell encoded / bypass
  // encoded-command / ps-stop-parsing (kind pwsh-encoded) retired (#1402 canary-7):
  // isEncodedCommandWriteIR (bash-write-targets/encoded.js) is the fail-closed SSOT.
  // Scoped to pwsh/powershell interpreters (not arbitrary -enc flags).
  // PowerShell here-strings
  // here-doc/here-string here-* entries are RETAINED (not retired #1402): they are
  // QUOTING_ONLY markers required by the Group A override + isSafeHeredocOnly gate.
  // isHereWriteIR (bash-write-targets/here.js) is the IR-side read/write companion.
  { name: "pwsh-here-single", kind: "pwsh-here", regex: /@'[\s\S]*?'@/ },
  { name: "pwsh-here-double", kind: "pwsh-here", regex: /@"[\s\S]*?"@/ },
  // Destructive file operations (kind file-op) retired (#1402 canary-7):
  // isExtendedFileOpWriteIR (bash-write-targets/file-op.js) is the SSOT.
  // Flag-gated verbs (sed -i, perl -i, tar -x, dd of=) require explicit flags.
  // pkg-mgr (npm/pnpm/yarn/pip/uv/cargo/go) retired to IR (#1411 canary-6a).
  // isPkgMgrWriteIR in hooks/lib/bash-write-targets/pkg-mgr.js is the SSOT.
  // git mutating subcommands (kind git) retired from WRITE_PATTERNS (#1401):
  // the 18 git write forms + config-injection are now owned by isGitWriteIR
  // (IR-based SSOT). git write reaches the enforce-worktree main-worktree-allows
  // predicates via the collect→scope pipeline as a {resolveVia:"self"} target.
  // gh mutating subcommands.
  // Only commands that modify repo content or are destructive are kept here (Group B).
  // Coordination commands (Group A: gh pr create/edit/close/comment/review,
  // gh issue create/edit/close/comment, gh repo create/edit/rename/archive)
  // are intentionally NOT classified as write — they only touch GitHub-side
  // metadata and do not change repo content, so they require neither worktree
  // enforcement nor session-scope check.
  // The kind:"gh" WRITE_PATTERNS group has been retired (#1296). gh write
  // detection is now owned solely by isGhWriteIR (IR-based SSOT) below.
  // interpreter-c (bash/sh/zsh/pwsh -c/-Command/-EncodedCommand) retired to IR (#1411 canary-6a).
  // isInterpreterCWriteIR in hooks/lib/bash-write-targets.js is the SSOT.
  // git-c-config-flag (kind git) retired (#1401): config-injection reachability
  // is now owned by isGitWriteIR (C3) — it returns true for `-c k=v` / --config-env
  // regardless of subcommand, so the fast-allow gate does not exit before
  // hasGitHooksBypass / rejectRceGitFlags run on the raw command.
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
// - posix-redir (posix-redirect, tee): redirect chars inside quoted args
//   (e.g. `grep -nE "pattern > match" file`, #460) and `tee` in quoted prose
//   (e.g. `doc-append --subject "tee output"`) must not false-positive.
// - git (#692): git verbs inside quoted args (e.g. `grep -n "git push" file`)
//   must not false-positive. The git-commit / git-push / git-merge / etc.
//   regexes use `\bgit\b.*\bverb\b` which span quoted prose without stripping.
// gh: NOT in STRIP_KINDS — the kind:"gh" WRITE_PATTERNS group was retired (#1296);
//   gh write detection is now owned solely by isGhWriteIR (IR-based SSOT below),
//   which operates on parsed argv tokens and is unaffected by quote-stripping.
// AT-DP1 (#416): "pkg-mgr" has been removed from STRIP_KINDS because the
// pkg-mgr WRITE_PATTERNS entries were retired to isPkgMgrWriteIR (#1411 canary-6a).
// STRIP_KINDS: file-op/pwsh-alias/pwsh-encoded retired (#1402 canary-7). here-*
// entries stay in WRITE_PATTERNS as QUOTING_ONLY markers but are kind:"posix"/
// "pwsh-here" (never in STRIP_KINDS — original-cmd scan preserved). The Set is
// now empty; classify() no longer strips quoted args for any write-path kind.
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
//
// #1296 retire bypass class: the retired regex `\bgh\b.*\bpr\b.*\bmerge\b` was
// order-tolerant, so `gh -R owner/repo pr merge 123` still matched. The IR
// replacement below uses strict positional matching (sub0/sub1), so a global
// flag before the subcommand (e.g. `gh -R o/r pr merge`) shifted argv → sub0="-R"
// → detection returned false → the gh mutation fast-allowed with NO session-scope
// enforcement against an arbitrary `-R owner/repo` target. Skipping the leading
// global flags here closes that out-of-session-repo bypass.
//
// Value-taking global flags consume a following token (or use the attached =value
// form): -R/--repo (owner/repo), --hostname (host). Any other leading `-`token is
// treated as a lone boolean flag (skip just it) — we do NOT consume a following
// value for unknown flags, to avoid over-skipping the subcommand.
const GH_VALUE_TAKING_GLOBAL_FLAGS = new Set(["-R", "--repo", "--hostname"]);
function resolveGhSubArgv(ghArgv) {
  let i = 0;
  while (i < ghArgv.length) {
    const tok = ghArgv[i];
    if (typeof tok !== "string" || tok[0] !== "-") break; // first non-flag = effective subcommand
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

  // Find the first gh segment (direct, env-prefix `env VAR=val gh ...`, or VAR=val-prefix `VAR=val gh ...`).
  // argv in IR excludes cmd0 — it starts with the first argument after the command name.
  let ghArgv = null;
  for (const seg of ir.segments) {
    if (seg.cmd0 === "gh") {
      ghArgv = seg.argv; // argv already excludes cmd0
      break;
    }
    // `env VARNAME=val gh ...` form — synthetic seg so resolveEffectiveCommand skips leading assignments
    if (seg.cmd0 === "env" && Array.isArray(seg.argv) && seg.argv.length > 0) {
      const synthSeg = { cmd0: seg.argv[0], argv: seg.argv.slice(1) };
      if (resolveEffectiveCommand(synthSeg) === "gh") {
        ghArgv = resolveEffectiveArgv(synthSeg);
        break;
      }
    }
    // `VAR=val gh ...` form (inline env assignment as cmd0)
    if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(seg.cmd0) && Array.isArray(seg.argv)) {
      if (resolveEffectiveCommand(seg) === "gh") {
        ghArgv = resolveEffectiveArgv(seg);
        break;
      }
    }
  }
  if (!ghArgv || ghArgv.length === 0) return false;

  // Skip leading gh global flags (and their values) so sub0/sub1 read from the
  // effective subcommand position — closes the global-flag-before-subcommand
  // bypass (#1296 retire; see resolveGhSubArgv). Composes with the env-prefix /
  // VAR=val resolution above (that ran first, so subArgv starts after `gh`).
  const subArgv = resolveGhSubArgv(ghArgv);
  if (subArgv.length === 0) return false;

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

  return false;
}

module.exports = { WRITE_PATTERNS, GH_GROUP_A_REGEX, KNOWN_DISPATCH_SUFFIXES, QUOTING_ONLY_NAMES, STRIP_KINDS, QUOTED_COMMAND_WORD_WRITE_NAMES, UNSAFE_REASON_CHARS, isGhWriteIR, isGitWriteIR, resolveGitSubArgv };
