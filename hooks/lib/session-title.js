"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const { parseClosesIssues } = require("./parse-closes-issues");

// Subagent guard: CLAUDE_CODE_CHILD_SESSION=1 → skip all writes
function _isChildSession() {
  return process.env.CLAUDE_CODE_CHILD_SESSION === "1";
}

// Encode cwd for JSONL directory name
// CLAUDE_PROJECT_DIR takes precedence over cwd per design
function _encodeCwd(cwd) {
  const raw = process.env.CLAUDE_PROJECT_DIR || path.resolve(cwd);
  return path.resolve(raw).toLowerCase().replace(/[^a-zA-Z0-9]/g, "-");
}

function _getTranscriptBase() {
  return (
    process.env.CLAUDE_TRANSCRIPT_BASE_DIR ||
    path.join(os.homedir(), ".claude", "projects")
  );
}

function _getJsonlPath(sessionId, cwd) {
  const encodedCwd = _encodeCwd(cwd);
  const transcriptBase = _getTranscriptBase();
  return path.join(transcriptBase, encodedCwd, sessionId + ".jsonl");
}

// Read the most recent custom-title record for sessionId from the JSONL file.
// Returns the customTitle string, or null if not found.
function _readCurrentTitle(sessionId, cwd) {
  const jsonlPath = _getJsonlPath(sessionId, cwd);
  try {
    const content = fs.readFileSync(jsonlPath, "utf8");
    const lines = content.split("\n").filter((l) => l.trim().length > 0);
    // Scan in reverse to get the most recent
    for (let i = lines.length - 1; i >= 0; i--) {
      try {
        const record = JSON.parse(lines[i]);
        if (
          record.type === "custom-title" &&
          record.sessionId === sessionId &&
          typeof record.customTitle === "string"
        ) {
          return record.customTitle;
        }
      } catch (_) {
        // ignore malformed lines
      }
    }
  } catch (_) {
    // file absent or unreadable
  }
  return null;
}

// Append a custom-title record to the JSONL file.
// Fail-open on all fs errors.
function _writeTitle(sessionId, cwd, title) {
  const jsonlPath = _getJsonlPath(sessionId, cwd);
  const record =
    JSON.stringify({ type: "custom-title", sessionId, customTitle: title }) +
    "\n";
  try {
    fs.appendFileSync(jsonlPath, record, "utf8");
  } catch (_) {
    // fail-open
  }
}

/**
 * Read the issue title from intent.md for the given issue number.
 * Returns the title string (after "#N: ") or null if not parseable.
 */
function _readIssueTitleFromIntentLine(line) {
  // Matches "- #N: title" or "- N: title"
  const m = line.match(/^-\s+#?\d+:\s+(.+)\s*$/);
  if (m) return m[1].trim();
  return null;
}

/**
 * Parse ## Issues section from intent.md content.
 * Returns array of {num, title} objects.
 */
function _parseIssuesWithTitles(intentContent) {
  const lines = intentContent.split(/\r?\n/);
  let inSection = false;
  const issues = [];
  for (const line of lines) {
    if (/^## Issues\s*$/.test(line)) {
      inSection = true;
      continue;
    }
    if (inSection && /^## /.test(line)) break;
    if (inSection) {
      // Match "- #N: title" or "- #N" or "- N: title" or "- N"
      const m = line.match(/^-\s+#?(\d+)(?::\s+(.+))?\s*$/);
      if (m) {
        issues.push({
          num: Number(m[1]),
          title: m[2] ? m[2].trim() : null,
        });
      }
    }
  }
  return issues;
}

/**
 * writeSetIssue(sessionId, cwd, plansDir)
 *
 * Reads <plansDir>/<sessionId>-intent.md, parses ## Issues section,
 * builds the title, and writes a custom-title JSONL record.
 *
 * Skip guard: if _readCurrentTitle returns non-null → return immediately
 * (preserves any existing PR # / ✓ suffix).
 *
 * Fail-open: missing intent.md, no issues found → no write.
 */
function writeSetIssue(sessionId, cwd, plansDir) {
  if (_isChildSession()) return;
  if (!sessionId) return;

  // Skip guard: if a title already exists, don't overwrite
  const existing = _readCurrentTitle(sessionId, cwd);
  if (existing !== null) return;

  const intentPath = path.join(plansDir, sessionId + "-intent.md");
  let intentContent;
  try {
    intentContent = fs.readFileSync(intentPath, "utf8");
  } catch (_) {
    return; // fail-open: missing intent.md
  }

  const issues = _parseIssuesWithTitles(intentContent);
  if (issues.length === 0) return; // fail-open: no issues found

  // Build title
  let title;
  if (issues.length === 1) {
    const { num, title: issueTitle } = issues[0];
    title = issueTitle ? `#${num} ${issueTitle}` : `#${num}`;
  } else {
    // Multi-issue: "#N1 #N2 title-of-first"
    const nums = issues.map((i) => `#${i.num}`).join(" ");
    const firstTitle = issues[0].title;
    title = firstTitle ? `${nums} ${firstTitle}` : nums;
  }

  _writeTitle(sessionId, cwd, title);
}

/**
 * writeAddPr(sessionId, cwd, prNumber)
 *
 * Reads current title from JSONL, appends " PR #<prNumber>" if not already present.
 * Fail-open: no existing record → writes "PR #<prNumber>" as full title.
 * Idempotent: second call is a no-op if "PR #<prNumber>" already present.
 */
function writeAddPr(sessionId, cwd, prNumber) {
  if (_isChildSession()) return;
  if (!sessionId) return;

  const prSuffix = `PR #${prNumber}`;
  const current = _readCurrentTitle(sessionId, cwd);

  if (current === null) {
    _writeTitle(sessionId, cwd, prSuffix);
    return;
  }

  // Idempotent: already contains PR #N
  if (current.includes(prSuffix)) return;

  _writeTitle(sessionId, cwd, `${current} ${prSuffix}`);
}

/**
 * writeMarkComplete(sessionId, cwd)
 *
 * Reads current title from JSONL, prepends "✓ " if not already present.
 * Fail-open: no existing record → writes "✓".
 * Idempotent: second call is a no-op.
 */
function writeMarkComplete(sessionId, cwd) {
  if (_isChildSession()) return;
  if (!sessionId) return;

  const current = _readCurrentTitle(sessionId, cwd);

  if (current === null) {
    _writeTitle(sessionId, cwd, "✓");
    return;
  }

  // Idempotent: already starts with ✓
  if (current.startsWith("✓")) return;

  _writeTitle(sessionId, cwd, `✓ ${current}`);
}

module.exports = {
  writeSetIssue,
  writeAddPr,
  writeMarkComplete,
  // Exported for testing
  _readCurrentTitle,
  _writeTitle,
  _encodeCwd,
  _getJsonlPath,
};
