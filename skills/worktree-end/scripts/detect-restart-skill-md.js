#!/usr/bin/env node
'use strict';
// Reads a unified diff (gh pr diff) on stdin; prints `yes` when any SKILL.md block is added,
// deleted, renamed, or changes a frontmatter line, else `no`. Called by detect-restart.sh (#1076).
// Any error prints `no` and exits 0, matching detect-restart.sh's fail-safe.

const SKILL_MD_RE = /(^|\/)SKILL\.md$/;
const HUNK_RE = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/;
const isDelim = (s) => s.trim() === '---';

// One side (old: context + '-', new: context + '+') of a hunk that starts at file line 1:
// the frontmatter runs from the opening --- to the next --- (or past the hunk end).
const sideTouchesFrontmatter = (hunk, drop) => {
    const side = hunk.filter((l) => l.kind !== drop);
    if (side.length === 0 || !isDelim(side[0].text)) return false;
    const close = side.findIndex((l, i) => i > 0 && isDelim(l.text));
    return side.some((l, i) => l.kind !== ' ' && (close === -1 || i < close));
};

// Hunk not anchored at line 1: a change with no --- in the context before it and one after it.
const midHunkTouchesFrontmatter = (hunk) => hunk.some((l, i) => l.kind !== ' '
    && !hunk.slice(0, i).some((c) => c.kind === ' ' && isDelim(c.text))
    && hunk.slice(i + 1).some((c) => c.kind === ' ' && isDelim(c.text)));

const hunkTouchesFrontmatter = ({ oldStart, newStart, lines }) => {
    if (oldStart === 1 || newStart === 1) {
        return (oldStart === 1 && sideTouchesFrontmatter(lines, '+'))
            || (newStart === 1 && sideTouchesFrontmatter(lines, '-'));
    }
    return midHunkTouchesFrontmatter(lines);
};

const blockQualifies = (block) => {
    const m = /^diff --git a\/(\S+) b\/(\S+)/.exec(block[0]);
    if (!m || !(SKILL_MD_RE.test(m[1]) || SKILL_MD_RE.test(m[2]))) return false;
    const hunks = [];
    for (const line of block.slice(1)) {
        const h = HUNK_RE.exec(line);
        if (h) hunks.push({ oldStart: Number(h[1]), newStart: Number(h[2]), lines: [] });
        else if (hunks.length === 0) {
            if (/^(new file mode|deleted file mode|rename from) /.test(line)) return true;
        } else if (/^[ +-]/.test(line) || line === '') {
            hunks[hunks.length - 1].lines.push({ kind: line[0] || ' ', text: line.slice(1) });
        }
    }
    return hunks.some((h) => h.lines.some((l) => l.kind !== ' ') && hunkTouchesFrontmatter(h));
};

try {
    const input = require('fs').readFileSync(0, 'utf8');
    const blocks = [];
    for (const line of input.split(/\r?\n/)) {
        if (line.startsWith('diff --git ')) blocks.push([line]);
        else if (blocks.length > 0) blocks[blocks.length - 1].push(line);
    }
    process.stdout.write(blocks.some(blockQualifies) ? 'yes\n' : 'no\n');
} catch {
    process.stdout.write('no\n');
}
