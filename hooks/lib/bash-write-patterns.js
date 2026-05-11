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
//   - FD-to-FD redirects: cmd 2>&1, cmd 1>&2 (contain '>' — classified as write)
//   - echo "a > b" with quoted '>' inside the argument
// Note: echo "<<WORKFLOW_...>>" is NOT a false-positive — the here-doc anchor fix excludes it.
// Note: redirects to /dev/null (e.g. 2>/dev/null) are excluded from write — null-sink
//       discards output and is common in read-only commands like `git status 2>/dev/null`.
//       The lookahead uses (?=\s|[;|&]|$) not \b, so /dev/null/foo remains a write.
//       Windows NUL is intentionally NOT excluded: this pattern is for POSIX bash commands
//       only. PowerShell null-sink uses Out-Null/> $null and is handled by pwsh-specific patterns.

"use strict";

const { stripQuotedArgs } = require("./strip-quoted-args");

const WRITE_PATTERNS = [
  // POSIX redirects: >, >>, 1>, 2>, &>, n>  — /dev/null null-sink is excluded (see header note)
  { name: "posix-redirect", kind: "posix", regex: /(?:^|[\s;|&])(?:\d*)>>?(?!>|\d)(?!\s*\/dev\/null(?=\s|[;|&]|$))/ },
  // tee (writes to file while passing through)
  { name: "tee", kind: "posix", regex: /(?:^|[\s;|&])tee\b/ },
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
  // Branch deletion is gated by enforce-worktree's marker-file exemption
  // (isAllowedBranchDeleteViaMarker), which only /worktree-end produces;
  // direct invocations from any worktree are blocked at the hook level.
  { name: "git-branch-mutate", kind: "git", regex: /\bgit\s+(?:[^|;&]*\s)?branch\b[^|;&]*\s-[dDmMcC](?:\s|$)/ },
  { name: "git-checkout-force", kind: "git", regex: /\bgit\b.*\bcheckout\b.*(?:--|\.|\bHEAD\b)/ },
  { name: "git-restore", kind: "git", regex: /\bgit\b.*\brestore\b/ },
  { name: "git-stash-write", kind: "git", regex: /\bgit\b.*\bstash\b.*\b(?:push|pop|drop|clear|apply)\b/ },
  { name: "git-worktree-write", kind: "git", regex: /\bgit\b.*\bworktree\b.*\b(?:add|remove|prune)\b/ },
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
  // Interpreter -c / -Command: shell/interpreter invocations with inline body.
  // Tested against ORIGINAL cmd (not stripped) — the inline body is irrelevant;
  // the interpreter call itself is always a potential write.
  { name: "interpreter-c", kind: "interpreter",
    regex: /(?:^|[\s;|&])(?:bash|sh|zsh|dash|fish|pwsh|powershell|cmd)(?:\.exe)?\s+(?:-c\b|-Command\b|-EncodedCommand\b|\/c\b)/i },
];

// gh "Group A" coordination commands: pr/issue/repo lifecycle that touch
// GitHub-side metadata only (never tracked repo content). When the only "write"
// trigger is heredoc/here-string (multi-line body argument), override read.
const GH_GROUP_A_REGEX = /\bgh\b\s+(?:pr\s+(?:create|edit|close|comment|review)|issue\s+(?:create|edit|close|comment)|repo\s+(?:create|edit|rename|archive))\b/;

// WRITE_PATTERNS names that are merely quoting/heredoc shapes — they signal a
// multi-line string argument, not file I/O.
const QUOTING_ONLY_NAMES = new Set([
  "here-doc", "here-string", "pwsh-here-single", "pwsh-here-double",
]);

// Pattern kinds where classify() tests the stripped (quote-removed) command.
// Only file-op patterns (cp/mv/rm/touch/chmod etc.) — other kinds (posix, git,
// gh, interpreter) are tested against the original command so that operators
// and interpreter flags inside quoted args are still detected.
const STRIP_KINDS = new Set(["file-op"]);

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
    const stripped = stripQuotedArgs(cmd);
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
      return "read";
    }
    return "write";
  } catch (e) {
    return "read"; // fail-open
  }
}

module.exports = { WRITE_PATTERNS, classify };
