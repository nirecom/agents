"use strict";
// Never-synced paths (#2658): the managed .gitignore block and the matching in-engine filter.

const BEGIN = "# BEGIN agents session-sync (managed)";
const END = "# END agents session-sync (managed)";
const PATTERNS = ["/workflow/", "/codex-review/", "/plans/*", "!/plans/*.md", "*.bak.*", "*.tmp",
  "/*-AppData-Local-Temp-*/", "/-tmp-*/", "/-var-folders-*/", "/-private-var-folders-*/"];

function applyManagedBlock(text) {
  const lines = (text || "").replace(/\r\n/g, "\n").split("\n");
  if (lines[lines.length - 1] === "") lines.pop();
  const kept = [];
  let inside = false;
  for (const line of lines) {
    if (line === BEGIN) inside = true;
    else if (inside && line.startsWith("# END")) inside = false;
    else if (!inside) kept.push(line);
  }
  return kept.concat([BEGIN], PATTERNS, [END]).join("\n") + "\n";
}

const TEMP_DIR = [/^.*-AppData-Local-Temp-.*$/, /^-tmp-.*$/, /^-var-folders-.*$/, /^-private-var-folders-.*$/];

function isExcluded(rel) {
  const parts = rel.split("/");
  if (parts[0] === "workflow" || parts[0] === "codex-review") return parts.length > 1;
  if (parts[0] === "plans" && parts.length > 1) return parts.length > 2 || !parts[1].endsWith(".md");
  if (parts.length > 1 && TEMP_DIR.some((re) => re.test(parts[0]))) return true;
  return parts.some((p) => p.endsWith(".tmp") || /\.bak\./.test(p));
}

module.exports = { BEGIN, END, PATTERNS, applyManagedBlock, isExcluded };
