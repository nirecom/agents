"use strict";
// hooks/lib/command-ir/heredoc.js — heredoc as first-class syntax (#2121 / #2134 S2).
//
// Finds openers quote-aware and drops body lines from the text handed to the lexer,
// so body text can no longer become separators or redirect records.
// A delimiter LINE closes the body, including one on the last physical line (tool
// payloads routinely omit the trailing newline).
// Ownership: docs/architecture/claude-code/shell-command-parsing.md.

// Tag right after `<<` / `<<-`: quoted or a bare word (`.`/`-` admitted so
// punctuated delimiters like `EOF-1.2` are recognised).
const TAG_RE = /^(-?)[ \t]*(?:'([^']*)'|"([^"]*)"|([A-Za-z0-9_.\-]+))/;

// Heredoc openers on ONE physical line, skipping quoted and escaped regions.
// `<<<` is a here-STRING, not a heredoc, and is deliberately skipped.
function findOpeners(line) {
  const out = [];
  const n = line.length;
  let i = 0;
  while (i < n) {
    const ch = line[i];
    if (ch === "'") {
      i++;
      while (i < n && line[i] !== "'") i++;
      i++;
      continue;
    }
    if (ch === '"') {
      i++;
      while (i < n && line[i] !== '"') {
        if (line[i] === "\\") i++;
        i++;
      }
      i++;
      continue;
    }
    if (ch === "\\") {
      i += 2;
      continue;
    }
    if (ch === "<" && line[i + 1] === "<") {
      if (line[i + 2] === "<") { i += 3; continue; }
      const m = TAG_RE.exec(line.slice(i + 2));
      if (m && (m[2] != null || m[3] != null || m[4] != null)) {
        const tag = m[2] != null ? m[2] : m[3] != null ? m[3] : m[4];
        out.push({ tag, indent: m[1] === "-", quoted: m[2] != null || m[3] != null, column: i });
        i += 2 + m[0].length;
        continue;
      }
      i += 2;
      continue;
    }
    i++;
  }
  return out;
}

/**
 * Split a command into the text the lexer should see and the heredocs it carries.
 *
 * @param {string} cmd raw command text
 * @returns {{lexText: string, heredocs: object[]}} lexText === cmd when no heredoc
 *          on the line is closed by a newline-terminated delimiter line.
 */
function scanHeredocs(cmd) {
  const heredocs = [];
  if (typeof cmd !== "string" || cmd.indexOf("<<") === -1) {
    return { lexText: typeof cmd === "string" ? cmd : "", heredocs };
  }
  const lines = cmd.split("\n");
  const keep = new Array(lines.length).fill(true);
  let stripped = false;
  let li = 0;

  while (li < lines.length) {
    const openers = findOpeners(lines[li]);
    if (openers.length === 0) { li++; continue; }

    let cursor = li + 1;
    let allTerminated = true;
    const claimed = [];

    for (const op of openers) {
      let end = -1;
      for (let k = cursor; k < lines.length; k++) {
        const cand = op.indent ? lines[k].replace(/^\t+/, "") : lines[k];
        if (cand === op.tag) { end = k; break; }
      }
      if (end === -1) {
        allTerminated = false;
        heredocs.push({ tag: op.tag, quoted: op.quoted, indent: op.indent, line: li, column: op.column, terminated: false });
        continue;
      }
      claimed.push([cursor, end]);
      heredocs.push({
        tag: op.tag, quoted: op.quoted, indent: op.indent, line: li, column: op.column,
        terminated: true, bodyStart: cursor, bodyEnd: end,
      });
      cursor = end + 1;
    }

    if (allTerminated && claimed.length > 0) {
      for (const [a, b] of claimed) {
        for (let k = a; k <= b; k++) keep[k] = false;
      }
      stripped = true;
      li = cursor;
    } else {
      li++;
    }
  }

  const lexText = stripped ? lines.filter((_l, i) => keep[i]).join("\n") : cmd;
  return { lexText, heredocs };
}

module.exports = { scanHeredocs, findOpeners };
