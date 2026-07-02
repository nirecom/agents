"use strict";
// Extract scannable text from `gh` forge-write commands (issue/pr create|edit|close|comment|review).
// Deliberately narrower than GH_GROUP_A_REGEX — excludes `gh repo` and `gh api`.

const { stripQuotedArgs, stripInlineBodyArg } = require("./strip-quoted-args");

const FORGE_SCAN_TARGET_REGEX =
  /\bgh\b\s+(?:pr\s+(?:create|edit|close|comment|review)|issue\s+(?:create|edit|close|comment))\b/;

function isForgeScanTarget(command) {
  if (typeof command !== "string" || command.length === 0) return false;
  return FORGE_SCAN_TARGET_REGEX.test(command);
}

// Extract --body / --title quoted values (single or double quoted).
// Supports: --body "val", --body 'val', --body="val", --body='val', --body=val
function extractFlagQuoted(command, flag, out) {
  // Space-separated quoted: --body "val" or --body 'val'
  const reSpace = new RegExp(`--${flag}\\s+(["'])([\\s\\S]*?)\\1`, "g");
  let m;
  while ((m = reSpace.exec(command)) !== null) {
    out.push(m[2]);
  }
  // Equals-quoted: --body="val" or --body='val'
  const reEqQuoted = new RegExp(`--${flag}=(["'])([\\s\\S]*?)\\1`, "g");
  while ((m = reEqQuoted.exec(command)) !== null) {
    out.push(m[2]);
  }
  // Equals-unquoted: --body=val (until whitespace)
  const reEqUnquoted = new RegExp(`--${flag}=([^\\s"'][^\\s]*)`, "g");
  while ((m = reEqUnquoted.exec(command)) !== null) {
    out.push(m[1]);
  }
}

// Extract --flag <value> where value is a single unquoted token (not starting with -- or a quote).
function extractFlagUnquoted(command, flag, out) {
  const re = new RegExp(`--${flag}\\s+(?!["']|--)(\\S+)`, "g");
  let m;
  while ((m = re.exec(command)) !== null) {
    out.push(m[1]);
  }
}

// Extract --body-file <path> (next whitespace-delimited token, unquoted).
function extractBodyFile(command, out) {
  const re = /--body-file\s+(\S+)/g;
  let m;
  while ((m = re.exec(command)) !== null) {
    out.push(m[1]);
  }
}

// Extract heredoc content with arbitrary delimiter: <<EOF, <<'EOF', <<"EOF", <<-EOF, etc.
function extractHeredocs(command, out) {
  const re = /<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?\s*\n([\s\S]*?)\n[ \t]*\1\b/g;
  let m;
  while ((m = re.exec(command)) !== null) {
    out.push(m[2]);
  }
}

function extractTexts(command) {
  const inline = [];
  const filePaths = [];
  if (typeof command !== "string" || command.length === 0) {
    return { inline, filePaths };
  }
  extractFlagQuoted(command, "body", inline);
  extractFlagQuoted(command, "title", inline);
  extractFlagUnquoted(command, "body", inline);
  extractFlagUnquoted(command, "title", inline);
  extractBodyFile(command, filePaths);
  extractHeredocs(command, inline);
  return { inline, filePaths };
}

// Validate owner/repo shape: alphanumeric/dot/dash/underscore on both sides of /
const REPO_SHAPE_RE = /^[\w.-]+\/[\w.-]+$/;

// Extract the --repo / -R flag value from a gh command.
// Returns owner/repo string or null if absent/invalid.
// Uses extractFlagQuoted/extractFlagUnquoted for --repo (long form only).
// For -R short form: uses stripQuotedArgs to avoid false positives from quoted body content.
function extractRepoFlag(command) {
  if (typeof command !== "string" || command.length === 0) return null;

  // Long form: --repo "val", --repo=val, --repo val
  // Strip only --body/--title argument VALUES (where untrusted smuggling lands, e.g.
  // --body "see --repo attacker/evil"), leaving a real --repo flag value intact — so a
  // smuggled --repo inside a body/title is neutralized but a legitimate quoted --repo
  // "owner/repo" still extracts correctly. (stripQuotedArgs would also blank the real value.)
  {
    const stripped = stripInlineBodyArg(command);
    const candidates = [];
    extractFlagQuoted(stripped, "repo", candidates);
    extractFlagUnquoted(stripped, "repo", candidates);
    for (const c of candidates) {
      const v = c.trim();
      if (REPO_SHAPE_RE.test(v)) return v;
    }
  }

  // Short form: -R (not handled by extractFlagQuoted/extractFlagUnquoted since those prefix --)
  // Use stripQuotedArgs to neutralize quoted content so we only match real -R flags.
  {
    const stripped = stripQuotedArgs(command);
    // Check if -R or -R= appears in the stripped command (outside quotes)
    const hasShortFlag = /(?:^|[\s;|&])-R(?:[\s=]|$)/.test(stripped);
    if (hasShortFlag) {
      // -R=owner/repo (equals form, no space)
      const eqMatch = command.match(/(?:^|[\s;|&])-R=(\S+)/);
      if (eqMatch) {
        const v = eqMatch[1].replace(/^["']|["']$/g, "");
        if (REPO_SHAPE_RE.test(v)) return v;
      }
      // -R "owner/repo" or -R owner/repo (space form — search original command)
      // Find -R followed by a value in the original command string
      const spaceMatch = command.match(/(?:^|[\s;|&])-R\s+(["']?)([^\s"']+)\1/);
      if (spaceMatch) {
        const v = spaceMatch[2];
        if (REPO_SHAPE_RE.test(v)) return v;
      }
    }
  }

  return null;
}

module.exports = { isForgeScanTarget, extractTexts, extractRepoFlag };
