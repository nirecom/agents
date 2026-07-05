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
  { name: "mi-alias", kind: "pwsh-alias", regex: /(?:^|[\s;|&])mi\b/ },
  { name: "ci-alias", kind: "pwsh-alias", regex: /(?:^|[\s;|&])ci\b/ },
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
  // negative-lookahead excludes read-only plumbing: merge-base (ancestry check) and
  // merge-tree (tree-object output only). merge-file writes back to the first arg
  // and must still classify as write.
  { name: "git-merge", kind: "git", regex: /\bgit\b.*\bmerge(?!-base\b|-tree\b)(?:\b|$)/ },
  { name: "git-rebase", kind: "git", regex: /\bgit\b.*\brebase\b/ },
  { name: "git-reset", kind: "git", regex: /\bgit\b.*\breset\b/ },
  { name: "git-am", kind: "git", regex: /\bgit\b.*\bam\b/ },
  // Anchor `apply` at the git subcommand position (after `git` + optional global
  // flags) so `apply` inside an argument value (e.g. `git stash list --grep=apply`,
  // #1024) is not a false-positive. `git stash apply` is still caught by
  // git-stash-write; real `git apply <patch>` still matches here.
  { name: "git-apply", kind: "git", regex: /\bgit\s+(?:-\S+(?:\s+[^-|;&\s]\S*)?\s+)*apply\b/ },
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
  // only push/pop/apply at subcommand position mutate the working tree (write);
  // drop/clear delete a stash ref only — read (#1024); subcommand-position avoids FP on `stash list --grep=apply`.
  { name: "git-stash-write", kind: "git", regex: /\bgit\b.*\bstash\s+(?:push|pop|apply)\b/ },
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

// isGhWriteIR: IR-owned version of the kind:"gh" WRITE_PATTERNS group.
// During canary-5 (#1296), the kind:"gh" group will be removed from WRITE_PATTERNS
// and this becomes the sole SSOT for gh write detection.
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

  const sub0 = ghArgv[0];
  const sub1 = ghArgv[1];
  const sub2 = ghArgv[2];

  if (sub0 === "pr" && sub1 === "merge") return true;
  if (sub0 === "issue" && sub1 === "delete") return true;
  if (sub0 === "repo" && sub1 === "delete") return true;
  if (sub0 === "release" && sub1 != null && /^(?:create|delete|edit|upload)$/.test(sub1)) return true;
  if (sub0 === "issue" && sub1 === "create") return true;

  if (sub0 === "api") {
    // gh api -X METHOD / --method METHOD
    for (let i = 1; i < ghArgv.length; i++) {
      const tok = ghArgv[i];
      if (tok === "-X" || tok === "--method") {
        const method = ghArgv[i + 1];
        if (method && /^(?:POST|PUT|PATCH|DELETE)$/i.test(method)) return true;
      } else if (/^-X(?:POST|PUT|PATCH|DELETE)$/i.test(tok) || /^--method=(?:POST|PUT|PATCH|DELETE)$/i.test(tok)) {
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

module.exports = { WRITE_PATTERNS, GH_GROUP_A_REGEX, KNOWN_DISPATCH_SUFFIXES, QUOTING_ONLY_NAMES, STRIP_KINDS, QUOTED_COMMAND_WORD_WRITE_NAMES, UNSAFE_REASON_CHARS, isGhWriteIR };
