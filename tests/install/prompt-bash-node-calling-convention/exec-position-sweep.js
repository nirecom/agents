'use strict';

// General/class-level checker for #2262's root defect (bare "$AGENTS_CONFIG_DIR/<path>" in
// execution position, or the wrong interpreter). Scope is driven from
// install/settings-allow-commands.txt (CPR-SSOT); rationale: docs/architecture/claude-code/settings.md.
// Scans code spans only (fenced blocks + inline `...`) -- a prose mention is not a command line.
// Sole consumer: tests/prompt-bash-node-calling-convention/exec-position-sweep.sh.
// Contract: argv[1] is the agents root; stdout is {"occurrences":[{file,line,entry,prevToken,
// expected,status}]}; a malformed SSOT throws (fail-closed, non-zero exit) rather than reporting
// an empty sweep.

const fs = require('fs');
const path = require('path');

const agentsRoot = process.argv[2];
if (!agentsRoot) {
    process.stderr.write('usage: exec-position-sweep.js <agentsRoot>\n');
    process.exit(2);
}

const rulesLib = require(path.join(agentsRoot, 'install', 'lib', 'settings-allow-rules.js'));

const readSsotEntries = () => {
    const file = path.join(agentsRoot, 'install', 'settings-allow-commands.txt');
    const raw = fs.readFileSync(file, 'utf8');
    return raw
        .split('\n')
        .map((line) => line.replace(/\s+$/, ''))
        .filter((line) => line.length > 0 && !/^\s*#/.test(line));
};

// install/ is out of scope for this diff (resolveInterpreter is a private, unexported
// function there) -- so the expected interpreter per entry is read back from the same
// generatedAllowRules() output settings.json itself is built from, never re-derived here.
const escapeRegex = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

const buildInterpreterMap = (entries) => {
    const { rules } = rulesLib.generatedAllowRules({ agentsRoot });
    const map = new Map();
    for (const entry of entries) {
        const re = new RegExp(`^Bash\\((bash|node) "\\$AGENTS_CONFIG_DIR/${escapeRegex(entry)}"\\)$`);
        const hit = rules.find((r) => re.test(r));
        map.set(entry, hit ? re.exec(hit)[1] : null);
    }
    return map;
};

// Pattern B (rules/coding/file-split.md): SKILL.md, rules/*.md, agents/*.md, skills/_shared/*.md.
const listPromptFiles = () => {
    const files = [];
    const topLevelMd = (dir) => {
        const abs = path.join(agentsRoot, dir);
        let entries;
        try {
            entries = fs.readdirSync(abs, { withFileTypes: true });
        } catch (e) {
            return;
        }
        for (const ent of entries) {
            if (ent.isFile() && ent.name.endsWith('.md')) files.push(path.join(dir, ent.name));
        }
    };
    topLevelMd('agents');
    topLevelMd('rules');
    topLevelMd('skills/_shared');

    const walkSkills = (dir) => {
        const abs = path.join(agentsRoot, dir);
        let entries;
        try {
            entries = fs.readdirSync(abs, { withFileTypes: true });
        } catch (e) {
            return;
        }
        for (const ent of entries) {
            const rel = path.join(dir, ent.name);
            if (ent.isDirectory()) {
                walkSkills(rel);
            } else if (ent.isFile() && ent.name === 'SKILL.md') {
                files.push(rel);
            }
        }
    };
    walkSkills('skills');

    return [...new Set(files)].map((p) => p.split(path.sep).join('/')).sort();
};

// Extracts candidate command-ish text spans (fenced code lines, inline `code` spans) with
// their 1-based source line number, without evaluating chain/token structure yet.
const extractSpans = (content) => {
    const spans = [];
    const lines = content.split('\n');
    let inFence = false;
    for (let i = 0; i < lines.length; i += 1) {
        const line = lines[i];
        if (/^\s*```/.test(line)) {
            inFence = !inFence;
            continue;
        }
        if (inFence) {
            spans.push({ text: line, lineNo: i + 1 });
            continue;
        }
        const re = /`([^`\n]+)`/g;
        let m;
        while ((m = re.exec(line)) !== null) {
            spans.push({ text: m[1], lineNo: i + 1 });
        }
    }
    return spans;
};

const tokenize = (segment) => {
    const re = /"[^"]*"|'[^']*'|\S+/g;
    const tokens = [];
    let m;
    while ((m = re.exec(segment)) !== null) tokens.push(m[0]);
    return tokens;
};

const stripQuotes = (token) => {
    if (token.length >= 2 && ((token[0] === '"' && token[token.length - 1] === '"') ||
        (token[0] === "'" && token[token.length - 1] === "'"))) {
        return token.slice(1, -1);
    }
    return token;
};

const isEnvAssignment = (token) => /^[A-Za-z_][A-Za-z0-9_]*=/.test(stripQuotes(token));

// THE EXCLUSION CLASS. The subject is EXECUTION position, and a path only reaches it two ways:
// as the first token of a segment, or as the operand of a token that launches what follows.
// Everything else is quotation-equivalent -- `cat "<path>"`, `git add "<path>"`, and the
// `Bash(bash "<path>")` allow-rule strings this repo quotes verbatim (whose preceding token is
// the glued `Bash(bash`) name the file, they do not run it, so reporting them would be noise
// the sweep's zero-offender contract could never reach green against.
const LAUNCHERS = new Set([
    'bash', 'node', 'sh', 'zsh', 'ksh', 'dash', 'pwsh', 'powershell',
    'python', 'python3', 'env', 'exec', 'source', '.', 'sudo', 'command',
]);

const main = () => {
    const entries = readSsotEntries();
    const expectedInterpreter = buildInterpreterMap(entries);

    // Longest-entry-first so "bin/foo/bar" is not shadowed by a coincidental "bin/foo" prefix match.
    const entriesByLength = [...entries].sort((a, b) => b.length - a.length);
    const matchEntry = (bare) => entriesByLength.find((e) => bare === `$AGENTS_CONFIG_DIR/${e}`) || null;

    const files = listPromptFiles();
    const occurrences = [];

    for (const relFile of files) {
        const abs = path.join(agentsRoot, relFile);
        const content = fs.readFileSync(abs, 'utf8');
        const spans = extractSpans(content);
        for (const span of spans) {
            const segments = span.text.split(/&&|\||;/);
            for (const segment of segments) {
                const tokens = tokenize(segment.trim());
                for (let i = 0; i < tokens.length; i += 1) {
                    const entry = matchEntry(stripQuotes(tokens[i]));
                    if (!entry) continue;
                    let j = i - 1;
                    while (j >= 0 && isEnvAssignment(tokens[j])) j -= 1;
                    const prevToken = j >= 0 ? stripQuotes(tokens[j]) : null;
                    if (prevToken !== null && !LAUNCHERS.has(prevToken)) continue;
                    const expected = expectedInterpreter.get(entry);
                    let status;
                    if (prevToken === null) status = 'no-interpreter';
                    else if (prevToken !== 'bash' && prevToken !== 'node') status = 'unexpected-prefix';
                    else if (expected === null) status = 'unresolvable-entry';
                    else if (prevToken !== expected) status = 'wrong-interpreter';
                    else status = 'ok';
                    occurrences.push({
                        file: relFile, line: span.lineNo, entry, prevToken, expected, status,
                    });
                }
            }
        }
    }

    process.stdout.write(JSON.stringify({ occurrences }));
};

main();
