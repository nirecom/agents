// Tests: skills/review-tests/SKILL.md, rules/shell-commands.md
// Parses a `claude -p --output-format json` transcript (argv[2]) and prints the ordered
// index of the first Read of rules/shell-commands.md and the first Bash tool_use, among the
// assistant's tool_use blocks only (text blocks are not counted). -1 means "not seen".
const fs = require('fs');

let data;
try {
    data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
} catch (e) {
    console.log('READ_IDX=-1 BASH_IDX=-1 TOTAL=0');
    process.exit(0);
}

const msgs = Array.isArray(data.messages) ? data.messages : [];
const seq = [];
for (const m of msgs) {
    if (m.role !== 'assistant') continue;
    for (const c of m.content || []) {
        if (c.type === 'tool_use') seq.push(c);
    }
}

let readIdx = -1;
let bashIdx = -1;
seq.forEach((t, i) => {
    const p = t.input && (t.input.file_path || t.input.path);
    const normalized = typeof p === 'string' ? p.replace(/\\/g, '/') : '';
    if (readIdx === -1 && t.name === 'Read' && normalized.endsWith('rules/shell-commands.md')) {
        readIdx = i;
    }
    if (bashIdx === -1 && t.name === 'Bash') {
        bashIdx = i;
    }
});

console.log('READ_IDX=' + readIdx + ' BASH_IDX=' + bashIdx + ' TOTAL=' + seq.length);
