#!/usr/bin/env node
// tests/feature-1665-seq-cascade/projectstate-callsites.js
//
// Call-site inventory for `projectState`, used by c-projectstate-callers.sh.
//
// WHY a scanner and not `grep`: the C1/C4 grep assertions are textual. They see
// only the literal string `projectState(` and only the remainder of the SAME
// line. Three mutations slip through them silently:
//   (a) an aliased call     -- `const p = projection.projectState; p(events)`
//   (b) a multiline call    -- `projectState(\n  events.filter(f)\n)`
//   (c) a pre-filtered var  -- `const sub = events.slice(0,3); projectState(sub)`
// This scanner catches all three.
//
// WHAT IT IS NOT: this is a lexical scanner, not an AST. It strips comments and
// string/template literals, resolves a bounded set of alias forms, and matches
// parentheses to recover a call's real (possibly multiline) argument text. It
// does NOT build a scope tree and it does NOT evaluate anything. Its honest
// limits are enumerated in the `# TL3 gap` block of c-projectstate-callers.sh.
//
// Usage:  node projectstate-callsites.js <file.js> [<file.js> ...]
// Stdout (stable, line-oriented; paths are printed exactly as given):
//   ALIAS   <file> <name>
//   CALL    <file> <callee> <line> <filtered:0|1>
//   COUNT   <file> <n>
//   TOTAL   <n>
//   FILTERED <n>

'use strict';

const fs = require('fs');

const TARGET = 'projectState';

// Replace comments and string/template bodies with same-length blanks so that
// offsets (and therefore line numbers) stay aligned with the original source.
function blankNoise(src) {
    const out = src.split('');
    const blank = (from, to) => {
        for (let k = from; k < to && k < out.length; k++) {
            if (out[k] !== '\n') out[k] = ' ';
        }
    };
    let i = 0;
    while (i < src.length) {
        const c = src[i];
        const d = src[i + 1];
        if (c === '/' && d === '/') {
            let j = i;
            while (j < src.length && src[j] !== '\n') j++;
            blank(i, j);
            i = j;
            continue;
        }
        if (c === '/' && d === '*') {
            let j = src.indexOf('*/', i + 2);
            j = j === -1 ? src.length : j + 2;
            blank(i, j);
            i = j;
            continue;
        }
        if (c === '"' || c === "'" || c === '`') {
            let j = i + 1;
            while (j < src.length) {
                if (src[j] === '\\') { j += 2; continue; }
                if (src[j] === c) break;
                if (c !== '`' && src[j] === '\n') break;
                j++;
            }
            blank(i + 1, j);
            i = j + 1;
            continue;
        }
        i++;
    }
    return out.join('');
}

const lineOf = (src, idx) => src.slice(0, idx).split('\n').length;

// Alias forms resolved (deliberately bounded -- see TL3 gap block):
//   const p = projection.projectState;      -> p
//   const p = projectState;                 -> p
//   const { projectState: p } = require(..) -> p
//   let p; p = mod.projectState;            -> p
function collectAliases(code) {
    const names = new Set();
    const decl = new RegExp(
        String.raw`(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*\.` +
        TARGET + String.raw`\b\s*(?!\()`,
        'g');
    const declBare = new RegExp(
        String.raw`(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*` + TARGET + String.raw`\b\s*(?!\()`,
        'g');
    const assign = new RegExp(
        String.raw`([A-Za-z_$][\w$]*)\s*=\s*[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*\.` +
        TARGET + String.raw`\b\s*(?!\()`,
        'g');
    // destructuring rename: `{ ... projectState: p ... } =`
    const destr = new RegExp(
        String.raw`\{[^{}]*\b` + TARGET + String.raw`\s*:\s*([A-Za-z_$][\w$]*)[^{}]*\}\s*=`,
        'g');
    for (const re of [decl, declBare, assign, destr]) {
        let m;
        while ((m = re.exec(code)) !== null) {
            if (m[1] !== TARGET) names.add(m[1]);
        }
    }
    return names;
}

// Walk forward from the '(' at `open`, matching nested brackets, and return the
// text of the FIRST top-level argument.
function firstArg(code, open) {
    let depth = 0;
    let start = open + 1;
    for (let i = open; i < code.length; i++) {
        const c = code[i];
        if (c === '(' || c === '[' || c === '{') depth++;
        else if (c === ')' || c === ']' || c === '}') {
            depth--;
            if (depth === 0) return code.slice(start, i);
        } else if (c === ',' && depth === 1) {
            return code.slice(start, i);
        }
    }
    return code.slice(start);
}

const SUBSEQ = /\.filter\s*\(|\.slice\s*\(/;

// A bare identifier argument is traced back to its declaration in the same file,
// so `const sub = events.slice(0,3); projectState(sub)` is still flagged.
function argFoldsSubsequence(code, arg) {
    const a = arg.trim();
    if (SUBSEQ.test(a)) return true;
    if (!/^[A-Za-z_$][\w$]*$/.test(a)) return false;
    const re = new RegExp(String.raw`(?:const|let|var)\s+` + a + String.raw`\s*=\s*([^;\n]*(?:\n(?!\s*(?:const|let|var|return)\b)[^;\n]*)*)`, 'g');
    let m;
    while ((m = re.exec(code)) !== null) {
        if (SUBSEQ.test(m[1])) return true;
    }
    return false;
}

function scan(file) {
    const raw = fs.readFileSync(file, 'utf8');
    const code = blankNoise(raw);
    const callees = new Set([TARGET, ...collectAliases(code)]);
    const calls = [];
    for (const name of callees) {
        const re = new RegExp(String.raw`\b` + name.replace(/\$/g, '\\$') + String.raw`\s*\(`, 'g');
        let m;
        while ((m = re.exec(code)) !== null) {
            const before = code.slice(Math.max(0, m.index - 40), m.index);
            if (/\bfunction\s+$/.test(before)) continue;          // the definition
            if (/\b(?:class|new)\s+$/.test(before)) continue;
            const open = m.index + m[0].length - 1;
            const filtered = argFoldsSubsequence(code, firstArg(code, open));
            calls.push({ name, line: lineOf(code, m.index), filtered });
        }
    }
    calls.sort((a, b) => a.line - b.line);
    return { callees, calls };
}

const files = process.argv.slice(2);
let total = 0;
let filteredTotal = 0;
for (const f of files) {
    const { callees, calls } = scan(f);
    for (const a of [...callees].filter((n) => n !== TARGET).sort()) {
        console.log(`ALIAS\t${f}\t${a}`);
    }
    for (const c of calls) {
        console.log(`CALL\t${f}\t${c.name}\t${c.line}\t${c.filtered ? 1 : 0}`);
        if (c.filtered) filteredTotal++;
    }
    if (calls.length > 0) console.log(`COUNT\t${f}\t${calls.length}`);
    total += calls.length;
}
console.log(`TOTAL\t${total}`);
console.log(`FILTERED\t${filteredTotal}`);
