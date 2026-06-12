"use strict";

const { spawnSync } = require("child_process");
const path = require("path");
const os = require("os");

// True if the token looks like a variable expansion or command substitution
// that we cannot statically resolve.
function isUnresolvableToken(tok) {
  return /[$`]|\$\(|>\(/.test(tok);
}

/**
 * Expand statically resolvable shell variable prefixes in a redirect target token.
 * Only expands: $HOME, ${HOME}, ~/..., $WORKFLOW_PLANS_DIR, ${WORKFLOW_PLANS_DIR}.
 * Only expands at the START of the token (leading position).
 * Returns the expanded string, or the original string if unexpandable.
 * Returns null if the token contains a dollar sign that was NOT expanded (fail-closed).
 *
 * @param {string} s - The token string to expand.
 * @param {object} opts
 *   fromQuotedContext: "double" | "unquoted"
 */
function expandStaticShellTokens(s, opts = {}) {
  const { fromQuotedContext = "unquoted" } = opts;

  // Normalize Windows backslash paths to forward slashes for consistent matching
  // and output. os.homedir() returns backslashes on Windows; downstream callers
  // (path.resolve, hook regex matching) treat / and \ interchangeably on Windows
  // but tests expect forward-slash output.
  const homeDir = os.homedir().replace(/\\/g, "/");

  // Tilde expansion: only in unquoted context (not inside double-quotes)
  if (fromQuotedContext === "unquoted" && (s === "~" || s.startsWith("~/") || s.startsWith("~\\"))) {
    const remainder = s.slice(1);
    if (remainder.includes("$") || remainder.includes("`")) return null;
    return homeDir + remainder;
  }

  // $HOME or ${HOME} — expand in both double-quoted and unquoted contexts.
  // Use alternation to enforce balanced braces: $HOME or ${HOME} only.
  const homeRe = /^\$(?:\{HOME\}|HOME)(?=\/|\\|$)/;
  if (homeRe.test(s)) {
    const remainder = s.replace(homeRe, "");
    if (remainder.includes("$") || remainder.includes("`")) return null;
    return homeDir + remainder;
  }

  // $WORKFLOW_PLANS_DIR or ${WORKFLOW_PLANS_DIR} — expand only when env var is defined and non-empty.
  const wpRe = /^\$(?:\{WORKFLOW_PLANS_DIR\}|WORKFLOW_PLANS_DIR)(?=\/|\\|$)/;
  if (wpRe.test(s)) {
    const wpd = process.env.WORKFLOW_PLANS_DIR;
    if (!wpd) return null; // fail-closed: unset or empty → cannot resolve
    const remainder = s.replace(wpRe, "");
    if (remainder.includes("$") || remainder.includes("`")) return null;
    return wpd + remainder;
  }

  // If the token still starts with $ (or contains $ not at a known expansion), fail-closed.
  if (s.includes("$")) return null;

  return s;
}

// Pad quoted string CONTENT with null bytes to preserve string length while
// neutralising any shell operators (>, $, etc.) that appear inside quotes.
// This lets the redirect-operator regex run on the padded string and produce
// character positions that are identical to those in the original string.
function padQuotedSegments(str) {
  return str
    .replace(/"(?:[^"\\]|\\.)*"/g, (m) => '"' + "\0".repeat(m.length - 2) + '"')
    .replace(/'[^']*'/g, (m) => "'" + "\0".repeat(m.length - 2) + "'");
}

// Read a redirect target token from the ORIGINAL cmd starting at position i.
// Returns { target: string|null, end: number } or null (parse failure).
function readTargetAt(cmd, i) {
  if (i >= cmd.length) return { target: null, end: i };
  const ch = cmd[i];
  if (ch === "(") return null;                       // process substitution
  if (ch === "`") return null;                       // command substitution
  if (ch === '"') {
    let content = "", j = i + 1;
    let hadEscapedDollar = false;
    while (j < cmd.length && cmd[j] !== '"') {
      if (cmd[j] === "`") return null;              // command substitution inside double-quotes
      if (cmd[j] === "\\" && j + 1 < cmd.length) {
        if (cmd[j + 1] === "$") hadEscapedDollar = true;
        content += cmd[j + 1]; j += 2;
      } else {
        content += cmd[j++];
      }
    }
    // If a backslash-escaped \$ was encountered, the resulting content contains a literal $
    // that must NOT be expanded (the user explicitly escaped it). Fail-closed.
    if (hadEscapedDollar && content.includes("$")) return null;
    const expanded = expandStaticShellTokens(content, { fromQuotedContext: "double" });
    if (expanded === null) return null;
    return { target: expanded, end: j + 1 };
  }
  if (ch === "'") {
    let content = "", j = i + 1;
    while (j < cmd.length && cmd[j] !== "'") content += cmd[j++];
    // Single-quoted strings: NEVER expand — return literal content as-is.
    return { target: content, end: j + 1 };
  }
  // Unquoted token: read until whitespace or shell delimiter.
  // Allow $ to accumulate and attempt static expansion via expandStaticShellTokens.
  let content = "", j = i;
  while (j < cmd.length && !/[\s;|&]/.test(cmd[j])) {
    const c = cmd[j];
    if (c === "`" || c === "(") return null;        // command/process substitution — fail-closed
    content += c; j++;
  }
  if (!content) return { target: null, end: j };
  const expanded = expandStaticShellTokens(content, { fromQuotedContext: "unquoted" });
  if (expanded === null) return null;
  return { target: expanded, end: j };
}

/**
 * Extract POSIX redirect write targets from a shell command string.
 *
 * Handles: > file, >> file, N> file, N>> file, &> file
 * Skips:   FD-to-FD redirects (2>&1, 1>&2), /dev/null sinks, quoted paths preserved
 * Returns: string[] on success, null on parse failure (unresolvable token).
 */
function extractRedirectTargets(cmd) {
  if (!cmd || typeof cmd !== "string") return null;

  // Detect redirect operators on the padded string (avoids false positives inside quotes).
  // Positions in padded == positions in original because quotes are padded to same length.
  const padded = padQuotedSegments(cmd);
  // \s* is required: both "> file" and ">file" are valid shell syntax.
  const OPRE = /(?:^|[\s;|])(?:\d*)(?:&>>?|>>?)(?!>|\d)\s*/g;

  const targets = [];
  let m;
  while ((m = OPRE.exec(padded)) !== null) {
    const targetStart = m.index + m[0].length;
    const result = readTargetAt(cmd, targetStart);
    if (result === null) return null;                     // parse failure
    const { target } = result;
    if (target === null) continue;
    if (/^&\d/.test(target)) continue;                   // FD-to-FD (e.g. &1)
    if (target === "/dev/null" || target.endsWith("/dev/null")) continue; // null-sink
    targets.push(target);
  }
  return targets;
}

/**
 * Extract tee write targets from a shell command string.
 *
 * Handles: tee [flags] file1 [file2 ...]
 * Skips:   -a/--append/-i/-p flags
 * Returns: string[] on success, null on parse failure.
 */
function extractTeeTargets(cmd) {
  if (!cmd || typeof cmd !== "string") return null;

  // Process substitutions in tee args → fail-closed.
  if (/tee\s[^;|&]*>\s*\(/.test(cmd)) return null;

  // Find tee invocation.
  const RE = /(?:^|[\s;|&])tee\b(.*?)(?:$|[;|&](?:[^|&]|$))/s;
  const m = RE.exec(cmd);
  if (!m) return [];

  const argStr = m[1];
  // Split on whitespace, filter out flags.
  const tokens = argStr.trim().split(/\s+/).filter(Boolean);
  const targets = [];
  let i = 0;
  while (i < tokens.length) {
    const t = tokens[i];
    if (t === "-a" || t === "--append" || t === "-i" || t === "-p" || t === "--ignore-interrupts") {
      i++;
      continue;
    }
    if (t.startsWith("-")) {
      i++;
      continue;
    }
    // Process substitution
    if (t.startsWith(">(")) return null;
    if (isUnresolvableToken(t)) return null;
    targets.push(t);
    i++;
  }
  return targets;
}

// PowerShell cmdlets that write to a single positional/named -Path target.
const PWSH_SINGLE_TARGET_CMDLETS = new Set([
  "set-content", "add-content", "out-file", "new-item", "remove-item",
  "sc", "ac", "ni", "ri",
]);

// PowerShell cmdlets where the destination is the SECOND positional arg (source = first).
const PWSH_DEST_SECOND_CMDLETS = new Set([
  "move-item", "copy-item", "mi", "ci",
]);

// Quote-aware tokenizer for PowerShell command strings.
// Returns string[] of tokens on success, null on parse failure (unresolvable).
function tokenizePwsh(cmd) {
  const tokens = [];
  let i = 0;
  while (i < cmd.length) {
    while (i < cmd.length && /\s/.test(cmd[i])) i++;
    if (i >= cmd.length) break;
    if (cmd[i] === '"') {
      let content = "", j = i + 1;
      while (j < cmd.length && cmd[j] !== '"') {
        if (cmd[j] === "$" || cmd[j] === "`") return null;
        if (cmd[j] === "\\" && j + 1 < cmd.length) { content += cmd[j + 1]; j += 2; }
        else content += cmd[j++];
      }
      tokens.push(content);
      i = j + 1;
    } else if (cmd[i] === "'") {
      let content = "", j = i + 1;
      while (j < cmd.length && cmd[j] !== "'") content += cmd[j++];
      tokens.push(content);
      i = j + 1;
    } else {
      let content = "", j = i;
      while (j < cmd.length && !/\s/.test(cmd[j])) {
        if (cmd[j] === "$" || cmd[j] === "`" || cmd[j] === "(") return null;
        content += cmd[j++];
      }
      if (content) tokens.push(content);
      i = j;
    }
  }
  return tokens;
}

/**
 * Extract PowerShell write cmdlet targets from a command string.
 *
 * For Set-Content/Add-Content/Out-File/New-Item/Remove-Item (and aliases sc/ac/ni/ri):
 *   - named: -Path/-LiteralPath/-FilePath → that value
 *   - positional fallback: first non-flag token
 * For Move-Item/Copy-Item (and aliases mi/ci):
 *   - named: -Destination/-Target → that value (source -Path is ignored)
 *   - positional fallback: SECOND non-flag token (source = first, destination = second)
 *   - no destination → null (fail-closed)
 *
 * Returns: string[] on success, null on parse failure.
 */
function extractPwshWriteTargets(cmd) {
  if (!cmd || typeof cmd !== "string") return null;

  const tokens = tokenizePwsh(cmd);
  if (tokens === null || tokens.length === 0) return null;

  const cmdletRaw = tokens[0].toLowerCase();
  const isSingle = PWSH_SINGLE_TARGET_CMDLETS.has(cmdletRaw);
  const isDest = PWSH_DEST_SECOND_CMDLETS.has(cmdletRaw);

  if (!isSingle && !isDest) return null;

  let namedTarget = null;
  const positionals = [];
  let i = 1;

  while (i < tokens.length) {
    const t = tokens[i];
    const tl = t.toLowerCase();
    if (tl === "-path" || tl === "-literalpath" || tl === "-filepath") {
      if (isDest) {
        // For Move/Copy, -Path is the source — skip the value.
        i += 2;
        continue;
      }
      if (i + 1 < tokens.length) {
        namedTarget = tokens[i + 1];
        i += 2;
        continue;
      }
      return null;
    }
    if (tl === "-destination" || tl === "-target") {
      if (i + 1 < tokens.length) {
        namedTarget = tokens[i + 1];
        i += 2;
        continue;
      }
      return null;
    }
    if (tl === "-value" || tl === "-encoding" || tl === "-force" ||
        tl === "-recurse" || tl === "-itemtype" || tl === "-whatif" ||
        tl === "-confirm" || tl === "-passthru" || tl === "-noclobber" ||
        tl === "-append" || tl === "-width" || tl === "-inputobject") {
      // Known non-path named params — skip name and value.
      i += (i + 1 < tokens.length && !tokens[i + 1].startsWith("-")) ? 2 : 1;
      continue;
    }
    if (t.startsWith("-")) {
      i++;
      continue;
    }
    positionals.push(t);
    i++;
  }

  if (namedTarget !== null) return [namedTarget];

  if (isSingle) {
    return positionals.length > 0 ? [positionals[0]] : null;
  }

  // isDest: destination = second positional.
  if (positionals.length < 2) return null;
  return [positionals[1]];
}

/**
 * Extract the destination path of a POSIX cp or mv command.
 *
 * cp [flags] source... dest — returns last positional arg (destination)
 * mv [flags] source dest   — same
 *
 * Returns: string on success, null on parse failure (unresolvable token or
 * fewer than 2 positional args).
 */
function extractCpMvDestination(cmd) {
  if (!cmd || typeof cmd !== "string") return null;

  const RE = /(?:^|[\s;|&])(?:cp|mv)\b(.*?)(?:$|[;|&](?:[^|&]|$))/s;
  const m = RE.exec(cmd);
  if (!m) return null;

  // Step A — Parse env-prefix tokens from the segment BEFORE `cp`/`mv`.
  // Only KEY=VALUE pairs where VALUE has no $, `, ( are accepted.
  // env-prefix only — process.env not consulted (#739)
  const envPrefix = {};
  const beforeRe = /(?:^|[\s;|&])(?:cp|mv)\b/;
  const beforeMatch = beforeRe.exec(cmd);
  if (beforeMatch) {
    const prefixRegion = cmd.slice(0, beforeMatch.index);
    const prefixTokens = prefixRegion.trim().split(/\s+/).filter(Boolean);
    for (const tok of prefixTokens) {
      const km = /^([A-Za-z_][A-Za-z0-9_]*)=(\S+)$/.exec(tok);
      if (!km) continue;
      const value = km[2];
      if (value.includes("$") || value.includes("`") || value.includes("(")) continue;
      // Reject ../ traversal in env-prefix values: a worktree-backup target
      // expressed via traversal is suspicious — fail-closed (#739 R9/R10).
      if (/(^|[\\/])\.\.([\\/]|$)/.test(value)) continue;
      envPrefix[km[1]] = value;
    }
  }

  // Substitute $KEY / ${KEY} using envPrefix only.
  function substituteEnvPrefix(s) {
    let out = s;
    for (const key of Object.keys(envPrefix)) {
      const val = envPrefix[key];
      out = out.split("${" + key + "}").join(val);
      // $KEY where the next char is not a word char (or end).
      const re = new RegExp("\\$" + key + "(?![A-Za-z0-9_])", "g");
      out = out.replace(re, val);
    }
    return out;
  }

  // Strip surrounding quotes from a single token. Returns { stripped, wasDoubleQuoted }.
  function stripOuterQuotes(t) {
    if (t.length >= 2) {
      if (t[0] === '"' && t[t.length - 1] === '"') {
        return { stripped: t.slice(1, -1), wasDoubleQuoted: true };
      }
      if (t[0] === "'" && t[t.length - 1] === "'") {
        return { stripped: t.slice(1, -1), wasDoubleQuoted: false, wasSingleQuoted: true };
      }
    }
    return { stripped: t, wasDoubleQuoted: false };
  }

  const tokens = m[1].trim().split(/\s+/).filter(Boolean);
  const positionals = [];
  for (const t of tokens) {
    if (t === "--") break;
    if (t.startsWith("-")) continue;

    // Step B — Substitute env-prefix in ALL positionals (source and destination).
    let resolved = t;
    if (t.includes("$")) {
      // Strip outer quotes so substitution can target the inner content.
      const { stripped, wasSingleQuoted } = stripOuterQuotes(t);
      // Single-quoted tokens: never expand — fail-closed if $ present.
      if (wasSingleQuoted) {
        if (stripped.includes("$")) return null;
        resolved = stripped;
      } else {
        const substituted = substituteEnvPrefix(stripped);
        if (isUnresolvableToken(substituted)) return null;
        resolved = substituted;
      }
    } else {
      // No $ — still strip outer quotes for consistency.
      const { stripped } = stripOuterQuotes(t);
      resolved = stripped;
      if (isUnresolvableToken(resolved)) return null;
    }
    positionals.push(resolved);
  }
  if (positionals.length < 2) return null;
  return positionals[positionals.length - 1];
}

/**
 * Extract POSIX rm targets from a shell command string.
 *
 * rm [flags] path... — returns all positional (non-flag) args.
 * Flags handled: short bundles (-rf, -fr, -i, -v, ...), long flags
 *   (--recursive, --force, --interactive, --verbose, --one-file-system,
 *   --no-preserve-root, --preserve-root, --dir, -d), and `--` end-of-flags.
 *
 * Relative paths are returned verbatim; the caller (findRepoRoot →
 * path.resolve) resolves them against process.cwd().
 *
 * Quote-detection fail-closed: if the rm args region contains ANY quote
 *   character (`"` or `'`), returns null. The split(/\s+/) tokenizer is
 *   not quote-aware, and silently shredding a quoted in-repo path into
 *   non-resolvable fragments would be a fail-open regression on a
 *   destructive command. Conservative; quoted rm paths are uncommon in
 *   hook contexts (Claude Code Bash invocations rarely quote rm targets).
 *
 * Returns: string[] on success (may be empty if no positionals), null on
 *   parse failure (unresolvable token via $VAR / $(...) / backticks, OR
 *   quote character present in args).
 */
function extractRmTargets(cmd) {
  if (!cmd || typeof cmd !== "string") return null;

  const RE = /(?:^|[\s;|&])rm\b(.*?)(?:$|[;|&](?:[^|&]|$))/s;
  const m = RE.exec(cmd);
  if (!m) return null;

  const argsRegion = m[1];

  if (argsRegion.includes('"') || argsRegion.includes("'")) return null;

  const tokens = argsRegion.trim().split(/\s+/).filter(Boolean);
  const positionals = [];
  let sawDashDash = false;
  for (const t of tokens) {
    if (!sawDashDash && isUnresolvableToken(t)) return null;
    if (!sawDashDash && t === "--") { sawDashDash = true; continue; }
    if (!sawDashDash && t.startsWith("-")) continue;
    positionals.push(t);
  }
  return positionals;
}

/**
 * Get the list of staged files in a git repo as absolute paths.
 *
 * Returns: string[] on success (may be empty), null on failure.
 */
function extractStagedFiles(repoRoot) {
  if (!repoRoot || typeof repoRoot !== "string") return null;
  try {
    const r = spawnSync(
      "git", ["diff", "--cached", "--name-only"],
      { cwd: repoRoot, encoding: "utf8", timeout: 2000 }
    );
    if (r.status !== 0) return null;
    const lines = (r.stdout || "").split("\n").filter(Boolean);
    return lines.map((rel) => path.resolve(repoRoot, rel));
  } catch (e) {
    return null;
  }
}

module.exports = {
  extractRedirectTargets,
  extractTeeTargets,
  extractPwshWriteTargets,
  extractCpMvDestination,
  extractRmTargets,
  extractStagedFiles,
};
