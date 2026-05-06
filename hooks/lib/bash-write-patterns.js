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

"use strict";

const WRITE_PATTERNS = [
  // POSIX redirects: >, >>, 1>, 2>, &>, n>
  { name: "posix-redirect", kind: "posix", regex: /(?:^|[\s;|&])(?:\d*)>>?(?!>|\d)/ },
  // tee (writes to file while passing through)
  { name: "tee", kind: "posix", regex: /(?:^|[\s;|&])tee\b/ },
  // here-doc: <<EOF, <<-EOF, <<'EOF', <<"EOF"
  { name: "here-doc", kind: "posix", regex: /<<-?['"]?\w/ },
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
  { name: "git-commit", kind: "git", regex: /\bgit\b.*\bcommit\b/ },
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
  { name: "git-branch-mutate", kind: "git", regex: /\bgit\b.*\bbranch\b.*-[dDmMcC]/ },
  { name: "git-checkout-force", kind: "git", regex: /\bgit\b.*\bcheckout\b.*(?:--|\.|\bHEAD\b)/ },
  { name: "git-restore", kind: "git", regex: /\bgit\b.*\brestore\b/ },
  { name: "git-stash-write", kind: "git", regex: /\bgit\b.*\bstash\b.*\b(?:push|pop|drop|clear|apply)\b/ },
  { name: "git-worktree-write", kind: "git", regex: /\bgit\b.*\bworktree\b.*\b(?:add|remove|prune)\b/ },
  // gh mutating subcommands
  { name: "gh-pr-write", kind: "gh", regex: /\bgh\b.*\bpr\b.*\b(?:create|edit|close|merge|comment|review)\b/ },
  { name: "gh-issue-write", kind: "gh", regex: /\bgh\b.*\bissue\b.*\b(?:create|edit|close|delete)\b/ },
  { name: "gh-release-write", kind: "gh", regex: /\bgh\b.*\brelease\b.*\b(?:create|delete|edit|upload)\b/ },
  { name: "gh-repo-write", kind: "gh", regex: /\bgh\b.*\brepo\b.*\b(?:create|delete|edit|rename|archive)\b/ },
  { name: "gh-api-mutate", kind: "gh", regex: /\bgh\b.*\bapi\b.*-X\s+(?:POST|PUT|PATCH|DELETE)\b/i },
];

/**
 * Classify a Bash command string as "read" or "write".
 * Returns "write" if any WRITE_PATTERNS pattern matches.
 * Returns "read" if no pattern matches or input is not a string.
 * Never throws.
 */
function classify(cmd) {
  try {
    if (!cmd || typeof cmd !== "string") return "read";
    for (const p of WRITE_PATTERNS) {
      if (p.regex.test(cmd)) return "write";
    }
    return "read";
  } catch (e) {
    return "read"; // fail-open
  }
}

module.exports = { WRITE_PATTERNS, classify };
