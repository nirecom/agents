"use strict";

const { stripQuotedArgs, stripHeredocBody, stripInlineBodyArg, stripShellVarAssignment } = require("../strip-quoted-args");
const { isStrictSentinel } = require("../sentinel-patterns");
const { parse } = require("../command-ir");
const { WRITE_PATTERNS, GH_GROUP_A_REGEX, KNOWN_DISPATCH_SUFFIXES, QUOTING_ONLY_NAMES, STRIP_KINDS, QUOTED_COMMAND_WORD_WRITE_NAMES, UNSAFE_REASON_CHARS, isGitWriteIR } = require("./patterns");
const { isPosixRedirWriteIR, isPwshWriteIR, isFileOpWriteIR, isCommandSubstWriteIR, isExoticExecWriteIR, isEncodedCommandWriteIR, isExtendedFileOpWriteIR } = require("../bash-write-targets");

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
  // Reject path traversal (CWE-22 sibling of isOsTempPath guard)
  if (/(?:^|\/)\.\.(?:\/|$)/.test(path)) return false;
  if (/^\/(?:tmp|var\/tmp|dev\/shm)\//i.test(path)) return false;
  if (/^[A-Za-z]:\/(?:Users\/[^/]+\/AppData\/Local\/Temp|Windows\/Temp|Temp)\//i.test(path)) return false;
  return KNOWN_DISPATCH_SUFFIXES.some((suf) => path.endsWith(suf));
}

function isSentinelEchoSafe(cmd) {
  if (!isStrictSentinel(cmd)) return false;
  const m = cmd.match(/<<WORKFLOW_[A-Za-z_]+(?::\s*([^>]+))?>>"/);
  if (!m) return false;
  const reason = m[1];
  if (reason == null) return true;
  return !UNSAFE_REASON_CHARS.test(reason);
}

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

/**
 * Classify a Bash command string as "read" or "write".
 * Returns "write" if any WRITE_PATTERNS pattern matches, except: when ALL
 * matched patterns are quoting-only AND the command is a Group A gh command,
 * the body is a multi-line string (not file I/O) and the command is "read".
 * Returns "read" if no pattern matches or input is not a string.
 * Never throws.
 * @param {string|import('../command-ir').IR} cmdOrIr
 */
function classify(cmd) {
  try {
    // IR shim: if an IR object is passed, use it directly; re-parse skipped.
    if (cmd !== null && typeof cmd === "object" && "rawText" in cmd) {
      if (cmd.parseFailure === true) return "write";
      cmd = cmd.rawText;
    }
    if (!cmd || typeof cmd !== "string") return "read";
    const trimmed = cmd.trim();
    if (isStrictSentinel(trimmed)) {
      return isSentinelEchoSafe(trimmed) ? "read" : "write";
    }

    // --- IR-based signal suppressors ---
    // Parse IR once; use for position-aware demotions below.
    const ir = parse(cmd);
    // Fail-closed: malformed input → treat as write (line 4 contract: when in doubt, write)
    if (ir.parseFailure) return "write";

    // Collect names of WRITE_PATTERNS entries to suppress (position false-positives).
    // Do NOT return "read" early — redirect and other patterns must still be evaluated.
    const suppressedPatterns = new Set();
    // #876: Out-File as CLI flag is not a write — suppress the "Out-File" pattern only
    if (/\bOut-File\b/i.test(cmd)) {
      const hasOutFileAsCmd = ir.segments.some((seg) => /^out-file$/i.test(seg.cmd0));
      if (!hasOutFileAsCmd) suppressedPatterns.add("Out-File");
    }
    // #1223: "reset" in a path arg is not git-reset — suppress the "git-reset" pattern only
    if (ir.cmd0 === "git" && /\breset\b/.test(cmd)) {
      const subCmd = ir.argv.find((a) => !a.startsWith("-"));
      if (subCmd && subCmd !== "reset") suppressedPatterns.add("git-reset");
    }
    // #1411: pkg-mgr subcommands are shell commands, not PowerShell short aliases.
    // npm ci (clean-install) is the known conflict with ci-alias (Copy-Item).
    // Suppress all pwsh-alias patterns when cmd0 is a known pkg-mgr tool.
    const PKG_MGR_CMDS = new Set(["npm", "pnpm", "yarn", "pip", "pip3", "uv", "cargo", "go"]);
    if (ir.cmd0 && PKG_MGR_CMDS.has(ir.cmd0.toLowerCase())) {
      for (const n of ["ci-alias", "ni-alias", "ri-alias", "mi-alias", "sc-alias", "ac-alias"]) {
        suppressedPatterns.add(n);
      }
    }

    // --- end IR-based signal suppressors ---

    // Existing logic (unchanged from original classify()):
    const stripped = stripQuotedArgs(cmd);
    if (isQuotedWriteCommandWord(cmd)) return "write";
    const matchedNames = [];
    for (const p of WRITE_PATTERNS) {
      if (suppressedPatterns.has(p.name)) continue;
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

    // pwsh/powershell family: -Command / -c (PowerShell accepts `-c` as a
    // documented alias for -Command). Symmetric with the bash `-c` handling so a
    // genuine pwsh read demotes regardless of the flag spelling.
    if (body === null) {
      const pwshSingle = trimmed.match(
        /^(?:pwsh|powershell)(?:\.exe)?\s+(?:-Command|-c)\s+'([^']*)'\s*$/i
      );
      if (pwshSingle) body = pwshSingle[1];
    }

    if (body === null) {
      const pwshDouble = trimmed.match(
        /^(?:pwsh|powershell)(?:\.exe)?\s+(?:-Command|-c)\s+"((?:[^"\\]|\\.)*)"\s*$/i
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

    // #1400/#1401 (GAP 1+2): after rm/cp/mv/posix-redir/pwsh/git leave
    // WRITE_PATTERNS, classify() of an inner body like `rm /f` or `git commit`
    // returns "read", so the segments.every(read) check below would demote the
    // wrapper to read and fast-allow it. This is REGRESSION PREVENTION only — it
    // is NOT the full interpreter-c IR target-extraction migration (canary-6a).
    //
    // Fail-closed for ALL writes: parse EACH inner segment to IR and refuse to
    // demote to read when ANY inner segment is a write. The IR predicates see
    // through env-prefix (`FOO=1 rm f`) and wrappers (`command git commit`) — a
    // first-token string scan cannot. Covers the multi-segment case
    // (`git status && git commit` — a LATER segment is the write) because every
    // segment is checked, not just the first. The #820 single-segment bare-git
    // guard above is a subset of isGitWriteIR here (kept for defense-in-depth).
    const innerSegIsWrite = (s) => {
      let segIr;
      try { segIr = parse(s); } catch (_) { return true; } // unparseable → fail-closed
      if (!segIr || segIr.parseFailure === true) return true;
      // Lazy require isPkgMgrWriteIR to avoid circular dependency.
      let isPkgMgrWriteIR;
      try { ({ isPkgMgrWriteIR } = require("../bash-write-targets/pkg-mgr")); } catch (_) { isPkgMgrWriteIR = () => false; }
      return classify(segIr) === "write" ||
        isGitWriteIR(segIr) ||
        isPosixRedirWriteIR(segIr) ||
        isPwshWriteIR(segIr) ||
        isFileOpWriteIR(segIr) ||
        isCommandSubstWriteIR(segIr) ||
        isExoticExecWriteIR(segIr) ||
        isPkgMgrWriteIR(segIr) ||
        isEncodedCommandWriteIR(segIr) ||
        isExtendedFileOpWriteIR(segIr);
    };
    if (segments.some(innerSegIsWrite)) return false;

    // Only demote to read when EVERY inner segment is genuinely read.
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

module.exports = { classify, classifyDetailed, isReadOnlyInterpreterC, isSafeHeredocOnly };
