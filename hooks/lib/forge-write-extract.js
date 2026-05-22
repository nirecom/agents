"use strict";
// Extract scannable text from `gh` forge-write commands (issue/pr create|edit|close|comment|review).
// Deliberately narrower than GH_GROUP_A_REGEX — excludes `gh repo` and `gh api`.

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

module.exports = { isForgeScanTarget, extractTexts };
