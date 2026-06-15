// hooks/lib/bash-write-patterns.js
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

const { stripQuotedArgs, stripHeredocBody, stripInlineBodyArg, stripShellVarAssignment } = require("./strip-quoted-args");
const { isStrictSentinel } = require("./sentinel-patterns");

const WRITE_PATTERNS = [
  // POSIX redirects: >, >>, 1>, 2>, &>, n>  — /dev/null null-sink is excluded (see header note)
  { name: "posix-redirect", kind: "posix-redir", regex: /(?:^|[\s;|&])(?:\d*)>>?(?!>|\d)(?!&\d)(?!\s*\/dev\/null(?=\s|[;|&)]|$))/ },
  // tee (writes to file while passing through)
  { name: "tee", kind: "posix-redir", regex: /(?:^|[\s;|&])tee\b/ },
  // here-doc: <<EOF, <<-EOF, <<'EOF', <<"EOF"
  { name: "here-doc", kind: "posix", regex: /(?:^|[\s;|&])(?:\d*)<<-?['"]?\w/ },
  // here-string: <<<
  { name: "here-string", kind: "posix", regex: /<<</ },
  // PowerShell write cmdlets
  { name: "Set-Content", kind: "pwsh", regex: /\bSet-Content\b/i },
  { name: "Add-Content", kind: "pwsh", regex: /\bAdd-Content\b/i },
  { name: "Out-File", kind: "pwsh", regex: /\bOut-File\b/i },
  { name: "New-Item", kind: "pwsh", regex: /\bNew-Item\b/i },
  { name: "Remove-Item", kind: "pwsh", regex: /\bRemove-Item\b/i },
  { name: "Move-Item", kind: "pwsh", regex: /\bMove-Item\b/i },
  { name: "Copy-Item", kind: "pwsh", regex: /\bCopy-Item\b/i },
  // PowerShell write aliases
  { name: "sc-alias", kind: "pwsh-alias", regex: /(?:^|[\s;|&])sc\b/ },
  { name: "ac-alias", kind: "pwsh-alias", regex: /(?:^|[\s;|&])ac\b/ },
  { name: "ni-alias", kind: "pwsh-alias", regex: /(?:^|[\s;|&])ni\b/ },
  { name: "ri-alias", kind: "pwsh-alias", regex: /(?:^|[\s;|&])ri\b/ },
  // PowerShell encoded / bypass
  { name: "encoded-command", kind: "pwsh-encoded", regex: /-EncodedCommand\b|-enc\b/i },
  { name: "ps-stop-parsing", kind: "pwsh-encoded", regex: /(?:^|[\s;|&])--%/ },
  // PowerShell here-strings
  { name: "pwsh-here-single", kind: "pwsh-here", regex: /@'[\s\S]*?'@/ },
  { name: "pwsh-here-double", kind: "pwsh-here", regex: /@"[\s\S]*?"@/ },
  // Destructive file operations
  { name: "rm", kind: "file-op", regex: /(?:^|[\s;|&])rm\b/ },
  { name: "mv", kind: "file-op", regex: /(?:^|[\s;|&])mv\b/ },
  { name: "cp", kind: "file-op", regex: /(?:^|[\s;|&])cp\b/ },
  { name: "sed-inplace", kind: "file-op", regex: /\bsed\s+-[a-zA-Z]*i\b/ },
  { name: "perl-inplace", kind: "file-op", regex: /\bperl\s+-[a-zA-Z]*i\b/ },
  { name: "patch", kind: "file-op", regex: /(?:^|[\s;|&])patch\b/ },
  { name: "touch", kind: "file-op", regex: /(?:^|[\s;|&])touch\b/ },
  { name: "chmod", kind: "file-op", regex: /(?:^|[\s;|&])chmod\b/ },
  { name: "dd", kind: "file-op", regex: /(?:^|[\s;|&])dd\b/ },
  { name: "rsync", kind: "file-op", regex: /(?:^|[\s;|&])rsync\b/ },
  { name: "tar-extract", kind: "file-op", regex: /\btar\b.*-[a-zA-Z]*x/ },
  { name: "unzip", kind: "file-op", regex: /(?:^|[\s;|&])unzip\b/ },
  { name: "gunzip", kind: "file-op", regex: /(?:^|[\s;|&])gunzip\b/ },
  { name: "bunzip2", kind: "file-op", regex: /(?:^|[\s;|&])bunzip2\b/ },
  // Package manager installs (write to node_modules, lock files, site-packages, etc.)
  { name: "npm-write", kind: "pkg-mgr", regex: /(?:^|[\s;|&])npm\s+(?:install|ci|update|uninstall|i\b|run\b|exec\b|publish\b|pack\b|link\b)/ },
  { name: "pnpm-write", kind: "pkg-mgr", regex: /(?:^|[\s;|&])pnpm\s+(?:install|add|remove|update|run\b|exec\b|publish\b|pack\b|link\b)/ },
  { name: "yarn-write", kind: "pkg-mgr", regex: /(?:^|[\s;|&])yarn\s+(?:install|add|remove|upgrade|run\b|pack\b|publish\b|link\b|\b(?!list|info|why|outdated|audit))/ },
  { name: "pip-write", kind: "pkg-mgr", regex: /(?:^|[\s;|&])pip(?:3)?\s+(?:install|uninstall|download)\b/ },
  { name: "uv-write", kind: "pkg-mgr", regex: /(?:^|[\s;|&])uv\s+(?:pip\s+(?:install|uninstall)|add\b|remove\b|sync\b|lock\b)/ },
  { name: "cargo-write", kind: "pkg-mgr", regex: /(?:^|[\s;|&])cargo\s+(?:build|install|update|publish|clean)\b/ },
  { name: "go-write", kind: "pkg-mgr", regex: /(?:^|[\s;|&])go\s+(?:build|install|get|mod\s+(?:download|tidy|vendor))\b/ },
  // git mutating subcommands
  { name: "git-commit", kind: "git", regex: /\bgit\s+(?:-\S+(?:\s+[^-|;&\s]\S*)?\s+)*commit\b/ },
  { name: "git-push", kind: "git", regex: /\bgit\b.*\bpush\b/ },
  { name: "git-merge", kind: "git", regex: /\bgit\b.*\bmerge\b/ },
  { name: "git-rebase", kind: "git", regex: /\bgit\b.*\brebase\b/ },
  { name: "git-reset", kind: "git", regex: /\bgit\b.*\breset\b/ },
  { name: "git-am", kind: "git", regex: /\bgit\b.*\bam\b/ },
  { name: "git-apply", kind: "git", regex: /\bgit\b.*\bapply\b/ },
  { name: "git-cherry-pick", kind: "git", regex: /\bgit\b.*\bcherry-pick\b/ },
  { name: "git-revert", kind: "git", regex: /\bgit\b.*\brevert\b/ },
  // git tag: write (create/delete) but not list (-l, -v, --list, --points-at, etc.)
  { name: "git-tag-write", kind: "git", regex: /\bgit\b.*\btag\b(?!\s+(?:-[lLvnq]|--list|--sort|--contains|--merged|--no-merged|--points-at))/ },
  // git-branch-mutate: anchor flags at whitespace-delimited positions to avoid
  // false-positives where branch names contain literal "-d", "-c", etc.
  // (e.g., `git branch agents-env-consolidate` formerly matched `-c`).
  // -d/-D (delete), -m/-M (rename), -c/-C (copy) all mutate refs — write.
  // Branch deletion is gated by enforce-worktree's direct registry check
  // (isAllowedBranchDeleteWhenNotCheckedOut), which queries `git worktree list
  // --porcelain` and allows -d/-D only when the target branch is not currently
  // checked out in any worktree.
  { name: "git-branch-mutate", kind: "git", regex: /\bgit\s+(?:[^|;&]*\s)?branch\b[^|;&]*\s-[dDmMcC](?:\s|$)/ },
  { name: "git-checkout-force", kind: "git", regex: /\bgit\b.*\bcheckout\b.*(?:--|\.|\bHEAD\b)/ },
  { name: "git-restore", kind: "git", regex: /\bgit\b.*\brestore\b/ },
  { name: "git-stash-write", kind: "git", regex: /\bgit\b.*\bstash\b.*\b(?:push|pop|drop|clear|apply)\b/ },
  { name: "git-worktree-write", kind: "git", regex: /\bgit\b.*\bworktree\b.*\b(?:add|remove|prune)\b/ },
  { name: "git-add-history", kind: "git", regex: /\bgit\s+add\b(?:.*\bdocs\/history\b|.*\bCHANGELOG\.md\b)/ },
  // git update-ref: directly rewrites a ref — write op (classifier gap fix).
  { name: "git-update-ref", kind: "git", regex: /\bgit\b.*\bupdate-ref\b/ },
  // gh mutating subcommands.
  // Only commands that modify repo content or are destructive are kept here (Group B).
  // Coordination commands (Group A: gh pr create/edit/close/comment/review,
  // gh issue create/edit/close/comment, gh repo create/edit/rename/archive)
  // are intentionally NOT classified as write — they only touch GitHub-side
  // metadata and do not change repo content, so they require neither worktree
  // enforcement nor session-scope check.
  { name: "gh-pr-merge", kind: "gh", regex: /\bgh\b.*\bpr\b.*\bmerge\b/ },
  { name: "gh-issue-delete", kind: "gh", regex: /\bgh\b.*\bissue\b.*\bdelete\b/ },
  { name: "gh-repo-delete", kind: "gh", regex: /\bgh\b.*\brepo\b.*\bdelete\b/ },
  { name: "gh-release-write", kind: "gh", regex: /\bgh\b.*\brelease\b.*\b(?:create|delete|edit|upload)\b/ },
  // gh api: cover all flag forms — `-X DELETE`, `-XDELETE`, `-X=DELETE`,
  // `--method DELETE`, `--method=DELETE`.
  { name: "gh-api-mutate", kind: "gh", regex: /\bgh\b.*\bapi\b.*(?:-X[\s=]*|--method[\s=]+)(?:POST|PUT|PATCH|DELETE)\b/i },
  // gh issue create: sanctioned path is `/issue-create` (see skills/issue-create).
  // Classified as write so the enforce-worktree session-scope guard applies.
  { name: "gh-issue-create", kind: "gh", regex: /\bgh\s+issue\s+create\b/ },
  // gh api PUT to repos/<o>/<r>/contents/... — Contents API single-file write.
  // (Sanctioned wrapper: bin/lib/github-contents-write.sh.)
  { name: "gh-api-contents-put", kind: "gh", regex: /\bgh\s+api\s+(?:-X\s+)?PUT\s+repos\/[^\/\s]+\/[^\/\s]+\/contents\// },
  // gh api POST/PATCH to repos/<o>/<r>/git/{blobs,trees,commits,refs} — Git Data API.
  // (Sanctioned wrapper: bin/lib/github-git-data-write.sh.)
  { name: "gh-api-git-data-write", kind: "gh", regex: /\bgh\s+api\s+(?:-X\s+)?(?:POST|PATCH)\s+repos\/[^\/\s]+\/[^\/\s]+\/git\/(?:blobs|trees|commits|refs)/ },
  // Interpreter -c / -Command: shell/interpreter invocations with inline body.
  // Tested against ORIGINAL cmd (not stripped) — the inline body is irrelevant;
  // the interpreter call itself is always a potential write.
  // Path-qualified prefix (e.g. /bin/bash, /usr/bin/sh) is accepted via the
  // optional `(?:\S*\/)?` group so wrappers cannot evade by spelling the
  // interpreter as `/bin/bash` instead of `bash`.
  { name: "interpreter-c", kind: "interpreter",
    regex: /(?:^|[\s;|&])(?:\S*\/)?(?:bash|sh|zsh|dash|fish|pwsh|powershell|cmd)(?:\.exe)?\s+(?:-c\b|-Command\b|-EncodedCommand\b|\/c\b)/i },
  // git -c <key>=<val>: arbitrary config injection. core.sshCommand,
  // core.fsmonitor, etc. are executed by the transport — RCE-class.
  // Classify as write so isAllowedFastForwardMerge / isAllowedPushAllExcluded
  // reach the predicate-level rejectRceGitFlags guard.
  { name: "git-c-config-flag", kind: "git",
    regex: /\bgit\b[^|;&]*\s-c\s+\S+=/ },
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

// Returns true when cmd invokes a known dispatcher via bash/sh/zsh/dash.
// Quotes around the path are tolerated. Backslashes are normalised to forward
// slashes before the suffix check (Windows path support).
// Paths inside world-writable temp directories are rejected to reduce the risk
// of an attacker crafting a script whose path ends in a known suffix.
// (This is a UX guard, not a security boundary — see file header.)
function isKnownDispatchInvocation(cmd) {
  const m = cmd.match(/\b(?:bash|sh|zsh|dash)\b\s+["']?([^"'\s]+)["']?/);
  if (!m) return false;
  const path = m[1].replace(/\\/g, "/");
  if (/^\/(?:tmp|var\/tmp|dev\/shm)\//i.test(path)) return false;
  if (/^[A-Za-z]:\/(?:Users\/[^/]+\/AppData\/Local\/Temp|Windows\/Temp|Temp)\//i.test(path)) return false;
  return KNOWN_DISPATCH_SUFFIXES.some((suf) => path.endsWith(suf));
}

// WRITE_PATTERNS names that are merely quoting/heredoc shapes — they signal a
// multi-line string argument, not file I/O.
const QUOTING_ONLY_NAMES = new Set([
  "here-doc", "here-string", "pwsh-here-single", "pwsh-here-double",
]);

// Pattern kinds where classify() tests the stripped (quote-removed) command.
// - file-op (cp/mv/rm/touch/chmod etc.): write tokens inside quoted args
//   (e.g. `doc-append --subject "rm tmp"`) must not false-positive.
// - posix-redir (posix-redirect, tee): redirect chars inside quoted args
//   (e.g. `grep -nE "pattern > match" file`, #460) and `tee` in quoted prose
//   (e.g. `doc-append --subject "tee output"`) must not false-positive.
// - git (#692): git verbs inside quoted args (e.g. `grep -n "git push" file`)
//   must not false-positive. The git-commit / git-push / git-merge / etc.
//   regexes use `\bgit\b.*\bverb\b` which span quoted prose without stripping.
// - "pkg-mgr" / "gh" (#416): npm/gh verbs in sentinel echo reason text
//   (e.g. echo "<<...: npm install fix>>") caused false-positive write.
//   Stripping quoted args prevents the match.
// - "pwsh" / "pwsh-alias" / "pwsh-encoded" (#416): defense-in-depth for pwsh
//   verbs in reason text.
// Accepted tradeoff (AT-DP1, #416): adding "pkg-mgr"/"gh" causes
// stripQuotedArgs to collapse quoted write verbs (e.g. npm "install",
// gh api -X "DELETE") into no-match → 'read' (false-negative). Claude Code
// normally issues unquoted commands so real-world impact is minimal. To
// recover true-positive detection for quoted writes, revert this set and use
// a sentinel-only case-bypass instead.
// Other kinds (posix [here-doc/here-string], interpreter) are
// tested against the original command. here-doc/here-string in particular MUST
// scan the original cmd because the Group A QUOTING_ONLY_NAMES override and
// stripHeredocBody contract depend on it (see classify() lines 160-190).
const STRIP_KINDS = new Set(["file-op", "posix-redir", "git", "pkg-mgr", "gh", "pwsh", "pwsh-alias", "pwsh-encoded"]);

// Write command words that, when quoted at command-position, must still be
// classified as write (#515). git/npm/gh excluded — too many false positives.
// sed/perl excluded — in-place flag detection requires argument scanning.
const QUOTED_COMMAND_WORD_WRITE_NAMES = new Set([
  "tee", "rm", "mv", "cp", "patch", "touch", "chmod", "dd", "rsync",
  "unzip", "gunzip", "bunzip2", "sc", "ac", "ni", "ri",
]);

// Returns true if cmd has a write command word at a command-position that is
// wrapped in single OR double quotes (e.g. `"rm" file`, `foo; 'tee' out`).
// Command-position is anchored to start-of-string or a shell command separator
// (;|&), optionally followed by whitespace. Plain whitespace alone does NOT
// qualify — that would FP on argument-position quotes like `echo "rm"` or
// `grep "tee" file` (#566 MEDIUM). Single-quoted form is the sibling required
// by orthogonality (#515 MEDIUM).
function isQuotedWriteCommandWord(cmd) {
  if (!cmd || typeof cmd !== "string") return false;
  const re = /(?:^|[;|&])\s*(?:"([^"]+)"|'([^']+)')/g;
  let m;
  while ((m = re.exec(cmd)) !== null) {
    const content = m[1] != null ? m[1] : m[2];
    const firstToken = content.trim().split(/\s+/)[0];
    if (QUOTED_COMMAND_WORD_WRITE_NAMES.has(firstToken)) return true;
  }
  return false;
}

// Reason-text guard: reject only the 3 chars that carry expansion semantics
// inside a bash double-quoted string — $ (variable/command expansion), ` (command
// substitution), and " (quote termination). All other chars (|, ;, &, (, ), <, >,
// \) are literal inside "..." and are safe to pass through.
//
// Bare \ is safe: it is only a bash escape when immediately followed by one of
// { $ ` " \ newline }. Those second chars are already in this 3-char set, so any
// dangerous \-sequence is caught by its second character. Trailing \ before >>"
// (e.g. C:\path>>) is also safe — \ before > is not a bash escape sequence.
const UNSAFE_REASON_CHARS = /[$`"]/;

function isSentinelEchoSafe(cmd) {
  if (!isStrictSentinel(cmd)) return false;
  const m = cmd.match(/<<WORKFLOW_[A-Za-z_]+(?::\s*([^>]+))?>>"/);
  if (!m) return false;
  const reason = m[1];
  if (reason == null) return true;
  return !UNSAFE_REASON_CHARS.test(reason);
}

/**
 * Classify a Bash command string as "read" or "write".
 * Returns "write" if any WRITE_PATTERNS pattern matches, except: when ALL
 * matched patterns are quoting-only AND the command is a Group A gh command,
 * the body is a multi-line string (not file I/O) and the command is "read".
 * Returns "read" if no pattern matches or input is not a string.
 * Never throws.
 */
function classify(cmd) {
  try {
    if (!cmd || typeof cmd !== "string") return "read";
    const trimmed = cmd.trim();
    if (isStrictSentinel(trimmed)) {
      return isSentinelEchoSafe(trimmed) ? "read" : "write";
    }
    const stripped = stripQuotedArgs(cmd);
    if (isQuotedWriteCommandWord(cmd)) return "write";
    const matchedNames = [];
    for (const p of WRITE_PATTERNS) {
      const scanned = STRIP_KINDS.has(p.kind) ? stripped : cmd;
      if (p.regex.test(scanned)) matchedNames.push(p.name);
    }
    if (matchedNames.length === 0) return "read";
    if (
      matchedNames.every((n) => QUOTING_ONLY_NAMES.has(n)) &&
      GH_GROUP_A_REGEX.test(cmd)
    ) {
      // #371 codex-review hardening: the quoting-only early-return only applies
      // when every heredoc in the command is safe to collapse. Otherwise the
      // body might execute (interpreter heredoc) or undergo shell expansion
      // (unquoted opener with $(...) / backticks), and the dangerous content
      // must remain visible to the classifier.
      if (isSafeHeredocOnly(cmd)) {
        return "read";
      }
      return "write";
    }
    // #371 + #596 fix: for Group A gh commands or known dispatcher invocations,
    // strip heredoc bodies AND inline --body/--title argument values, then
    // re-scan. If no write pattern remains, or only quoting-only patterns
    // remain, the command is "read".
    if (GH_GROUP_A_REGEX.test(cmd) || isKnownDispatchInvocation(cmd)) {
      const bodyStripped = stripInlineBodyArg(stripHeredocBody(stripShellVarAssignment(cmd)));
      const reStripped = stripQuotedArgs(bodyStripped);
      const reMatched = [];
      for (const p of WRITE_PATTERNS) {
        const scanned = STRIP_KINDS.has(p.kind) ? reStripped : bodyStripped;
        if (p.regex.test(scanned)) reMatched.push(p.name);
      }
      if (reMatched.length === 0) return "read";
      if (reMatched.every((n) => QUOTING_ONLY_NAMES.has(n))) return "read";
    }
    // Re-classify bash -c / pwsh -Command when only interpreter-c matches
    // and the inner body is read-only.
    const nonQuotingMatches = matchedNames.filter((n) => !QUOTING_ONLY_NAMES.has(n));
    if (
      nonQuotingMatches.length === 1 &&
      nonQuotingMatches[0] === "interpreter-c" &&
      isReadOnlyInterpreterC(cmd)
    ) {
      return "read";
    }
    return "write";
  } catch (e) {
    return "write"; // fail-safe (line 4 contract: when in doubt, write)
  }
}

/**
 * Returns true if every heredoc in cmd is safe to collapse: opener is preceded
 * by `cat` (not an interpreter like bash/sh/python), and bodies of unquoted
 * heredocs do not contain shell expansions ($(...) / backticks). Heredocs that
 * fail either check carry executable content and must be classified as write
 * even when the surrounding command is otherwise quoting-only Group A.
 *
 * Fail-safe: any unexpected condition returns false (forcing the caller to
 * treat the command as potentially dangerous).
 */
function isSafeHeredocOnly(cmd) {
  try {
    if (!cmd || typeof cmd !== "string") return false;
    // Match every heredoc opener: capture the preceding non-space token (if any)
    // and the body. Without a `cat` prefix or with an unquoted body containing
    // $(...) or backticks, the heredoc is unsafe.
    const re = /(\S*)\s*<<-?\s*(['"]?)(\w+)\2[^\n]*\n([\s\S]*?)\n\s*\3\s*(?:\n|$)/g;
    let m;
    let found = false;
    while ((m = re.exec(cmd)) !== null) {
      found = true;
      const prefixToken = m[1];
      const quoteChar = m[2];
      const body = m[4];
      // Prefix must end with `cat` (allow `cat`, `\ncat`, ` cat`, etc.)
      if (!/(^|[\s;|&(])cat$/.test(prefixToken) && prefixToken !== "cat") {
        return false;
      }
      const isQuoted = quoteChar === "'" || quoteChar === '"';
      if (!isQuoted && /\$\(|`/.test(body)) {
        return false;
      }
    }
    return found; // if no heredoc found, this check is N/A — return false to be conservative
  } catch (e) {
    return false;
  }
}

/**
 * Returns true if cmd is a bash/sh/zsh -c '...' or pwsh -Command '...'
 * invocation where all inner body segments (split by &&/||/;) are "read".
 * Fail-closed: any unrecognized form returns false.
 */
function isReadOnlyInterpreterC(cmd) {
  try {
    if (!cmd || typeof cmd !== "string") return false;
    // Reject unsafe constructs at outer level
    if (/\$'/.test(cmd)) return false;   // ANSI-C quoting
    if (/<<</.test(cmd)) return false;    // here-string
    if (/<<[^<]/.test(cmd)) return false; // here-doc
    if (/`/.test(cmd)) return false;      // backtick substitution
    // Reject outer chaining (& inside quotes is stripped first)
    const stripped = stripQuotedArgs(cmd);
    if (/[|;&]|\$\(/.test(stripped)) return false;

    const trimmed = cmd.trim();
    let body = null;

    // bash/sh/zsh family: -c flag (or combined like -xc)
    const bashSingle = trimmed.match(
      /^(?:bash|sh|zsh|dash|fish)(?:\.exe)?\s+(?:-\w*c\w*)\s+'([^']*)'\s*$/i
    );
    if (bashSingle) body = bashSingle[1];

    if (body === null) {
      const bashDouble = trimmed.match(
        /^(?:bash|sh|zsh|dash|fish)(?:\.exe)?\s+(?:-\w*c\w*)\s+"((?:[^"\\]|\\.)*)"\s*$/i
      );
      if (bashDouble) body = bashDouble[1];
    }

    // pwsh/powershell family: -Command only (not -c)
    if (body === null) {
      const pwshSingle = trimmed.match(
        /^(?:pwsh|powershell)(?:\.exe)?\s+-Command\s+'([^']*)'\s*$/i
      );
      if (pwshSingle) body = pwshSingle[1];
    }

    if (body === null) {
      const pwshDouble = trimmed.match(
        /^(?:pwsh|powershell)(?:\.exe)?\s+-Command\s+"((?:[^"\\]|\\.)*)"\s*$/i
      );
      if (pwshDouble) body = pwshDouble[1];
    }

    if (body === null) return false; // unrecognized form → fail-closed

    // Reject newlines / NUL in inner body — segment split does not handle
    // line-separated statements; failing closed is safer than misclassifying.
    if (/[\r\n\0]/.test(body)) return false;

    const segments = body.split(/&&|\|\||;/).map((s) => s.trim()).filter(Boolean);
    if (segments.length === 0) return false;

    // Depth-1 guard: refuse nested interpreter invocations
    const NESTED_INTERP_RE = /(?:^|[\s;|&])(?:bash|sh|zsh|dash|fish|pwsh|powershell)(?:\.exe)?\s+(?:-\w*c|-Command)\b/i;
    if (segments.some((s) => NESTED_INTERP_RE.test(s))) return false;

    // #820: refuse single-segment bare `git <verb>` wrappers. These hide a git
    // command from the main-worktree-allows predicates (merge / cleanup /
    // push) so the wrapper-aware rejectInterpreterAndChaining helper can do
    // its job. Legitimate multi-step bodies (cd ... && git status && echo OK)
    // still demote to read.
    if (segments.length === 1 && /^git\b/.test(segments[0])) return false;

    return segments.every((s) => classify(s) === "read");
  } catch (e) { return false; }
}

// Returns { kind, matchedNames } — for test introspection only; production callers use classify()
function classifyDetailed(cmd) {
  const kind = classify(cmd);
  // Re-run pattern matching to collect matched names
  const stripped = stripShellVarAssignment(stripInlineBodyArg(stripHeredocBody(cmd)));
  const matchedNames = [];
  for (const p of WRITE_PATTERNS) {
    if (p.regex.test(stripped) || p.regex.test(cmd)) {
      matchedNames.push(p.name || p.kind);
    }
  }
  return { kind, matchedNames };
}

module.exports = { WRITE_PATTERNS, classify, classifyDetailed, isReadOnlyInterpreterC };
