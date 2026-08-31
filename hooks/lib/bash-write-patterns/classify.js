"use strict";

const { stripQuotedArgs, stripHeredocBody, stripInlineBodyArg, stripShellVarAssignment, isInsideSubstitution, isLineContinuedBoundary } = require("../strip-quoted-args");

// True when the sink word at `sinkOffset` is the HEAD of its own shell segment:
// only whitespace since a real boundary, no line-continuation folding it onto a
// previous command, and no enclosing $( / <( / ` capture. Without this, `bash -s
// cat <<EOF` reads as a benign local sink while `cat` is really an interpreter
// argument (#2120/#2121 security review r3; mirrors stripHeredocBody's anchor).
function isSegmentHeadSink(whole, sinkOffset) {
  const prefix = whole.slice(0, sinkOffset);
  const head = prefix.replace(/[ \t]*$/, "");
  if (head.length > 0 && !"\n;&|(".includes(head[head.length - 1])) return false;
  if (isLineContinuedBoundary(prefix)) return false;
  return !isInsideSubstitution(prefix);
}

// Strip DQ content; SQ spans need special handling (#1679 HIGH-1, FP1679-E).
// Used by spanAware+stripDQOnly so heredoc delimiters like <<'EOF' stay visible
// (full stripQuotedArgs removes 'EOF' as SQ, losing the <<'word' shape).
// SQ strategy: if accumulated result ends with << or <<- the ' is a heredoc
// delimiter — preserve content so the heredoc regex sees the word. Otherwise
// it is a regular SQ span — strip content to prevent <<EOF leakage and phantom
// DQ spans from a " inside an SQ argument (#1679 HIGH-1 + FP1679-E).
function stripDoubleQuotedContent(cmd) {
  let result = "";
  let i = 0;
  while (i < cmd.length) {
    if (cmd[i] === "'") {
      // Heredoc delimiter check: <<'word' or <<-'word'
      const isHeredocDelim = /<<-?$/.test(result.trimEnd());
      result += "'";
      i++;
      if (isHeredocDelim) {
        // Preserve delimiter word verbatim so the here-doc pattern matches.
        while (i < cmd.length && cmd[i] !== "'") {
          result += cmd[i++];
        }
      } else {
        // Regular SQ span: strip content.
        // The `"` inside (e.g. `'a"b'`) must not open a phantom DQ span, and
        // `<<EOF` inside a body arg (e.g. `bash -c 'echo "see <<EOF"'`) must
        // not be visible to the here-doc pattern.
        while (i < cmd.length && cmd[i] !== "'") {
          i++; // skip content, do not append
        }
      }
      if (i < cmd.length) { result += "'"; i++; } // consume closing '
    } else if (cmd[i] === '"') {
      result += '"';
      i++;
      while (i < cmd.length && cmd[i] !== '"') {
        if (cmd[i] === '\\' && i + 1 < cmd.length) i++; // skip escape + next char
        i++;
      }
      if (i < cmd.length) { result += '"'; i++; } // consume closing "
    } else {
      result += cmd[i++];
    }
  }
  return result;
}
const { isStrictSentinel } = require("../sentinel-patterns");
const { parse } = require("../command-ir");
const { WRITE_PATTERNS, GH_GROUP_A_REGEX, KNOWN_DISPATCH_SUFFIXES, isKnownDispatchPath, QUOTING_ONLY_NAMES, STRIP_KINDS, QUOTED_COMMAND_WORD_WRITE_NAMES, UNSAFE_REASON_CHARS, isGitWriteIR } = require("./patterns");
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
  return isKnownDispatchPath(m[1]);
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
function classify(cmd, opts) {
  try {
    // #2064: caller-supplied dispatch provenance (never re-derived here).
    const cleared = !!(opts && opts.dispatchCleared === true);
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

    // Existing logic (with #1679 S-1 spanAware/stripDQOnly enhancements):
    const stripped = stripQuotedArgs(cmd);
    const strippedDQOnly = stripDoubleQuotedContent(cmd);
    if (isQuotedWriteCommandWord(cmd)) return "write";
    const matchedNames = [];
    for (const p of WRITE_PATTERNS) {
      if (suppressedPatterns.has(p.name)) continue;
      // stripDQOnly: strip only DQ content so heredoc delimiters like <<'EOF'
      // remain visible (SQ span not stripped). Used by here-doc and here-string.
      // spanAware without stripDQOnly: use full stripQuotedArgs (for pwsh-here patterns).
      const scanned = p.stripDQOnly ? strippedDQOnly
        : (p.spanAware || STRIP_KINDS.has(p.kind)) ? stripped : cmd;
      if (p.regex.test(scanned)) matchedNames.push(p.name);
    }
    if (matchedNames.length === 0) return "read";
    if (matchedNames.every((n) => QUOTING_ONLY_NAMES.has(n))) {
      // #1679 S-1: Group A gh coordination commands / known dispatchers — the
      // heredoc is a multi-line --body/--title argument, not a file-write shell
      // construct. isSafeHeredocOnly decides whether the body is expansion-free.
      // Group A is checked first so that `gh pr create ... | cat <<EOF > out`
      // (a redirect on the same compound command) is correctly allowed as "read"
      // for the gh segment while the posix-redir is caught by isPosixRedirWriteIR.
      if (GH_GROUP_A_REGEX.test(cmd) || isKnownDispatchInvocation(cmd)) {
        if (isSafeHeredocOnly(cmd)) return "read";
        // #2064 arm A: dispatch-cleared fragment whose only write evidence is a
        // truncated cat opener. Redirect evidence is checked here explicitly.
        if (cleared && !isPosixRedirWriteIR(ir) && isTruncatedCatHeredocOnly(cmd, ir)) return "read";
        return "write";
      }
      // Non-Group-A: a co-located posix write redirect makes this a real file
      // write even though the only WRITE_PATTERNS match is a quoting-only
      // here-doc opener (e.g. `cat <<'EOF' > README.md`). isPosixRedirWriteIR
      // is retired from the general classify() path but is checked here so that
      // FC1679-J security pins remain "write" without restoring the early-return.
      if (isPosixRedirWriteIR(ir)) return "write";
      // Safe cat-only heredoc without redirect: stdin/stdout data, not a file write.
      if (isSafeHeredocOnly(cmd)) return "read";
      // #2064 arm B: same two-layer condition as arm A; redirect already excluded above.
      if (cleared && isTruncatedCatHeredocOnly(cmd, ir)) return "read";
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
        const scanned = (p.spanAware || STRIP_KINDS.has(p.kind)) ? reStripped : bodyStripped;
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
      // ...and that `cat` must head its own segment, not sit in argument
      // position (`bash -s cat <<EOF`) — see isSegmentHeadSink.
      if (!isSegmentHeadSink(cmd, m.index + prefixToken.length - 3)) {
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
 * #2064 layer 2. True only when the fragment's sole write evidence is a
 * TRUNCATED heredoc opener left behind by stripHeredocBody (body + terminator
 * already removed), and every opener is a quoted-delimiter `cat` opener.
 * Never parses: `ir` must be the caller's already-parsed IR. Missing ir → false.
 * Fail-closed: any unexpected condition returns false.
 */
function isTruncatedCatHeredocOnly(cmd, ir) {
  try {
    if (!cmd || typeof cmd !== "string") return false;
    if (!ir || ir.parseFailure === true) return false;
    if (!Array.isArray(ir.segments) || ir.segments.length !== 1) return false;
    const openers = cmd.match(/<<-?\s*(?:'\w+'|"\w+"|\w+)/g);
    if (!openers || openers.length === 0) return false;
    // Count openers that are BOTH quoted-delimiter AND owned by a segment-head
    // `cat` — an argument-position `cat` (`bash -s cat <<'EOF'`) does not count.
    const catRe = /(?:^|[\s;|&(])cat\s+<<-?\s*(?:'\w+'|"\w+")/g;
    let catQuoted = 0;
    let cm;
    while ((cm = catRe.exec(cmd)) !== null) {
      if (isSegmentHeadSink(cmd, cm.index + cm[0].indexOf("cat"))) catQuoted++;
    }
    if (catQuoted === 0) return false;
    return catQuoted === openers.length;
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
    // Quote-span-aware outer prechecks (#1679 S-3): test outside quoted spans to
    // avoid false positives from these patterns appearing inside body arguments.
    const stripped = stripQuotedArgs(cmd);
    if (/\$'/.test(stripped)) return false;   // ANSI-C quoting at outer level
    if (/<<</.test(stripped)) return false;    // here-string at outer level
    if (/<<[^<]/.test(stripped)) return false; // here-doc at outer level
    // Backtick: test FULL command — backtick IS active inside DQ spans (FC1679-K2).
    // A span-aware check would remove DQ content, hiding `\`cmd\`` from detection.
    if (/`/.test(cmd)) return false;           // backtick substitution
    // Reject outer chaining (& inside quotes is stripped first)
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
      // De-escape DQ-captured body: \"→" and \\→\ (#1679 S-3) so that
      // inner scan sees `echo "see <<EOF"` not `echo \"see <<EOF\"`.
      if (bashDouble) body = bashDouble[1].replace(/\\"/g, '"').replace(/\\\\/g, "\\");
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
      if (pwshDouble) body = pwshDouble[1].replace(/\\"/g, '"').replace(/\\\\/g, "\\");
    }

    // IR fallback (#1679 S-3): handles quote-concatenated forms (e.g. '…'"'"'…')
    // that the simple regex extractors above cannot capture. The IR parser resolves
    // quote concatenation at the argv level, so argv[cFlagIdx+1] is the correct body.
    if (body === null) {
      try {
        const irFb = parse(trimmed);
        if (!irFb.parseFailure && irFb.cmd0 && Array.isArray(irFb.argv)) {
          const base = irFb.cmd0.toLowerCase().replace(/\.exe$/i, "");
          if (/^(?:bash|sh|zsh|dash|fish|pwsh|powershell)$/.test(base)) {
            for (let i = 0; i < irFb.argv.length; i++) {
              const a = irFb.argv[i]; const al = a.toLowerCase();
              const isPwsh = base === "pwsh" || base === "powershell";
              const isCFlag = isPwsh
                ? (al === "-c" || al === "-command")
                : (al === "-c" || (a.startsWith("-") && !a.startsWith("--") && a.slice(1).includes("c")));
              if (isCFlag && i + 1 < irFb.argv.length) { body = irFb.argv[i + 1]; break; }
            }
          }
        }
      } catch (_) { body = null; }
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

    // #820: refuse single-segment bare `git <verb>` wrappers — hides command
    // from main-worktree-allows predicates; multi-step bodies still demote.
    if (segments.length === 1 && /^git\b/.test(segments[0])) return false;

    // #1400/#1401 (GAP 1+2): REGRESSION PREVENTION — not the full canary-6a migration.
    // classify() on an inner body returns "read" for rm/cp/mv/git, demoting the
    // wrapper; parse each segment to IR and fail-closed when any inner segment is a
    // write. IR predicates see through env-prefix and wrappers (#820 guard is a
    // subset of isGitWriteIR here, kept for defense-in-depth).
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
  const strippedQuotes = stripQuotedArgs(cmd);
  const strippedDQOnly = stripDoubleQuotedContent(cmd);
  const matchedNames = [];
  for (const p of WRITE_PATTERNS) {
    // stripDQOnly: DQ-only strip for here-doc/here-string (#1679 S-1)
    // spanAware without stripDQOnly: full quote-strip for pwsh-here patterns
    const matched = p.stripDQOnly
      ? p.regex.test(strippedDQOnly)
      : p.spanAware
        ? p.regex.test(strippedQuotes)
        : (p.regex.test(stripped) || p.regex.test(cmd));
    if (matched) matchedNames.push(p.name || p.kind);
  }
  return { kind, matchedNames };
}

module.exports = { classify, classifyDetailed, isReadOnlyInterpreterC, isSafeHeredocOnly, isTruncatedCatHeredocOnly };
